/**
 * FormCalloutException
 * ----------------------------------------------------------------------------
 * Custom exception used to surface failures across layer boundaries (service ->
 * caller, callout -> service) without leaking low-level details such as raw
 * HTTP bodies or DML internals.
 *
 * WHY A CUSTOM TYPE:
 *  - Lets callers (LWC via @AuraEnabled, or other services) catch THIS type
 *    specifically instead of a broad `catch (Exception e)`.
 *  - Carries a machine-readable `errorCode` aligned with the API contract enum
 *    (AUTH_FAILED, VALIDATION_FAILED, VISION_PARSE_FAILED, LLM_TIMEOUT,
 *    FILE_TOO_LARGE, SF_CALLBACK_FAILED, PDF_GEN_FAILED, INTERNAL) so the UI can
 *    branch on it and show a meaningful message.
 *
 * NOTE: @AuraEnabled exceptions shown to LWC should use AuraHandledException at
 * the boundary. This type is for INTERNAL signaling; services translate it to
 * AuraHandledException with getMessage() right before returning to the UI.
 */

public class FormCalloutException extends Exception {
    //machine-readable code mathing the cross-layer API contract error sum.
    public String errorCode { get; private set; }
    
    public FormCalloutException(String errorCode, String message) {
        // the single=arg Exception(Message) constructor is implicit via setMessage
        this.setMessage(message);
        this.errorCode = errorCode;
    }

}
