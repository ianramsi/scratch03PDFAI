package com.dynamicform.pdf.service;

import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;
import com.dynamicform.pdf.model.FinalizeRequest;
import com.dynamicform.pdf.model.Schema;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

/**
 * Stage 2.2 — validates the inbound contract before any rendering or callout.
 *
 * <p>Rejects with {@link ErrorCode#VALIDATION_FAILED}. We require the structural
 * essentials (submissionId, non-empty schema.sections, Salesforce access) and,
 * for every signature field present in the schema, a matching signature pointer
 * with a non-blank contentVersionId. Requiring signatures only when the schema
 * actually contains that role is stricter where it matters and avoids failing a
 * form that legitimately has a single signer.
 */
@Component
public class RequestValidator {

    public void validate(FinalizeRequest req) {
        if (req == null) {
            throw new FinalizeException(ErrorCode.VALIDATION_FAILED, "Request body is missing.");
        }
        if (!StringUtils.hasText(req.submissionId())) {
            throw new FinalizeException(ErrorCode.VALIDATION_FAILED, "submissionId is required.");
        }

        Schema schema = req.schema();
        if (schema == null || schema.sections() == null || schema.sections().isEmpty()) {
            throw new FinalizeException(ErrorCode.VALIDATION_FAILED, "schema.sections is required and must be non-empty.");
        }

        FinalizeRequest.SalesforceFileApi sf = req.salesforceFileApi();
        if (sf == null || !StringUtils.hasText(sf.instanceUrl())) {
            throw new FinalizeException(ErrorCode.VALIDATION_FAILED, "salesforceFileApi.instanceUrl is required.");
        }

        validateSignaturePointers(req);
    }

    /** For each signature field in the schema, ensure a usable contentVersionId exists. */
    private void validateSignaturePointers(FinalizeRequest req) {
        Schema schema = req.schema();
        FinalizeRequest.Signatures sigs = req.signatures();

        for (Schema.Section section : safe(schema.sections())) {
            for (Schema.Row row : safe(section == null ? null : section.rows())) {
                for (Schema.Field field : safe(row == null ? null : row.fields())) {
                    if (field == null || !"signature".equals(field.type())) {
                        continue;
                    }
                    String role = field.signerRole();
                    FinalizeRequest.SignatureInfo info = sigs == null ? null : sigs.forRole(role);
                    if (info == null || !StringUtils.hasText(info.contentVersionId())) {
                        throw new FinalizeException(ErrorCode.VALIDATION_FAILED,
                                "Missing signature contentVersionId for role '" + role
                                        + "' required by field '" + field.id() + "'.");
                    }
                }
            }
        }
    }

    private static <T> java.util.List<T> safe(java.util.List<T> list) {
        return list == null ? java.util.List.of() : list;
    }
}
