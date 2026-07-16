package com.dynamicform.pdf.model;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * Response contract.
 *
 * <p>Success: {@code { status:"success", pdfContentVersionId, documentHash, pageCount, error:null }}
 * <br>Error:   {@code { status:"error", errorCode, error }}
 */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record FinalizeResponse(
        String status,
        String pdfContentVersionId,
        String documentHash,
        Integer pageCount,
        ErrorCode errorCode,
        String error
) {
    public static FinalizeResponse success(String pdfContentVersionId, String documentHash, int pageCount) {
        return new FinalizeResponse("success", pdfContentVersionId, documentHash, pageCount, null, null);
    }

    public static FinalizeResponse error(ErrorCode code, String message) {
        return new FinalizeResponse("error", null, null, null, code, message);
    }
}
