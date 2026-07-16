package com.dynamicform.pdf.model;

/** Contract error codes returned to Salesforce. Never leak internal details beyond these. */
public enum ErrorCode {
    /** Request body failed validation (missing required fields, bad shape). */
    VALIDATION_FAILED,
    /** Salesforce auth/token problem when pulling signatures or uploading the PDF. */
    AUTH_FAILED,
    /** HTML/PDF rendering failed. */
    PDF_GEN_FAILED,
    /** Anything else unexpected. */
    INTERNAL
}
