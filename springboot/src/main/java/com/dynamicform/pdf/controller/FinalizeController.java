package com.dynamicform.pdf.controller;

import com.dynamicform.pdf.model.FinalizeRequest;
import com.dynamicform.pdf.model.FinalizeResponse;
import com.dynamicform.pdf.service.FinalizeService;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Stage 2.1 / 2.7 endpoint — {@code POST /api/v1/forms/finalize}.
 *
 * <p>Salesforce calls this via the {@code springboot_Form} Named Credential
 * (which supplies the {@code X-API-Key} header checked by {@code ApiKeyFilter}).
 * Returns the agreed success/error contract; failures are mapped to error codes
 * by {@code FinalizeExceptionHandler}.
 */
@RestController
@RequestMapping("/api/v1/forms")
public class FinalizeController {

    private final FinalizeService finalizeService;

    public FinalizeController(FinalizeService finalizeService) {
        this.finalizeService = finalizeService;
    }

    @PostMapping(value = "/finalize", consumes = MediaType.APPLICATION_JSON_VALUE,
            produces = MediaType.APPLICATION_JSON_VALUE)
    public FinalizeResponse finalize(@RequestBody FinalizeRequest request) {
        return finalizeService.finalize(request);
    }

    /** Unauthenticated liveness check for connectivity verification (stage 2.1). */
    @GetMapping(value = "/ping", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, String> ping() {
        return Map.of("status", "ok", "service", "pdf-finalizer");
    }
}
