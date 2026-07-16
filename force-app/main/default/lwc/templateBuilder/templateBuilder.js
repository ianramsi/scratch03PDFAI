import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { reduceErrors } from 'c/errorUtils';

import getTemplateStatus from '@salesforce/apex/FormTemplateService.getTemplateStatus';
import startScan from '@salesforce/apex/FormTemplateService.startScan';
import applyAiEdit from '@salesforce/apex/FormTemplateService.applyAiEdit';
import saveSchema from '@salesforce/apex/FormTemplateService.saveSchema';
import publishTemplate from '@salesforce/apex/FormTemplateService.publishTemplate';
import revertToDraft from '@salesforce/apex/FormTemplateService.revertToDraft';

/**
 * templateBuilder
 * ----------------------------------------------------------------------------
 * The template DESIGN surface. Four capabilities over one Form_Template__c:
 *
 *   1. SCAN: upload a PDF/JPEG/PNG -> startScan (async) -> poll Scan_Status__c
 *      until Success/Failed -> the extracted schema appears.
 *   2. AI EDIT: type a prompt -> applyAiEdit (sync) -> schema updates.
 *   3. MANUAL EDIT: edit field properties / reorder / add / remove via
 *      c/schemaFieldEditor; Save persists with authoritative validation.
 *   4. PUBLISH: validate + lock the template so it can be filled.
 *
 * Plus a read-only PREVIEW that reuses c/formField (disabled) so the designer
 * sees the rendered result.
 *
 * STATE: this component owns a working copy of the schema (`schema`). Server
 * round-trips (scan/AI/save/publish) re-sync from the server via reload().
 *
 * POLLING: scan is async; we poll getTemplateStatus (uncached) every
 * POLL_INTERVAL_MS, stopping on Success/Failed or after POLL_MAX_TRIES to avoid
 * an infinite loop if the callback never arrives.
 */
const POLL_INTERVAL_MS = 2500;
const POLL_MAX_TRIES = 48; // ~2 minutes ceiling

// Scripted log steps shown while the async scan runs. Delays are absolute
// (ms from scan start); the real completion line is appended by pollOnce.
const SCAN_LOG_STEPS = [
    { delay: 300, text: 'Connecting to Lori AI Vision scan service via n8n...', cls: 'log-line log-line--info' },
    { delay: 1000, text: 'Uploading document for analysis...', cls: 'log-line log-line--info' },
    { delay: 1800, text: 'Document received -- queuing for Vision model...', cls: 'log-line log-line--info' },
    { delay: 2800, text: 'Model analyzing form structure...', cls: 'log-line log-line--info' },
    { delay: 4200, text: 'Detecting sections and column headers...', cls: 'log-line log-line--info' },
    { delay: 5800, text: 'Extracting field labels and types...', cls: 'log-line log-line--info' },
    { delay: 7600, text: 'Building hierarchical template schema...', cls: 'log-line log-line--info' }
];

export default class TemplateBuilder extends LightningElement {
    @api recordId;        // on a Form_Template__c record page
    @api templateId;      // or explicit (app page)

    @track schema;        // working schema object
    name;
    status;               // Draft | Published | Archived
    scanStatus;           // Pending | Processing | Success | Failed
    version = 1;

    prompt = '';
    isBusy = false;
    error;

    @track logLines = [];  // terminal-style scan log lines
    showScanLog = false;   // panel visibility (outlives isScanning briefly)

    _pollTries = 0;
    _pollTimer;
    _loaded = false;       // guard: load template state only once
    _logTimers = [];
    _logSeq = 0;
    _logScrollPending = false;

    get effectiveId() {
        return this.templateId || this.recordId;
    }

    // Initial load is IMPERATIVE and UNCACHED on purpose. A cacheable @wire can
    // serve a stale result that was cached when the template had no schema yet
    // (e.g. schema added out-of-band via Setup), leaving the builder showing no
    // schema. getTemplateStatus is uncached, so the load is always fresh.
    connectedCallback() {
        // NOTE: on a record page, recordId is frequently NOT yet set when
        // connectedCallback runs (LWC sets @api props around this point, not
        // strictly before). So we attempt a load here AND again in
        // renderedCallback once effectiveId is guaranteed available. The
        // _loaded guard ensures we only fetch once.
        this.maybeLoad();
    }

    renderedCallback() {
        // Covers the common case where recordId arrives after connectedCallback.
        this.maybeLoad();
        // Keep the scan log scrolled to the newest line.
        if (this._logScrollPending) {
            this._logScrollPending = false;
            const panel = this.refs.scanLog;
            if (panel) panel.scrollTop = panel.scrollHeight;
        }
    }

    /** Load template state exactly once, as soon as an id is available. */
    maybeLoad() {
        if (this._loaded || !this.effectiveId) return;
        this._loaded = true;
        this.reload();
    }

    disconnectedCallback() {
        this.stopPolling();
        this._clearLogTimers();
    }

    /** Fetch fresh template state (uncached) and apply it. */
    async reload() {
        try {
            const v = await getTemplateStatus({ templateId: this.effectiveId });
            this.applyView(v);
            this.error = undefined;
        } catch (error) {
            this.error = reduceErrors(error).join(', ');
        }
    }

    /** Map a TemplateView DTO onto component state (single place). */
    applyView(v) {
        if (!v) return;
        this.name = v.name;
        this.status = v.status;
        this.scanStatus = v.scanStatus;
        this.version = v.version;
        // Defensive parse: surface a parse failure instead of silently leaving
        // the manual-edit/preview panels hidden (hasSchema would stay false).
        const schemaStr = v.schemaJson != null ? v.schemaJson : v.schemaJSON;
        if (schemaStr) {
            try {
                this.schema = JSON.parse(schemaStr);
            } catch (e) {
                this.schema = null;
                this.error = 'Schema JSON could not be parsed: ' + e.message;
            }
        } else {
            this.schema = null;
        }
        // If we (re)loaded while a scan is already in flight (e.g. page refresh
        // mid-scan), resume the log animation and polling.
        if (this.isScanning && !this._pollTimer) {
            this._startScanLog();
            this.startPolling();
        }
    }

    // ---- status-driven gating --------------------------------------------
    get isDraft() { return this.status === 'Draft'; }
    get isPublished() { return this.status === 'Published'; }
    get hasSchema() { return !!(this.schema && this.schema.sections && this.schema.sections.length); }
    get isScanning() { return this.scanStatus === 'Processing'; }
    get canEdit() { return this.isDraft; }
    // Publish is only meaningful when there's a Draft schema to publish. Gating
    // here prevents handlePublish from ever serializing a null schema to "null".
    get canPublish() { return this.isDraft && this.hasSchema; }

    get statusVariant() {
        if (this.status === 'Published') return 'success';
        return 'inverse';
    }

    // ===================================================================
    // 1. SCAN
    // ===================================================================

    get acceptedFormats() {
        return ['.pdf', '.png', '.jpg', '.jpeg'];
    }

    async handleUploadFinished(event) {
        const files = event.detail.files;
        if (!files || !files.length) return;
        // lightning-file-upload attaches the file to effectiveId (the template
        // record) and returns contentVersionId (068...) on each file entry.
        // startScan expects exactly that ContentVersion Id.
        const contentVersionId = files[0].contentVersionId;
        await this.run(async () => {
            await startScan({ templateId: this.effectiveId, contentVersionId });
            this.scanStatus = 'Processing';
            this._startScanLog();
            this.startPolling();
        }, 'Scan started');
    }

    // ---- scan log (terminal-style progress animation) ---------------------
    // The scan itself is async (n8n callback + polling), so the scripted
    // steps are cosmetic pacing; only the final line reflects the real result.

    _startScanLog() {
        this._clearLogTimers();
        this.logLines = [];
        this.showScanLog = true;
        SCAN_LOG_STEPS.forEach((step) => {
            this._logTimers.push(
                setTimeout(() => this._addLog(step.text, step.cls), step.delay)
            );
        });
    }

    _addLog(text, cls) {
        this.logLines = [...this.logLines, { id: ++this._logSeq, text, cls }];
        this._logScrollPending = true;
    }

    _clearLogTimers() {
        this._logTimers.forEach((t) => clearTimeout(t));
        this._logTimers = [];
    }

    /** Append the real outcome line and (on success) fade the panel away. */
    _finishScanLog(ok, message) {
        this._clearLogTimers();
        this._addLog(message, ok ? 'log-line log-line--success' : 'log-line log-line--error');
        if (ok) {
            // Leave the success line on screen briefly, then hide the panel.
            this._logTimers.push(setTimeout(() => { this.showScanLog = false; }, 2000));
        }
        // On failure the panel stays until the next scan starts.
    }

    startPolling() {
        this.stopPolling();
        this._pollTries = 0;
        this._pollTimer = setInterval(() => this.pollOnce(), POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = undefined;
        }
    }

    async pollOnce() {
        this._pollTries += 1;
        if (this._pollTries > POLL_MAX_TRIES) {
            this.stopPolling();
            this.scanStatus = 'Failed';
            this._finishScanLog(false, 'Error: scan timed out -- no result received from n8n.');
            this.toast('Scan timed out', 'No result received. Check LKS Vision.', 'warning');
            return;
        }
        try {
            const v = await getTemplateStatus({ templateId: this.effectiveId });
            this.scanStatus = v.scanStatus;
            if (v.scanStatus === 'Success') {
                this.stopPolling();
                this.applyView(v);
                const c = this._schemaCounts();
                this._finishScanLog(true,
                    `Schema extraction complete -- ${c.sections} section${c.sections === 1 ? '' : 's'}, ${c.fields} field${c.fields === 1 ? '' : 's'} identified`);
                this.toast('Scan complete', 'Schema extracted.', 'success');
            } else if (v.scanStatus === 'Failed') {
                this.stopPolling();
                this._finishScanLog(false, 'Error: Vision could not extract a schema from the document.');
                this.toast('Scan failed', 'Vision could not extract a schema.', 'error');
            } else if (this._pollTries % 4 === 0) {
                // Every ~10s of real waiting, reassure that we're still on it.
                const secs = Math.round((this._pollTries * POLL_INTERVAL_MS) / 1000);
                this._addLog(`Still analyzing... (${secs}s elapsed)`, 'log-line log-line--muted');
            }
        } catch (e) {
            this.stopPolling();
            this._finishScanLog(false, 'Error: ' + reduceErrors(e).join(', '));
            this.toast('Polling error', reduceErrors(e).join(', '), 'error');
        }
    }

    _schemaCounts() {
        let sections = 0, fields = 0;
        if (this.hasSchema) {
            sections = this.schema.sections.length;
            this.schema.sections.forEach((sec) =>
                (sec.rows || []).forEach((row) => { fields += (row.fields || []).length; }));
        }
        return { sections, fields };
    }

    // ===================================================================
    // 2. AI EDIT
    // ===================================================================

    handlePromptChange(e) {
        this.prompt = e.target.value;
    }

    async handleAiEdit() {
        if (!this.prompt) {
            this.toast('Empty prompt', 'Describe the change you want.', 'warning');
            return;
        }
        await this.run(async () => {
            const newSchemaJson = await applyAiEdit({
                templateId: this.effectiveId,
                prompt: this.prompt
            });
            this.schema = JSON.parse(newSchemaJson);
            this.prompt = '';
            await this.reload();
        }, 'AI edit applied');
    }

    // ===================================================================
    // 3. MANUAL EDIT
    // ===================================================================
    // Render model: flatten fields with their section/row coordinates so the
    // editor can list them and we can splice changes back precisely.

    get sectionModels() {
        if (!this.hasSchema) return [];
        return this.schema.sections.map((sec) => {
            // Flatten this section's fields across its rows, preserving order.
            const flat = [];
            (sec.rows || []).forEach((row) => {
                (row.fields || []).forEach((f) => flat.push(f));
            });
            return {
                id: sec.id,
                title: sec.title,
                fields: flat.map((f, idx) => ({
                    ...f,
                    key: f.id,
                    isFirst: idx === 0,
                    isLast: idx === flat.length - 1
                }))
            };
        });
    }

    handleFieldChange(e) {
        const updated = e.detail;
        this.mutateSchema((sections) => {
            outer: for (const sec of sections) {
                for (const row of sec.rows || []) {
                    const i = (row.fields || []).findIndex((f) => f.id === updated.id);
                    if (i !== -1) {
                        row.fields[i] = updated;
                        break outer;
                    }
                }
            }
        });
    }

    handleMoveUp(e) { this.moveField(e.detail, -1); }
    handleMoveDown(e) { this.moveField(e.detail, +1); }

    moveField(fieldId, delta) {
        this.mutateSchema((sections) => {
            for (const sec of sections) {
                // Operate on the flattened order within a section, then re-chunk
                // into single-field rows (MVP layout: one field per row after a
                // manual reorder; colSpan still controls width in preview).
                const flat = [];
                (sec.rows || []).forEach((r) => (r.fields || []).forEach((f) => flat.push(f)));
                const idx = flat.findIndex((f) => f.id === fieldId);
                if (idx === -1) continue;
                const target = idx + delta;
                if (target < 0 || target >= flat.length) return;
                [flat[idx], flat[target]] = [flat[target], flat[idx]];
                sec.rows = flat.map((f, i) => ({ id: `${sec.id}_r${i}`, fields: [f] }));
                return;
            }
        });
    }

    handleRemoveField(e) {
        const fieldId = e.detail;
        this.mutateSchema((sections) => {
            for (const sec of sections) {
                for (const row of sec.rows || []) {
                    const i = (row.fields || []).findIndex((f) => f.id === fieldId);
                    if (i !== -1) {
                        row.fields.splice(i, 1);
                        return;
                    }
                }
            }
        });
    }

    handleAddField(e) {
        const sectionId = e.target.dataset.section;
        this.mutateSchema((sections) => {
            const sec = sections.find((s) => s.id === sectionId);
            if (!sec) return;
            const newId = 'f_' + Date.now().toString(36);
            const newRow = {
                id: `${sec.id}_r${(sec.rows || []).length}`,
                fields: [{ id: newId, type: 'text', label: 'New Field', colSpan: 12, required: false }]
            };
            sec.rows = [...(sec.rows || []), newRow];
        });
    }

    // Apply a mutation to a deep clone of the schema, then reassign for reactivity.
    mutateSchema(mutator) {
        const clone = JSON.parse(JSON.stringify(this.schema));
        mutator(clone.sections);
        this.schema = clone;
    }

    async handleSaveSchema() {
        // Guard: never serialize a null schema into the literal string "null",
        // which the server rejects with a confusing "root must be a JSON object".
        if (!this.hasSchema) {
            this.toast('Nothing to save', 'No schema is loaded yet.', 'warning');
            return;
        }
        await this.run(async () => {
            await saveSchema({
                templateId: this.effectiveId,
                schemaJson: JSON.stringify(this.schema)
            });
            await this.reload();
        }, 'Schema saved');
    }

    // ===================================================================
    // 4. PUBLISH / REVERT
    // ===================================================================

    async handlePublish() {
        // Same guard as save: a null/empty schema cannot be published.
        if (!this.hasSchema) {
            this.toast('Cannot publish', 'Load or create a schema first.', 'warning');
            return;
        }
        await this.run(async () => {
            // Save current working schema first so publish validates what's shown.
            await saveSchema({
                templateId: this.effectiveId,
                schemaJson: JSON.stringify(this.schema)
            });
            await publishTemplate({ templateId: this.effectiveId });
            await this.reload();
        }, 'Template published');
    }

    async handleRevert() {
        await this.run(async () => {
            await revertToDraft({ templateId: this.effectiveId });
            await this.reload();
        }, 'Reverted to Draft');
    }

    // ===================================================================
    // PREVIEW model (reuses c/formField, disabled)
    // ===================================================================
    get previewSections() {
        if (!this.hasSchema) return [];
        return this.schema.sections.map((sec) => ({
            id: sec.id,
            title: sec.title,
            rows: (sec.rows || []).map((row) => ({
                id: row.id,
                fields: (row.fields || []).map((f) => ({
                    ...f,
                    key: f.id,
                    isSignature: f.type === 'signature',
                    sizeClass: `slds-col slds-size_${f.colSpan || 12}-of-12`
                }))
            }))
        }));
    }

    // ---- shared action runner --------------------------------------------
    async run(action, successMsg) {
        this.isBusy = true;
        try {
            await action();
            this.toast('Success', successMsg, 'success');
        } catch (error) {
            this.toast('Error', reduceErrors(error).join(', '), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}