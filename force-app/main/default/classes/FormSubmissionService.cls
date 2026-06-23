/**
 * FormSubmissionService
 * ----------------------------------------------------------------------------
 * Service layer for Form_Submission__c. Orchestrates the fill -> sign -> submit
 * -> approve/reject lifecycle. It is intentionally THIN over FormStateMachine:
 * all status-transition RULES live in the state machine; this class handles data
 * persistence, signature records, and completeness checks, then delegates the
 * transition.
 *
 * SHARING: `with sharing` -- every method is a user-initiated UI action.
 * SECURITY: USER_MODE on all SOQL/DML.
 *
 * PHASE 2 NOTE:
 *  approve() is where the Spring Boot PDF finalize callout will be invoked AFTER
 *  the transition commits. It is deliberately absent now (Spring Boot deferred).
 *  The exact insertion point is marked `// === PHASE 2: FINALIZE PDF ===`.
 */
public with sharing class FormSubmissionService {

    // =====================================================================
    // READ (for the LWC fill-mode renderer)
    // =====================================================================

    /**
     * DTO returned to the LWC: everything the renderer needs in one round-trip --
     * the template schema, current answer data, status, and the active signatures
     * by role. cacheable=true so it can be @wire'd; refreshApex after mutations.
     */
    public class SubmissionView {
        @AuraEnabled public Id submissionId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer revisionNumber;
        @AuraEnabled public String rejectionComment;
        @AuraEnabled public String schemaJson;   // from the template
        @AuraEnabled public String dataJson;      // current answers
        @AuraEnabled public Map<String, String> signatureImageByRole; // role -> ContentVersion Id (active only)
    }

    /**
     * Load a submission with its template schema and active signatures.
     * @param submissionId the submission to view/fill
     */
    @AuraEnabled(cacheable=true)
    public static SubmissionView getSubmissionView(Id submissionId) {
        if (submissionId == null) return null;

        Form_Submission__c sub = [
            SELECT Id, Status__c, Revision_Number__c, Rejection_Comment__c, Data_JSON__c,
                   Form_Template__r.Schema_JSON__c
            FROM Form_Submission__c
            WHERE Id = :submissionId
            WITH USER_MODE
            LIMIT 1
        ];

        SubmissionView v = new SubmissionView();
        v.submissionId      = sub.Id;
        v.status            = sub.Status__c;
        v.revisionNumber    = (sub.Revision_Number__c == null) ? 0 : Integer.valueOf(sub.Revision_Number__c);
        v.rejectionComment  = sub.Rejection_Comment__c;
        v.schemaJson        = sub.Form_Template__r.Schema_JSON__c;
        v.dataJson          = sub.Data_JSON__c;

        v.signatureImageByRole = new Map<String, String>();
        for (Form_Signature__c s : [
            SELECT Signer_Role__c, Image_CV_Id__c
            FROM Form_Signature__c
            WHERE Form_Submission__c = :submissionId
              AND Is_Void__c = false
            WITH USER_MODE
        ]) {
            v.signatureImageByRole.put(s.Signer_Role__c, s.Image_CV_Id__c);
        }
        return v;
    }

    // =====================================================================
    // CREATE / FILL
    // =====================================================================

    /**
     * Create a new Draft submission for a published template, stamping the
     * template version in use (audit reference; Pilihan A = no re-render).
     *
     * @param templateId a Published Form_Template__c
     * @return the new submission Id
     */
    @AuraEnabled
    public static Id createSubmission(Id templateId) {
        try {
            Form_Template__c tpl = [
                SELECT Id, Status__c, Template_Version__c
                FROM Form_Template__c
                WHERE Id = :templateId
                WITH USER_MODE
                LIMIT 1
            ];
            // Only published templates can be filled.
            if (tpl.Status__c != 'Published') {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Template must be Published before it can be filled.');
            }

            Form_Submission__c sub = new Form_Submission__c(
                Form_Template__c   = templateId,
                Template_Version__c = tpl.Template_Version__c,
                Status__c          = FormStateMachine.DRAFT,
                Engineer__c        = UserInfo.getUserId(),  // creator fills as engineer
                Revision_Number__c = 0
            );
            insert as user sub;
            return sub.Id;
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not create submission: ' + e.getMessage());
        }
    }

    /**
     * Save answer data to a Draft submission. Stores the flat fieldId->value map
     * as JSON. Does NOT transition status -- save is autosave-friendly.
     *
     * @param submissionId target submission (must be Draft)
     * @param dataJson     Data_JSON per contract (values map, etc.)
     */
    @AuraEnabled
    public static void saveData(Id submissionId, String dataJson) {
        try {
            Form_Submission__c sub = [
                SELECT Id, Status__c
                FROM Form_Submission__c
                WHERE Id = :submissionId
                WITH USER_MODE
                LIMIT 1
            ];
            if (sub.Status__c != FormStateMachine.DRAFT) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Only Draft submissions can be edited.');
            }
            // Guard Long Text Area cap before DML.
            if (dataJson != null && dataJson.length() > 131072) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Submission data exceeds 131072 characters.');
            }
            sub.Data_JSON__c = dataJson;
            update as user new List<Form_Submission__c>{ sub };
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not save data: ' + e.getMessage());
        }
    }

    // =====================================================================
    // SIGNATURES
    // =====================================================================

    /**
     * Record a signature for a submission. The signature PNG is expected to be
     * already uploaded as a ContentVersion by the LWC; we store the pointer +
     * audit metadata. Replaces any prior non-void signature for the same role
     * (e.g. engineer re-signs after a revision) by voiding the old one.
     *
     * @param submissionId    the submission
     * @param signerRole      'engineer' | 'supervisor'
     * @param fieldId         schema signature field id (e.g. f_sig_engineer)
     * @param imageCvId       ContentVersion Id of the signature PNG
     */
    @AuraEnabled
    public static Id recordSignature(Id submissionId, String signerRole, String fieldId, Id imageCvId) {
        try {
            if (signerRole != 'engineer' && signerRole != 'supervisor') {
                throw new FormCalloutException('VALIDATION_FAILED', 'Invalid signerRole.');
            }

            // Void any existing live signature for this role so there is at most
            // one active signature per role. Query outside loop -> bulk-safe.
            List<Form_Signature__c> existing = [
                SELECT Id, Is_Void__c
                FROM Form_Signature__c
                WHERE Form_Submission__c = :submissionId
                  AND Signer_Role__c = :signerRole
                  AND Is_Void__c = false
                WITH USER_MODE
            ];
            for (Form_Signature__c s : existing) {
                s.Is_Void__c = true;
            }
            if (!existing.isEmpty()) {
                update as user existing;
            }

            Form_Signature__c sig = new Form_Signature__c(
                Form_Submission__c = submissionId,
                Signer_Role__c     = signerRole,
                Field_Id__c        = fieldId,
                Signed_By__c       = UserInfo.getUserId(),
                Signed_At__c       = System.now(),
                Image_CV_Id__c     = imageCvId,
                Is_Void__c         = false
            );
            insert as user sig;
            return sig.Id;
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not record signature: ' + e.getMessage());
        }
    }

    // =====================================================================
    // STATE TRANSITIONS (delegate to FormStateMachine)
    // =====================================================================

    /**
     * Engineer submits. Pre-checks completeness (required fields filled + engineer
     * signature present) BEFORE asking the state machine to transition.
     */
    @AuraEnabled
    public static void submit(Id submissionId) {
        try {
            assertReadyForSubmit(submissionId);
            FormStateMachine.submit(submissionId);
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not submit: ' + e.getMessage());
        }
    }

    /**
     * Supervisor approves. Expects the supervisor signature to be recorded first.
     * Transitions to Approved via the state machine.
     */
    @AuraEnabled
    public static void approve(Id submissionId) {
        try {
            // Require a live supervisor signature before approval.
            assertSignaturePresent(submissionId, 'supervisor');

            FormStateMachine.approve(submissionId, UserInfo.getUserId());

            // === PHASE 2: FINALIZE PDF ===
            // After the Approved transition commits, enqueue the Spring Boot
            // finalize callout (build payload from schema + Data_JSON +
            // signature ContentVersion ids, POST to callout:springboot_Form +
            // Finalize_Path__c, store returned pdfContentVersionId + documentHash
            // on the submission). Deferred until Spring Boot exists.
            // Implementation will mirror FormScanQueueable (Queueable + callout).
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not approve: ' + e.getMessage());
        }
    }

    /** Supervisor rejects with a mandatory comment. State machine voids signatures. */
    @AuraEnabled
    public static void reject(Id submissionId, String comment) {
        try {
            FormStateMachine.reject(submissionId, UserInfo.getUserId(), comment);
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not reject: ' + e.getMessage());
        }
    }

    /** Engineer reopens a Rejected submission to Draft for revision. */
    @AuraEnabled
    public static void reopenForRevision(Id submissionId) {
        try {
            FormStateMachine.reopenForRevision(submissionId);
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not reopen: ' + e.getMessage());
        }
    }

    // =====================================================================
    // Completeness checks
    // =====================================================================

    /**
     * Verify the submission is fillable-complete: every required field has a
     * value in Data_JSON, and the engineer signature exists. Reads the template
     * schema to know which fields are required.
     */
    private static void assertReadyForSubmit(Id submissionId) {
        Form_Submission__c sub = [
            SELECT Id, Status__c, Data_JSON__c, Form_Template__c
            FROM Form_Submission__c
            WHERE Id = :submissionId
            WITH USER_MODE
            LIMIT 1
        ];
        if (sub.Status__c != FormStateMachine.DRAFT) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Only Draft submissions can be submitted.');
        }

        Form_Template__c tpl = [
            SELECT Id, Schema_JSON__c
            FROM Form_Template__c
            WHERE Id = :sub.Form_Template__c
            WITH USER_MODE
            LIMIT 1
        ];

        Set<String> requiredFieldIds = extractRequiredFieldIds(tpl.Schema_JSON__c);
        Map<String, Object> values = extractValues(sub.Data_JSON__c);

        List<String> missing = new List<String>();
        for (String reqId : requiredFieldIds) {
            Object v = values.get(reqId);
            // Unfilled if: null, blank string, or empty list (e.g. a required
            // table with zero rows). Numbers/booleans always count as filled.
            Boolean unfilled =
                v == null
                || (v instanceof String && String.isBlank((String) v))
                || (v instanceof List<Object> && ((List<Object>) v).isEmpty());
            if (unfilled) {
                missing.add(reqId);
            }
        }
        if (!missing.isEmpty()) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Required fields are empty: ' + String.join(missing, ', '));
        }

        assertSignaturePresent(submissionId, 'engineer');
    }

    /** Throw unless a live (non-void) signature exists for the given role. */
    private static void assertSignaturePresent(Id submissionId, String role) {
        Integer count = [
            SELECT COUNT()
            FROM Form_Signature__c
            WHERE Form_Submission__c = :submissionId
              AND Signer_Role__c = :role
              AND Is_Void__c = false
            WITH USER_MODE
        ];
        if (count == 0) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Missing ' + role + ' signature.');
        }
    }

    // ------------------------------------------------------------------
    // schema/data parsing helpers
    // ------------------------------------------------------------------

    /** Collect ids of fields flagged required:true (signatures excluded -- they
     *  are checked separately via signature records, not Data_JSON). */
    private static Set<String> extractRequiredFieldIds(String schemaJson) {
        Set<String> req = new Set<String>();
        if (String.isBlank(schemaJson)) return req;
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(schemaJson);
        Object sectionsObj = schema.get('sections');
        if (!(sectionsObj instanceof List<Object>)) return req;
        for (Object secO : (List<Object>) sectionsObj) {
            Map<String, Object> sec = (Map<String, Object>) secO;
            Object rowsO = sec.get('rows');
            if (!(rowsO instanceof List<Object>)) continue;
            for (Object rowO : (List<Object>) rowsO) {
                Map<String, Object> row = (Map<String, Object>) rowO;
                Object fieldsO = row.get('fields');
                if (!(fieldsO instanceof List<Object>)) continue;
                for (Object fO : (List<Object>) fieldsO) {
                    Map<String, Object> f = (Map<String, Object>) fO;
                    Boolean isRequired = f.get('required') == true;
                    String type = (String) f.get('type');
                    if (isRequired && type != 'signature') {
                        req.add((String) f.get('id'));
                    }
                }
            }
        }
        return req;
    }

    /** Pull the values map out of Data_JSON. */
    private static Map<String, Object> extractValues(String dataJson) {
        if (String.isBlank(dataJson)) return new Map<String, Object>();
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(dataJson);
        Object valuesO = data.get('values');
        return (valuesO instanceof Map<String, Object>)
            ? (Map<String, Object>) valuesO
            : new Map<String, Object>();
    }
}
