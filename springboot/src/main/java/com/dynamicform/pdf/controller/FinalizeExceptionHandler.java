package com.dynamicform.pdf.controller;

import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;
import com.dynamicform.pdf.model.FinalizeResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * Stage 2.8 — maps every failure to the contract error response. Stack traces
 * are logged server-side but NEVER returned to the caller.
 */
@RestControllerAdvice
public class FinalizeExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(FinalizeExceptionHandler.class);

    @ExceptionHandler(FinalizeException.class)
    public ResponseEntity<FinalizeResponse> handleFinalize(FinalizeException e) {
        ErrorCode code = e.getErrorCode();
        HttpStatus status = switch (code) {
            case VALIDATION_FAILED -> HttpStatus.BAD_REQUEST;
            case AUTH_FAILED -> HttpStatus.UNAUTHORIZED;
            case PDF_GEN_FAILED -> HttpStatus.UNPROCESSABLE_ENTITY;
            case INTERNAL -> HttpStatus.INTERNAL_SERVER_ERROR;
        };
        // Validation/auth are client-actionable -> info; the rest are real faults.
        if (status.is5xxServerError()) {
            log.error("Finalize failed [{}]: {}", code, e.getMessage(), e);
        } else {
            log.info("Finalize rejected [{}]: {}", code, e.getMessage());
        }
        return ResponseEntity.status(status).body(FinalizeResponse.error(code, e.getMessage()));
    }

    /** Malformed/unreadable JSON body. */
    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<FinalizeResponse> handleUnreadable(HttpMessageNotReadableException e) {
        log.info("Rejected unreadable request body: {}", e.getMessage());
        return ResponseEntity.badRequest()
                .body(FinalizeResponse.error(ErrorCode.VALIDATION_FAILED, "Malformed JSON request body."));
    }

    /** Catch-all: never leak internals. */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<FinalizeResponse> handleAny(Exception e) {
        log.error("Unexpected finalize error.", e);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(FinalizeResponse.error(ErrorCode.INTERNAL, "Internal error."));
    }
}
