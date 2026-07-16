/**
 * FormFinalizeQueueable
 * ----------------------------------------------------------------------------
 * Async Queueable that POSTs an approved submission to the Spring Boot PDF
 * finalization service, then stores the returned ContentVersion id and
 * SHA-256 hash on the submission.
 *
 * NOT USING THE NAMED CREDENTIAL (springboot_Form / springboot_Form_Cred):
 *  Originally this callout went through callout:springboot_Form, with the
 *  X-API-Key header injected via {!$Credential.springboot_Form_Cred.ApiKey}.
 *  That principal was never fully set up in Setup UI, and debugging showed
 *  the NC's generateAuthorizationHeader/merge-field resolution was unreliable
 *  in this org. For MVP speed we bypass it entirely: doFinalizeCallout() hits
 *  the VPS URL literally and hardcodes X-API-Key in Apex. The
 *  springboot_Form / springboot_Form_Cred metadata is currently ORPHANED
 *  (not referenced anywhere) — kept in the repo in case the NC path is
 *  revisited post-MVP, but it does nothing today. Needs real credential
 *  handling (Named Credential or Custom Metadata secret) before production.
 *
 * WHY QUEUEABLE (mirrors FormScanQueueable):
 *  - FormStateMachine.approve() must stay callout-free (established project
 *    principle). The transition DML commits first; this job runs after.
 *  - AllowsCallouts gives us the full 120-second callout timeout.
 *  - A Finalizer guarantees PDF_Status__c is set to Failed if the job dies with
 *    an unhandled exception. No DML runs before the callout in execute() itself —
 *    Salesforce rejects a callout while there is uncommitted work pending
 *    (this was a real bug here: marking PDF_Status__c='Pending' before the
 *    callout threw "You have uncommitted work pending", which was swallowed
 *    by the Finalizer and looked like a silent failure).
 *
 * FLOW:
 *  1. Load the submission + template schema + active signature CV ids.
 *  2. POST to Spring Boot (contract B3) — hardcoded X-API-Key header, direct VPS
 *     URL (MVP simplicity; see note above on the unused Named Credential).
 *  3. On success: store Final_PDF_CV_Id__c, Document_Hash__c, PDF_Status__c=Success.
 *  4. On any error: PDF_Status__c=Failed. Submission stays Approved. Retry is
 *     possible without re-approving by re-enqueuing this queueable.
 *
 * CONTRACT B3 request (strict camelCase — a case mismatch caused a real bug):
 * {
 *   submissionId, schema, data: { values }, signatures: { engineer, supervisor },
 *   salesforceFileApi: { instanceUrl }    ← accessToken intentionally omitted
 * }
 */
public with sharing class FormFinalizeQueueable implements Queueable, Database.AllowsCallouts {

    private final Id submissionId;

    public FormFinalizeQueueable(Id submissionId) {
        this.submissionId = submissionId;
    }

    // -------------------------------------------------------------------------
    // execute
    // -------------------------------------------------------------------------
    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new FinalizeFinalizer(submissionId));

        // No DML before the callout: Salesforce rejects a callout while there is
        // uncommitted work pending in the same transaction. Status starts at
        // whatever it was pre-approval and is only written once, after the callout.
        try {
            // 1. Load everything we need in one go.
            Form_Submission__c sub = [
                SELECT Id, Data_JSON__c, Form_Template__r.Schema_JSON__c,
                       Form_Template__r.Name
                FROM Form_Submission__c
                WHERE Id = :submissionId
                WITH USER_MODE
                LIMIT 1
            ];

            // Active (non-void) signatures, ordered by role for determinism.
            List<Form_Signature__c> sigs = [
                SELECT Signer_Role__c, Image_CV_Id__c, Signed_By__c, Signed_At__c
                FROM Form_Signature__c
                WHERE Form_Submission__c = :submissionId
                  AND Is_Void__c = false
                WITH USER_MODE
            ];

            // 2. Build the B3 request payload.
            String body = buildPayload(sub, sigs);

            // 3. Read settings from Custom Metadata.
            Form_Integration_Setting__mdt setting = Form_Integration_Setting__mdt.getInstance('Default');
            String finalizePath = setting.Finalize_Path__c;

            // 4. Callout. Hits the VPS URL directly (bypasses the Named Credential /
            // External Credential entirely) with a hardcoded API key for MVP
            // simplicity. Need to remove in production.
            HttpResponse res = doFinalizeCallout(
                'https://supdf.suplo.my.id' + finalizePath,
                body,
                120000  // 120-second timeout — PDF gen can be slow on large schemas.
            );

            // 5. Handle response.
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String status = (String) parsed.get('status');
                if ('success'.equals(status)) {
                    String cvId = (String) parsed.get('pdfContentVersionId');
                    String hash = (String) parsed.get('documentHash');
                    markStatus(submissionId, 'Success', cvId, hash);
                    // Isolated: the PDF is already generated and PDF_Status__c
                    // already committed above. A link failure here must not
                    // flip a real success back to Failed.
                    try {
                        linkPdfToSubmission(submissionId, cvId);
                    } catch (Exception linkEx) {
                        System.debug(LoggingLevel.ERROR,
                            'Could not link PDF ContentVersion ' + cvId + ' to '
                            + submissionId + ': ' + linkEx.getMessage());
                    }
                } else {
                    // Spring Boot returned an application-level error body.
                    String errMsg = (String) parsed.get('error');
                    System.debug(LoggingLevel.WARN, 'Finalize error for ' + submissionId + ': ' + errMsg);
                    markStatus(submissionId, 'Failed', null, null);
                }
            } else {
                System.debug(LoggingLevel.WARN,
                    'Finalize callout HTTP ' + res.getStatusCode() + ' for ' + submissionId);
                markStatus(submissionId, 'Failed', null, null);
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'FormFinalizeQueueable exception for ' + submissionId + ': ' + e.getMessage());
            markStatus(submissionId, 'Failed', null, null);
        }
    }

    // -------------------------------------------------------------------------
    // Callout — hardcoded X-API-Key for MVP simplicity. Need to remove in production.
    // -------------------------------------------------------------------------
    private static HttpResponse doFinalizeCallout(String endpoint, String jsonBody, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-API-Key', '4aa3e859eb322ba7d9c6fca96ce6yuni');
        req.setTimeout(timeoutMs);
        req.setBody(jsonBody);
        return new Http().send(req);
    }

    // -------------------------------------------------------------------------
    // Payload builder
    // -------------------------------------------------------------------------
    private static String buildPayload(Form_Submission__c sub, List<Form_Signature__c> sigs) {
        // Build signature map: role -> { contentVersionId, signedBy, signedAt }
        Map<String, Object> sigMap = new Map<String, Object>();
        for (Form_Signature__c s : sigs) {
            sigMap.put(s.Signer_Role__c, new Map<String, Object>{
                'contentVersionId' => s.Image_CV_Id__c,
                'signedBy'         => s.Signed_By__c,
                'signedAt'         => s.Signed_At__c != null
                                        ? s.Signed_At__c.format()
                                        : null
            });
        }

        // Data envelope. Data_JSON__c stores { "values": { fieldId: value } }.
        Object dataObj = String.isNotBlank(sub.Data_JSON__c)
            ? JSON.deserializeUntyped(sub.Data_JSON__c)
            : new Map<String, Object>{ 'values' => new Map<String, Object>() };

        // Schema — send as a parsed object (not a re-encoded string) so Spring Boot
        // receives a proper JSON object, not a JSON-encoded string.
        Object schemaObj = String.isNotBlank(sub.Form_Template__r.Schema_JSON__c)
            ? JSON.deserializeUntyped(sub.Form_Template__r.Schema_JSON__c)
            : new Map<String, Object>();

        // salesforceFileApi: only instanceUrl — Spring Boot auths via OAuth itself.
        String instanceUrl = URL.getOrgDomainUrl().toExternalForm();

        Map<String, Object> payload = new Map<String, Object>{
            'submissionId'       => sub.Id,
            'schema'             => schemaObj,
            'data'               => dataObj,
            'signatures'         => sigMap,
            'salesforceFileApi'  => new Map<String, Object>{
                'instanceUrl' => instanceUrl
            }
        };

        return JSON.serialize(payload);
    }

    // -------------------------------------------------------------------------
    // DML helpers (USER_MODE, FLS-enforced)
    // -------------------------------------------------------------------------
    private static void markStatus(Id subId, String pdfStatus, String cvId, String hash) {
        Form_Submission__c upd = new Form_Submission__c(
            Id            = subId,
            PDF_Status__c = pdfStatus
        );
        if (cvId != null)  upd.Final_PDF_CV_Id__c  = cvId;
        if (hash != null)  upd.Document_Hash__c    = hash;
        update as user new List<Form_Submission__c>{ upd };
    }

    /**
     * Spring Boot creates the PDF ContentVersion standalone (no
     * FirstPublishLocationId) — see SalesforceClient.uploadPdf() comment.
     * Without this link the file exists in Salesforce but is invisible on the
     * record (no Related Files / Notes & Attachments entry). ShareType 'V'
     * (Viewer) + Visibility 'AllUsers' mirrors how a manually uploaded file
     * would be shared.
     */
    private static void linkPdfToSubmission(Id subId, String cvId) {
        ContentVersion cv = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cvId
            WITH USER_MODE
            LIMIT 1
        ];
        insert as user new ContentDocumentLink(
            ContentDocumentId = cv.ContentDocumentId,
            LinkedEntityId    = subId,
            ShareType         = 'V',
            Visibility        = 'AllUsers'
        );
    }

    // -------------------------------------------------------------------------
    // Finalizer — runs in its OWN transaction after the Queueable completes.
    // Flips PDF_Status__c to Failed if the job died with an unhandled exception,
    // so it never stays on "Pending" indefinitely.
    // -------------------------------------------------------------------------
    public class FinalizeFinalizer implements System.Finalizer {
        private final Id submissionId;

        public FinalizeFinalizer(Id submissionId) {
            this.submissionId = submissionId;
        }

        public void execute(System.FinalizerContext fc) {
            if (fc.getResult() == System.ParentJobResult.UNHANDLED_EXCEPTION) {
                try {
                    // without sharing in the Finalizer is intentional: it runs in
                    // a separate system transaction where the original user context
                    // may not apply. We update only the status field — no data read.
                    update new Form_Submission__c(
                        Id            = submissionId,
                        PDF_Status__c = 'Failed'
                    );
                } catch (Exception ignored) {
                    System.debug(LoggingLevel.ERROR,
                        'FinalizeFinalizer could not mark Failed: ' + ignored.getMessage());
                }
            }
        }
    }
}