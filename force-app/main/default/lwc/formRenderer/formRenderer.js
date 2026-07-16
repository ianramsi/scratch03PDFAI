import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { reduceErrors } from 'c/errorUtils';

import getSubmissionView from '@salesforce/apex/FormSubmissionService.getSubmissionView';
import saveData from '@salesforce/apex/FormSubmissionService.saveData';
import recordSignature from '@salesforce/apex/FormSubmissionService.recordSignature';
import submitSubmission from '@salesforce/apex/FormSubmissionService.submit';
import approveSubmission from '@salesforce/apex/FormSubmissionService.approve';
import rejectSubmission from '@salesforce/apex/FormSubmissionService.reject';
import reopenSubmission from '@salesforce/apex/FormSubmissionService.reopenForRevision';

/**
 * formRenderer
 * ----------------------------------------------------------------------------
 * Fill-mode renderer for a Form_Submission__c. Loads the template schema + the
 * current answers in one wired call (getSubmissionView), renders sections ->
 * rows -> fields (delegating each field to c/formField and each signature to
 * c/signaturePad), and drives the lifecycle actions (save / sign / submit /
 * approve / reject / reopen) by calling FormSubmissionService.
 *
 * STATE OWNERSHIP:
 *  - This component is the single owner of the answer `values` map. Child
 *    formField components are controlled and emit `valuechange`; we mutate the
 *    map here and persist on Save/Submit.
 *
 * REFRESH:
 *  - We keep the entire wired result (`wiredView`) so refreshApex can re-pull
 *    after a mutation changes status/signatures server-side.
 *
 * VISIBILITY OF ACTIONS:
 *  - Buttons are gated by status via getters (e.g. canSubmit only in Draft).
 *    The Apex state machine is still authoritative; the UI gating is UX, not
 *    security.
 */
export default class FormRenderer extends LightningElement {
    @api recordId;            // when placed on a Form_Submission__c record page
    @api submissionId;        // or passed explicitly (app page)

    schema;                   // parsed schema object
    values = {};              // fieldId -> value
    status;
    revisionNumber = 0;
    rejectionComment;
    signatureImageByRole = {};
    error;
    isBusy = false;

    wiredView;                // entire wire result, for refreshApex

    get effectiveId() {
        return this.submissionId || this.recordId;
    }

    @wire(getSubmissionView, { submissionId: '$effectiveId' })
    wiredGetView(result) {
        this.wiredView = result;
        const { data, error } = result;
        if (data) {
            this.error = undefined;
            this.status = data.status;
            this.revisionNumber = data.revisionNumber;
            this.rejectionComment = data.rejectionComment;
            this.signatureImageByRole = data.signatureImageByRole || {};
            this.schema = data.schemaJson ? JSON.parse(data.schemaJson) : null;
            this.values = this.parseValues(data.dataJson);
        } else if (error) {
            this.error = reduceErrors(error).join(', ');
        }
    }

    parseValues(dataJson) {
        if (!dataJson) return {};
        try {
            const parsed = JSON.parse(dataJson);
            // Accept either the envelope {values:{...}} or a bare values map.
            return parsed && parsed.values ? parsed.values : parsed || {};
        } catch (e) {
            return {};
        }
    }

    // ---- render model -----------------------------------------------------
    // Decorate each field with its current value and a per-render key so the
    // template stays declarative (no logic in {}).
    get sections() {
        if (!this.schema || !Array.isArray(this.schema.sections)) return [];
        return this.schema.sections.map((sec) => ({
            id: sec.id,
            title: sec.title,
            rows: (sec.rows || []).map((row) => ({
                id: row.id,
                fields: (row.fields || []).map((f) => ({
                    ...f,
                    key: f.id,
                    value: this.values[f.id],
                    // Regular answer fields: editable only while the engineer
                    // owns the record (Draft). Signature fields are NOT gated
                    // here -- each pad has its own role-aware enable rule below,
                    // since engineer and supervisor sign at different stages.
                    disabled: f.type === 'signature' ? false : !this.isEditable,
                    isSignature: f.type === 'signature',
                    signaturePadDisabled: this.isSignatureDisabled(f.signerRole),
                    // SLDS 12-col size mapping from schema colSpan.
                    sizeClass: `slds-col slds-size_${f.colSpan || 12}-of-12`
                }))
            }))
        }));
    }

    /**
     * A signature pad is enabled only during the stage where that role is
     * expected to sign:
     *   engineer   -> Draft   (engineer is filling/signing before submit)
     *   supervisor -> Submitted (supervisor reviews/signs before approving)
     * Both are disabled once the record leaves the relevant stage (Approved,
     * Rejected) since a signature on a closed/locked record makes no sense.
     *
     * KNOWN MVP GAP: stage gating controls WHEN a pad is enabled, not WHO is
     * allowed to use it. Any user with edit access to the submission in the
     * Submitted stage can draw into the supervisor pad, regardless of their
     * actual role. FormSubmissionService.recordSignature also does not check
     * that the calling user is a real "supervisor" -- it only checks the
     * signerRole STRING passed in. Acceptable for an internal MVP demo; before
     * production, gate by checking the running user against Submission__c's
     * Supervisor lookup or a permission/profile check server-side.
     */
    isSignatureDisabled(signerRole) {
        if (signerRole === 'engineer') return this.status !== 'Draft';
        if (signerRole === 'supervisor') return this.status !== 'Submitted';
        return true;
    }

    // ---- status-driven UX gating -----------------------------------------
    get isEditable() { return this.status === 'Draft'; }
    get canSubmit() { return this.status === 'Draft'; }
    get canApproveReject() { return this.status === 'Submitted'; }
    get canReopen() { return this.status === 'Rejected'; }
    get isApproved() { return this.status === 'Approved'; }
    get showRejection() {
        return this.status === 'Rejected' && this.rejectionComment;
    }

    get statusVariant() {
        switch (this.status) {
            case 'Approved': return 'success';
            case 'Rejected': return 'error';
            case 'Submitted': return 'warning';
            default: return 'inverse';
        }
    }

    // ---- field + signature events ----------------------------------------
    handleValueChange(evt) {
        const { fieldId, value } = evt.detail;
        // Reassign for reactivity.
        this.values = { ...this.values, [fieldId]: value };
    }

    async handleSigned(evt) {
        const { role, fieldId, contentVersionId } = evt.detail;
        this.isBusy = true;
        try {
            await recordSignature({
                submissionId: this.effectiveId,
                signerRole: role,
                fieldId,
                imageCvId: contentVersionId
            });
            await refreshApex(this.wiredView);
            this.toast('Signature recorded', '', 'success');
        } catch (error) {
            this.toast('Error', reduceErrors(error).join(', '), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    // ---- lifecycle actions ------------------------------------------------
    async handleSave() {
        await this.run(
            () => saveData({ submissionId: this.effectiveId, dataJson: this.buildDataJson() }),
            'Draft saved'
        );
    }

    async handleSubmit() {
        // Persist current values first, then submit (server re-validates required).
        await this.run(async () => {
            await saveData({ submissionId: this.effectiveId, dataJson: this.buildDataJson() });
            await submitSubmission({ submissionId: this.effectiveId });
        }, 'Submitted for approval');
    }

    async handleApprove() {
        await this.run(
            () => approveSubmission({ submissionId: this.effectiveId }),
            'Approved'
        );
    }

    async handleReject() {
        const comment = this.refs.rejectComment ? this.refs.rejectComment.value : '';
        if (!comment) {
            this.toast('Comment required', 'Please enter a rejection reason.', 'warning');
            return;
        }
        await this.run(
            () => rejectSubmission({ submissionId: this.effectiveId, comment }),
            'Rejected'
        );
    }

    async handleReopen() {
        await this.run(
            () => reopenSubmission({ submissionId: this.effectiveId }),
            'Reopened for revision'
        );
    }

    // Shared action runner: busy state + refresh + toast + error normalization.
    async run(action, successMsg) {
        this.isBusy = true;
        try {
            await action();
            await refreshApex(this.wiredView);
            this.toast('Success', successMsg, 'success');
        } catch (error) {
            this.toast('Error', reduceErrors(error).join(', '), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    buildDataJson() {
        // Envelope shape per contract (templateId/version are known server-side
        // already; we send the values map which is what saveData stores).
        return JSON.stringify({ values: this.values });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}