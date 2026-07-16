/**
 * FormTemplateService
 * ----------------------------------------------------------------------------
 * Service layer for Form_Template__c. Two outbound integrations to n8n:
 *
 *   1) SCAN  (async): user uploads a template file -> Claude Vision extracts a
 *      JSON schema. Vision can take >10s, which is risky for a synchronous,
 *      UI-blocking callout. So scan is fire-via-Queueable; n8n returns the schema
 *      later by calling FormCallbackResource (inbound REST). Correlation is via
 *      Form_Template__c.Scan_Job_Id__c (External Id) + Scan_Status__c.
 *
 *   2) EDIT  (sync): user types a prompt to modify the schema. This is fast
 *      enough to run synchronously so the LWC can show the result immediately.
 *      The edited schema is validated (FormSchemaValidator.validateEdit) BEFORE
 *      being returned/persisted -- Salesforce never trusts raw LLM output.
 *
 * SHARING: `with sharing` -- all entry points are user-initiated from the LWC.
 * SECURITY: SOQL/DML use USER_MODE; callouts use Named Credentials (no secrets
 *           in code); file-size guard from Custom Metadata prevents heap blowups.
 *
 * GOVERNOR NOTES:
 *  - Base64 of the uploaded file is held on the heap during the scan enqueue.
 *    We cap file size via Form_Integration_Setting__mdt.Max_File_Bytes__c
 *    (default 3MB) so base64 (~+33%) stays well under the 6MB sync heap limit.
 *  - The actual callout happens inside the Queueable (async, 12MB heap), giving
 *    extra headroom, but we still guard at entry to fail fast with a clear error.
 */
public with sharing class FormTemplateService {

    // Cached settings record (single default row). Loaded once per transaction.
    private static Form_Integration_Setting__mdt settings {
        get {
            if (settings == null) {
                settings = Form_Integration_Setting__mdt.getInstance('Default');
                if (settings == null) {
                    throw new FormCalloutException('INTERNAL',
                        'Missing Form_Integration_Setting__mdt "Default" record.');
                }
            }
            return settings;
        }
        set;
    }
    
    // =====================================================================
    // READ / CREATE / EDIT / PUBLISH (builder support)
    // =====================================================================

    /** DTO for templatebuilder LWC: everything needed in one round-trip. */
    public class TemplateView {
        @AuraEnabled public Id templateId;
        @AuraEnabled public String name;
        @AuraEnabled public String status;  //Draft|Published|Archived
        @AuraEnabled public String scanStatus; //Pending|Processing|Success|Failed
        @AuraEnabled public Integer version;
        @AuraEnabled public String schemaJson;
        @AuraEnabled public String sourceFileCvId;
    }

    /**
     * load template builder. cacheable = true so in can be @wire'd. the builder is also polls
     * uncached variant (getTemplateStatus) during scan
     */
    @AuraEnabled(cacheable = true)
    public static TemplateView getTemplateView(Id templateId) {
        if (templateId == null) {
            return null;
        }
        Form_Template__c t = [SELECT Id, Name, Status__c, Scan_Status__c, Template_Version__c, Schema_JSON__c, Source_File_CV_Id__c
                                    FROM Form_Template__c WHERE Id = :templateId LIMIT 1];
        return toView(t);
    }

    /**
     * uncached status read for polling during async scan. the builder calls this on interval
     * Cacheable would return stale data, so it is not cached.
     * Return just the fields the poller needs (status + schema once ready)
     */
    @AuraEnabled
    public static TemplateView getTemplateStatus(Id templateId) {
        return getTemplateViewUncached(templateId);
    }

    // create a new draft template and return its Id
    @AuraEnabled
    public static Id createTemplate(String name) {
        try {
            Form_Template__c t = new Form_Template__c(Name = String.isBlank(name) ? 'Untitled Template' : name, 
                                                        Status__c = 'Draft', Template_Version__c = 1, 
                                                        Scan_Status__c = 'Pending');
                                                    
            insert as user new List<Form_Template__c>{t};
            return t.Id;
        } catch (Exception e) {
            throw new AuraHandledException ('Can not create template: ==>> ' + e.getMessage());
        }
    }

     /**
     * Persist a manually-edited schema. Validates structure authoritatively and
     * guards the Long Text Area cap. Editing is only allowed while Draft -- a
     * Published template is locked (use revertToDraft to edit further).
     */
    @AuraEnabled
    public static void saveSchema(Id templateId, String schemaJson) {
        try {
            //defense null for schema. 
            if (String.isBlank(schemaJson) || schemaJson == 'null') {
                throw new FormCalloutException ('VALIDATION_FAILED', 'No schema provided to save (builder not have loaded schema yet!)');
            }
            Form_Template__c t = loadForEdit(templateId);
            // AUTHORITATIVE structural validation (same gate as scan/AI paths).
            FormSchemaValidator.validateNew(schemaJson);
            assertSchemaLength(schemaJson);
            t.Schema_JSON__c = schemaJson;
            update as user new List<Form_Template__c>{ t };
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not save schema: ' + e.getMessage());
        }
    }

    /**
     * Publish a template: validate it has a usable schema, then set Published.
     * Version is NOT incremented on first publish from Draft; it increments only
     * when re-publishing after a revertToDraft (i.e. a genuine new version).
     */
    @AuraEnabled
    public static void publishTemplate(Id templateId) {
        try {
            Form_Template__c t = [
                SELECT Id, Status__c, Schema_JSON__c, Template_Version__c
                FROM Form_Template__c
                WHERE Id = :templateId
                WITH USER_MODE
                LIMIT 1
            ];
            if (String.isBlank(t.Schema_JSON__c)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Cannot publish a template with no schema.');
            }
            // Final authoritative validation before it becomes fillable.
            FormSchemaValidator.validateNew(t.Schema_JSON__c);

            t.Status__c = 'Published';
            update as user new List<Form_Template__c>{ t };
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not publish: ' + e.getMessage());
        }
    }

    /**
     * Revert a Published template to Draft to edit it, bumping the version so the
     * next publish represents a new version. Existing submissions are unaffected:
     * they stored Template_Version__c at fill time and (Pilihan A) are never
     * re-rendered from the template.
     */
    @AuraEnabled
    public static void revertToDraft(Id templateId) {
        try {
            Form_Template__c t = [
                SELECT Id, Status__c, Template_Version__c
                FROM Form_Template__c
                WHERE Id = :templateId
                WITH USER_MODE
                LIMIT 1
            ];
            if (t.Status__c != 'Published') {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Only Published templates can be reverted. Current: ' + t.Status__c);
            }
            t.Status__c = 'Draft';
            t.Template_Version__c = (t.Template_Version__c ?? 1) + 1;
            update as user new List<Form_Template__c>{ t };
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not revert: ' + e.getMessage());
        }
    }



 


    //----- builder internals -----------------------------------------------------------------------------
   
    /* load a template and assert it is editable (draft). Share by edit pahts*/
    private static Form_Template__c loadForEdit(Id templateId) {
        Form_Template__c t = [ SELECT Id, Status__c, Schema_JSON__c FROM Form_Template__c WHERE Id = :templateId LIMIT 1 ];
        if (t.Status__c == 'Published') {
            throw new FormCalloutException('VALIDATION_FAILED', 'Template is Published and locked. Revert draft to Edit!');
        } 
        return t;
    }   
   
    private static TemplateView getTemplateViewUncached(Id templateId) {
        if (templateId == null) {
            return null;
        }

        Form_Template__c t = [SELECT Id, Name, Status__c, Scan_Status__c, Template_Version__c, Schema_JSON__c, Source_File_CV_Id__c 
                                    FROM Form_Template__c WHERE Id = :templateId LIMIT 1];
        return toView(t);
    }    
    
    private static TemplateView toView(Form_Template__c t) {
        TemplateView  v = new TemplateView();
        v.templateId = t.Id;
        v.name = t.name;
        v.status = t.Status__c;
        v.scanStatus = t.Scan_Status__c;
        v.version = (t.Template_Version__c == null) ? 1 : Integer.valueOf(t.Template_Version__c);
        v.schemaJson = t.Schema_JSON__c;
        v.sourceFileCvId = t.Source_File_CV_Id__c;
        return v;
    }



    // =====================================================================
    // SCAN (async)
    // =====================================================================

    /**
     * Entry point from LWC. Validates the uploaded ContentVersion, marks the
     * template as Processing, generates a correlation jobId, and enqueues the
     * callout. Returns the jobId so the UI can poll Scan_Status__c.
     *
     * @param templateId        the Form_Template__c being scanned
     * @param contentVersionId  the uploaded PDF/JPEG/PNG ContentVersion Id
     * @return the generated scan job id (also stored on the template)
     */
    @AuraEnabled
    public static String startScan(Id templateId, Id contentVersionId) {
        try {
            // Load the file. VersionData is a Blob on the heap -> size-guard first
            // using ContentSize (cheap field) before materializing base64.
            List<ContentVersion> cvs = [
                SELECT Id, ContentSize, FileType, FileExtension, VersionData
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
            if (cvs.isEmpty()) {
                throw new FormCalloutException('VALIDATION_FAILED', 'Uploaded file not found or not accessible.');
            }
            ContentVersion cv = cvs[0];

            // Guard: reject oversized files BEFORE base64 (heap protection).
            Integer maxBytes = (settings.Max_File_Bytes__c == null)
                ? 3000000 : Integer.valueOf(settings.Max_File_Bytes__c);
            if (cv.ContentSize > maxBytes) {
                throw new FormCalloutException('FILE_TOO_LARGE',
                    'File is ' + cv.ContentSize + ' bytes; limit is ' + maxBytes
                    + '. Use a smaller file or the file-pull integration path.');
            }

            // Derive a stable correlation id for the async callback.
            String jobId = 'scan_' + generateShortId();

            // Mark template as Processing and store the job id (External Id) so the
            // inbound callback can locate this record.
            Form_Template__c tpl = new Form_Template__c(
                Id = templateId,
                Scan_Job_Id__c = jobId,
                Scan_Status__c = 'Processing',
                Source_File_CV_Id__c = contentVersionId
            );
            update as user new List<Form_Template__c>{ tpl };

            // Base64-encode the file for inline transport (MVP path, <=3MB).
            String fileBase64 = EncodingUtil.base64Encode(cv.VersionData);
            String mimeType = resolveMimeType(cv.FileType, cv.FileExtension);

            // Enqueue the callout. Queueable runs in async context (12MB heap,
            // 60s CPU) and is allowed to make callouts because it implements
            // Database.AllowsCallouts.
            System.enqueueJob(new FormScanQueueable(
                templateId, jobId, contentVersionId, mimeType, fileBase64,
                buildCallbackUrl(),
                settings.Scan_Path__c,
                resolveTimeout()
            ));

            return jobId;
        } catch (FormCalloutException fce) {
            // Translate to an AuraHandledException so the LWC sees a clean message.
            throw new AuraHandledException(fce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unexpected error starting scan: ' + e.getMessage());
        }
    }

    // =====================================================================
    // EDIT (sync)
    // =====================================================================

    /**
     * Synchronously asks n8n to apply a natural-language edit to the current
     * schema, validates the result against the prior schema (id-immutability +
     * structural rules), persists it, and returns the new schema to the LWC.
     *
     * @param templateId  template whose Schema_JSON__c is edited
     * @param prompt      the user's natural-language instruction
     * @return the validated, persisted schema JSON
     */
    @AuraEnabled
    public static String applyAiEdit(Id templateId, String prompt) {
        if (String.isBlank(prompt)) {
            throw new AuraHandledException('Prompt cannot be empty.');
        }
        try {
            // Load current schema (source of the edit).
            Form_Template__c tpl = [
                SELECT Id, Schema_JSON__c
                FROM Form_Template__c
                WHERE Id = :templateId
                WITH USER_MODE
                LIMIT 1
            ];
            if (String.isBlank(tpl.Schema_JSON__c)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Template has no schema yet; scan or create one first.');
            }

            // Build request per contract B2.
            Map<String, Object> body = new Map<String, Object>{
                'templateId'    => templateId,
                'currentSchema' => JSON.deserializeUntyped(tpl.Schema_JSON__c),
                'prompt'        => prompt
            };

            // DEBUG: confirm the outbound request body is non-null/non-blank
            // before the callout. Inspect these in the debug log if n8n reports
            // "Request body must be a JSON object".
            String requestBody = JSON.serialize(body);
            System.debug(LoggingLevel.INFO, 'applyAiEdit >> templateId=' + templateId);
            System.debug(LoggingLevel.INFO, 'applyAiEdit >> prompt=' + prompt);
            System.debug(LoggingLevel.INFO, 'applyAiEdit >> requestBody isBlank=' + String.isBlank(requestBody)
                + ' length=' + (requestBody == null ? 0 : requestBody.length()));
            System.debug(LoggingLevel.INFO, 'applyAiEdit >> requestBody=' + requestBody);

/*
            HttpResponse res = doCallout(
                'callout:n8n_Form' + settings.Edit_Path__c,
                JSON.serialize(body),
                resolveTimeout()
            );
*/  
            HttpResponse res = doCallout(
                'https://n3n3n.suplo.my.id/webhook/schema-edit', 
                 requestBody, 
                 resolveTimeout()
            );

            // DEBUG: confirm what n8n returned (status + raw body).
            System.debug(LoggingLevel.INFO, 'applyAiEdit << HTTP ' + res.getStatusCode());
            System.debug(LoggingLevel.INFO, 'applyAiEdit << responseBody=' + res.getBody());


            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                throw new FormCalloutException('INTERNAL',
                    'n8n edit returned HTTP ' + res.getStatusCode());
            }

            // An empty 2xx body means n8n aborted before reaching a Respond node
            // (e.g. the Claude call or a Code node threw). Fail with a clear
            // message instead of a cryptic JSON "end of input" parse error.
            if (String.isBlank(res.getBody())) {
                throw new FormCalloutException('INTERNAL',
                    'n8n edit returned HTTP ' + res.getStatusCode()
                    + ' with an empty body. The workflow likely errored before its '
                    + 'Respond to Webhook node (check the Call Claude node / n8n execution log).');
            }

            // Parse contract response { status, schema, changes, error }.
            Map<String, Object> parsed =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String status = (String) parsed.get('status');
            if (status != 'success') {
                String err = (String) parsed.get('error');
                throw new FormCalloutException('VALIDATION_FAILED',
                    'AI edit failed: ' + (err == null ? 'unknown error' : err));
            }

            String newSchemaJson = JSON.serialize(parsed.get('schema'));

            // AUTHORITATIVE re-validation: even though n8n validates, SF must not
            // trust it. validateEdit enforces id-immutability vs the old schema.
            FormSchemaValidator.validateEdit(newSchemaJson, tpl.Schema_JSON__c);

            // Guard Long Text Area cap (131072) before DML to fail with a clear
            // message instead of a STRING_TOO_LONG DML error.
            assertSchemaLength(newSchemaJson);

            tpl.Schema_JSON__c = newSchemaJson;
            update as user new List<Form_Template__c>{ tpl };

            return newSchemaJson;
        } catch (FormCalloutException fce) {
            throw new AuraHandledException(fce.getMessage());
        } catch (CalloutException ce) {
            throw new AuraHandledException('Could not reach n8n: ' + ce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unexpected error during AI edit: ' + e.getMessage());
        }
    }

    // =====================================================================
    // Shared helpers (also used by FormScanQueueable / FormCallbackResource)
    // =====================================================================

    /** Single place that performs an HTTP POST with the configured timeout. */
    public static HttpResponse doCallout(String endpoint, String jsonBody, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);

        String credentials = EncodingUtil.base64Encode(Blob.valueOf('n3n:Kampret#1.')); //temporary hardcoded credentials for MVP simplicity. Need to remove in production.
        
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Basic '+credentials); // create this statement to accomodate credentials.
        req.setTimeout(timeoutMs);
        req.setBody(jsonBody);
        return new Http().send(req);
    }

    /** Reads timeout from Custom Metadata, clamped to the platform max (120000). */
    public static Integer resolveTimeout() {
        Integer t = (settings.Callout_Timeout_Ms__c == null)
            ? 120000 : Integer.valueOf(settings.Callout_Timeout_Ms__c);
        return Math.min(t, 120000);
    }

    /** Validates schema string length against the Long Text Area storage cap. */
    public static void assertSchemaLength(String schemaJson) {
        // 131072 is the Long Text Area max for Schema_JSON__c (MVP storage choice).
        if (schemaJson != null && schemaJson.length() > 131072) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Schema exceeds 131072 characters and cannot be stored in the Long Text Area. '
                + 'Simplify the template or migrate schema storage to a file.');
        }
    }

    /** Absolute callback URL n8n will POST the scan result to (contract B1). */
    private static String buildCallbackUrl() {
        // Apex REST base for this org + our resource URI mapping (see FormCallbackResource).
        return URL.getOrgDomainUrl().toExternalForm()
            + '/services/apexrest/formschema/v1/callback';
    }

    /** Map Salesforce FileType/extension to a MIME type for the Vision request. */
    private static String resolveMimeType(String fileType, String ext) {
        String e = (ext == null ? '' : ext.toLowerCase());
        if (e == 'pdf') return 'application/pdf';
        if (e == 'png') return 'image/png';
        if (e == 'jpg' || e == 'jpeg') return 'image/jpeg';
        // Fall back to a reasonable default; n8n can also sniff content.
        return 'application/octet-stream';
    }

    /** Short, collision-resistant id fragment for correlation (not security-sensitive). */
    private static String generateShortId() {
        // 8 hex chars from a crypto-random blob -> ~4 billion space, fine for correlation.
        Blob b = Crypto.generateAesKey(128);
        return EncodingUtil.convertToHex(b).substring(0, 8);
    }
}