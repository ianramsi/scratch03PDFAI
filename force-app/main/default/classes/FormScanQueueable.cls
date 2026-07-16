/**
 * FormScanQueueable
 * ----------------------------------------------------------------------------
 * Performs the asynchronous Claude Vision scan callout to n8n, off the UI thread.
 *
 * WHY QUEUEABLE (not @future, not sync):
 *  - Vision extraction is slow and variable; a sync UI callout risks timeout and
 *    freezes the LWC. Queueable runs async (12MB heap, 60s CPU) and can make
 *    callouts via Database.AllowsCallouts.
 *  - @future is rejected (can't carry typed state cleanly, no Finalizer, 50/txn
 *    cap). Queueable is the modern choice.
 *
 * FLOW:
 *  1. POST file (base64) + callbackUrl to n8n (contract B1). n8n returns a quick
 *     ACK; the real schema arrives later at FormCallbackResource.
 *  2. If n8n does NOT ACK 2xx, we mark the template Scan_Status__c = Failed now,
 *     so the UI doesn't hang on Processing.
 *  3. A Finalizer guarantees that if the job dies UNHANDLED (e.g. uncaught
 *     limit exception), we still flip the template to Failed. Without this, a
 *     crashed job would leave the template stuck in Processing forever.
 *
 * IMPORTANT: a Finalizer runs in its OWN transaction AFTER the job, so its DML
 * is independent. That is exactly why it can record failure even when the main
 * job transaction rolled back.
 */
public with sharing class FormScanQueueable implements Queueable, Database.AllowsCallouts {

    private final Id templateId;
    private final String jobId;
    private final Id contentVersionId;
    private final String mimeType;
    private final String fileBase64;
    private final String callbackUrl;
    private final String scanPath;
    private final Integer timeoutMs;

    public FormScanQueueable(
        Id templateId, String jobId, Id contentVersionId, String mimeType,
        String fileBase64, String callbackUrl, String scanPath, Integer timeoutMs
    ) {
        this.templateId = templateId;
        this.jobId = jobId;
        this.contentVersionId = contentVersionId;
        this.mimeType = mimeType;
        this.fileBase64 = fileBase64;
        this.callbackUrl = callbackUrl;
        this.scanPath = scanPath;
        this.timeoutMs = timeoutMs;
    }

    public void execute(QueueableContext ctx) {
        // Attach a Finalizer so a hard failure still updates Scan_Status__c.
        System.attachFinalizer(new ScanFinalizer(templateId, jobId));

        // Build request body per contract B1.
        Map<String, Object> body = new Map<String, Object>{
            'templateId'            => templateId,
            'fileContentVersionId'  => contentVersionId,
            'fileMimeType'          => mimeType,
            'fileBase64'            => fileBase64,
            'callbackUrl'           => callbackUrl,
            'jobId'                 => jobId
        };

/*        
        HttpResponse res = FormTemplateService.doCallout(
            'callout:n8n_Form' + scanPath,
            JSON.serialize(body),
            timeoutMs
        );
*/

        HttpResponse res = FormTemplateService.doCallout('https://n3n3n.suplo.my.id/webhook/template-scan', JSON.serialize(body), timeoutMs);


        // n8n should ACK 2xx ({status:"accepted"}). Non-2xx -> mark Failed now.
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            markFailed(templateId, 'n8n scan ACK returned HTTP ' + res.getStatusCode());
        }
        // On 2xx we do nothing else: the schema arrives async via the callback.
    }

    /** Flip the template to Failed with FLS enforced. Used on non-2xx ACK. */
    private static void markFailed(Id templateId, String reason) {
        // reason is logged via debug; surfaced to UI through Scan_Status__c.
        System.debug(LoggingLevel.WARN, 'Scan failed for ' + templateId + ': ' + reason);
        update as user new List<Form_Template__c>{
            new Form_Template__c(Id = templateId, Scan_Status__c = 'Failed')
        };
    }

    /**
     * Finalizer: runs in its own transaction after the Queueable completes.
     * If the job result is UNHANDLED_EXCEPTION, force the template to Failed so
     * the UI never hangs on Processing.
     */
    public class ScanFinalizer implements System.Finalizer {
        private final Id templateId;
        private final String jobId;

        public ScanFinalizer(Id templateId, String jobId) {
            this.templateId = templateId;
            this.jobId = jobId;
        }

        public void execute(System.FinalizerContext fc) {
            if (fc.getResult() == System.ParentJobResult.UNHANDLED_EXCEPTION) {
                // Best-effort status flip; swallow any secondary error to avoid
                // masking the original failure.
                try {
                    update new Form_Template__c(Id = templateId, Scan_Status__c = 'Failed');
                } catch (Exception ignored) {
                    System.debug(LoggingLevel.ERROR,
                        'Finalizer could not mark template Failed: ' + ignored.getMessage());
                }
            }
        }
    }
}