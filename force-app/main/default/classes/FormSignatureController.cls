/**
 * FormSignatureController
 * ----------------------------------------------------------------------------
 * Thin controller for the signaturePad LWC. Takes a base64 PNG and creates a
 * ContentVersion, returning its Id so the parent can link it to the submission
 * via FormSubmissionService.recordSignature.
 *
 * WHY SEPARATE FROM FormSubmissionService:
 *  - Single responsibility: this only turns bytes into a ContentVersion. The
 *    business linkage (which submission/role) stays in FormSubmissionService.
 *  - Keeps the signature upload reusable (e.g. supervisor signs from a different
 *    component) without dragging submission logic along.
 *
 * SECURITY: `with sharing`; size guard to avoid heap abuse; ContentVersion
 * insert runs as the user (USER_MODE not applicable to ContentVersion insert,
 * but the user must have content access -- enforced by platform).
 */
public with sharing class FormSignatureController {

    // A drawn signature PNG is small. Cap to 2MB of raw bytes as a sanity guard.
    private static final Integer MAX_SIGNATURE_BYTES = 2 * 1024 * 1024;

    /**
     * Create a ContentVersion from a base64 PNG.
     * @param fileName   display name for the file
     * @param base64Data base64 (no data-url prefix) of the PNG
     * @return the new ContentVersion Id
     */
    @AuraEnabled
    public static Id saveSignature(String fileName, String base64Data) {
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('Signature data is empty.');
        }
        Blob body;
        try {
            body = EncodingUtil.base64Decode(base64Data);
        } catch (Exception e) {
            throw new AuraHandledException('Signature data is not valid base64.');
        }
        if (body.size() > MAX_SIGNATURE_BYTES) {
            throw new AuraHandledException('Signature image is too large.');
        }

        ContentVersion cv = new ContentVersion(
            Title = String.isBlank(fileName) ? 'signature.png' : fileName,
            PathOnClient = String.isBlank(fileName) ? 'signature.png' : fileName,
            VersionData = body,
            // 'C' = content document is available in libraries/records; default origin.
            Origin = 'C'
        );
        try {
            insert as user cv;
        } catch (DmlException e) {
            throw new AuraHandledException('Could not save signature file: ' + e.getMessage());
        }

        // Re-query to get the generated ContentVersion Id (insert populates cv.Id,
        // but we return it explicitly for clarity).
        return cv.Id;
    }
}
