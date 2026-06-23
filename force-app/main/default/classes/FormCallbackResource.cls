/**
 * FormCallbackResource
 * ----------------------------------------------------------------------------
 * Inbound REST endpoint that n8n calls to deliver the result of an async Vision
 * scan (contract B1 async callback).
 *
 *   URL:    /services/apexrest/formschema/v1/callback
 *   METHOD: POST
 *   BODY:   { jobId, templateId, status:"success"|"error", schema?, error? }
 *
 * RESPONSIBILITIES:
 *  - Correlate the callback to a template via Scan_Job_Id__c (External Id).
 *  - On success: AUTHORITATIVELY validate the schema (never trust the LLM/n8n),
 *    persist it, set Scan_Status__c = Success.
 *  - On error: set Scan_Status__c = Failed.
 *  - Always return a clean JSON ack with a proper HTTP status; never leak stack
 *    traces to the caller.
 *
 * SECURITY:
 *  - `with sharing`. Inbound Apex REST runs as the integration user that
 *    authenticated; that user must have FLS/CRUD on the fields (granted via the
 *    permission set). USER_MODE DML enforces this.
 *  - AuthN/AuthZ of the caller itself is handled by Salesforce (the request must
 *    carry a valid session/OAuth token for an authorized user). The API key used
 *    on the OUTBOUND leg is separate; do not confuse the two. For MVP, n8n calls
 *    back using a Connected App / integration user credential.
 *
 * IDEMPOTENCY:
 *  - Keyed on jobId. If n8n retries the same jobId, we simply re-apply the same
 *    result; the operation is naturally idempotent (same schema -> same state).
 */
@RestResource(urlMapping='/formschema/v1/callback')
global with sharing class FormCallbackResource {

    // Response shape returned to n8n.
    global class CallbackAck {
        global String status;     // 'ok' | 'error'
        global String message;
        global String templateId;
    }

    @HttpPost
    global static CallbackAck handleCallback() {
        RestResponse response = RestContext.response;
        CallbackAck ack = new CallbackAck();

        try {
            // Parse body.
            String rawBody = RestContext.request.requestBody != null
                ? RestContext.request.requestBody.toString() : '';
            if (String.isBlank(rawBody)) {
                return badRequest(ack, 'Empty request body.');
            }

            Map<String, Object> payload =
                (Map<String, Object>) JSON.deserializeUntyped(rawBody);

            String jobId      = asString(payload.get('jobId'));
            String status     = asString(payload.get('status'));

            if (String.isBlank(jobId)) {
                return badRequest(ack, 'Missing jobId.');
            }

            // Locate the template by the correlation id (External Id field).
            // USER_MODE: the integration user must be able to see/edit it.
            List<Form_Template__c> tpls = [
                SELECT Id, Scan_Status__c, Schema_JSON__c
                FROM Form_Template__c
                WHERE Scan_Job_Id__c = :jobId
                WITH USER_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                response.statusCode = 404;
                ack.status = 'error';
                ack.message = 'No template found for jobId ' + jobId;
                return ack;
            }
            Form_Template__c tpl = tpls[0];
            ack.templateId = tpl.Id;

            if (status == 'success') {
                applySuccess(tpl, payload);
                response.statusCode = 200;
                ack.status = 'ok';
                ack.message = 'Schema stored.';
            } else {
                // status 'error' (or anything not 'success') -> mark Failed.
                String err = asString(payload.get('error'));
                tpl.Scan_Status__c = 'Failed';
                update as user new List<Form_Template__c>{ tpl };
                response.statusCode = 200; // we accepted the callback even though scan failed
                ack.status = 'ok';
                ack.message = 'Scan failure recorded: ' + (err == null ? 'unspecified' : err);
            }
            return ack;

        } catch (FormCalloutException fce) {
            // Validation of the returned schema failed -> 422, mark template Failed.
            response.statusCode = 422;
            ack.status = 'error';
            ack.message = fce.getMessage();
            markFailedQuietly(asJobId());
            return ack;
        } catch (Exception e) {
            // Never leak internals; return a generic 500.
            response.statusCode = 500;
            ack.status = 'error';
            ack.message = 'Internal error processing callback.';
            System.debug(LoggingLevel.ERROR, 'Callback error: ' + e.getMessage());
            return ack;
        }
    }

    /** Validate + persist the schema from a successful scan. */
    private static void applySuccess(Form_Template__c tpl, Map<String, Object> payload) {
        Object schemaObj = payload.get('schema');
        if (schemaObj == null) {
            throw new FormCalloutException('VISION_PARSE_FAILED',
                'Success status but no schema in callback.');
        }
        String schemaJson = JSON.serialize(schemaObj);

        // AUTHORITATIVE validation -- the whole reason this gate exists.
        FormSchemaValidator.validateNew(schemaJson);

        // Long Text Area cap guard.
        FormTemplateService.assertSchemaLength(schemaJson);

        tpl.Schema_JSON__c = schemaJson;
        tpl.Scan_Status__c = 'Success';
        update as user new List<Form_Template__c>{ tpl };
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private static CallbackAck badRequest(CallbackAck ack, String msg) {
        RestContext.response.statusCode = 400;
        ack.status = 'error';
        ack.message = msg;
        return ack;
    }

    /** Best-effort failure flip when validation throws mid-processing. */
    private static void markFailedQuietly(String jobId) {
        if (String.isBlank(jobId)) return;
        try {
            List<Form_Template__c> tpls = [
                SELECT Id FROM Form_Template__c
                WHERE Scan_Job_Id__c = :jobId WITH USER_MODE LIMIT 1
            ];
            if (!tpls.isEmpty()) {
                tpls[0].Scan_Status__c = 'Failed';
                update as user tpls;
            }
        } catch (Exception ignored) {
            System.debug(LoggingLevel.ERROR, 'markFailedQuietly failed: ' + ignored.getMessage());
        }
    }

    /** Re-read jobId from the current request body (used only in catch blocks). */
    private static String asJobId() {
        try {
            Map<String, Object> p =
                (Map<String, Object>) JSON.deserializeUntyped(
                    RestContext.request.requestBody.toString());
            return asString(p.get('jobId'));
        } catch (Exception e) {
            return null;
        }
    }

    private static String asString(Object o) {
        return (o instanceof String) ? (String) o : null;
    }
}
