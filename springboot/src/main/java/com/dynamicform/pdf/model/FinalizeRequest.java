package com.dynamicform.pdf.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.Map;

/**
 * Inbound payload from Salesforce (contract B3).
 *
 * <pre>
 * {
 *   "submissionId": "a0Y...",
 *   "schema":     { "sections": [...] },
 *   "data":       { "values": { "fieldId": value, "tableId": [ { "colId": cell } ] } },
 *   "signatures": { "engineer": {...}, "supervisor": {...} },
 *   "salesforceFileApi": { "instanceUrl": "...", "accessToken": "00D..." }
 * }
 * </pre>
 *
 * camelCase keys are intentional and must match Salesforce exactly.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record FinalizeRequest(
        String submissionId,
        Schema schema,
        FormData data,
        Signatures signatures,
        SalesforceFileApi salesforceFileApi
) {

    /** data.values map: fieldId -> scalar, or tableId -> List&lt;Map&lt;colId,cell&gt;&gt;. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record FormData(Map<String, Object> values) {
        public Map<String, Object> safeValues() {
            return values == null ? Map.of() : values;
        }
    }

    /** Signature pointers by role. Each holds a ContentVersion id + audit metadata. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Signatures(SignatureInfo engineer, SignatureInfo supervisor) {
        public SignatureInfo forRole(String role) {
            if ("engineer".equals(role)) return engineer;
            if ("supervisor".equals(role)) return supervisor;
            return null;
        }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record SignatureInfo(String contentVersionId, String signedBy, String signedAt) {}

    /**
     * Salesforce instance info for pulling signature images + uploading the PDF.
     *
     * <p>{@code accessToken} is no longer used — Spring Boot authenticates itself
     * via OAuth client_credentials. The field is kept (optional/ignored) so
     * existing Apex callers that still send it don't break.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record SalesforceFileApi(String instanceUrl, String accessToken) {}
}
