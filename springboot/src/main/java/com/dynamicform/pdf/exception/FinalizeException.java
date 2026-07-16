package com.dynamicform.pdf.exception;

import com.dynamicform.pdf.model.ErrorCode;

/**
 * Carries a contract {@link ErrorCode} so the controller can map any failure to
 * the agreed error response without leaking stack traces.
 */
public class FinalizeException extends RuntimeException {

    private final ErrorCode errorCode;

    public FinalizeException(ErrorCode errorCode, String message) {
        super(message);
        this.errorCode = errorCode;
    }

    public FinalizeException(ErrorCode errorCode, String message, Throwable cause) {
        super(message, cause);
        this.errorCode = errorCode;
    }

    public ErrorCode getErrorCode() {
        return errorCode;
    }
}
