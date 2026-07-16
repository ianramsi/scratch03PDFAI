package com.dynamicform.pdf.service;

import com.dynamicform.pdf.client.SalesforceClient;
import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;
import com.dynamicform.pdf.model.FinalizeRequest;
import com.dynamicform.pdf.model.FinalizeResponse;
import com.dynamicform.pdf.model.Schema;
import com.dynamicform.pdf.render.HtmlRenderer;
import com.dynamicform.pdf.render.PdfRenderService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.security.MessageDigest;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Orchestrates the finalize flow (stages 2.2 → 2.6):
 * validate → pull signature images → render XHTML → render PDF → SHA-256 hash →
 * upload ContentVersion → return id + hash + page count.
 *
 * <p>Signature images are pulled BEFORE rendering (the handoff's reorder note),
 * because the renderer needs them inline as data-URIs.
 */
@Service
public class FinalizeService {

    private static final Logger log = LoggerFactory.getLogger(FinalizeService.class);

    private final RequestValidator validator;
    private final SalesforceClient salesforceClient;
    private final HtmlRenderer htmlRenderer;
    private final PdfRenderService pdfRenderService;

    public FinalizeService(RequestValidator validator,
                           SalesforceClient salesforceClient,
                           HtmlRenderer htmlRenderer,
                           PdfRenderService pdfRenderService) {
        this.validator = validator;
        this.salesforceClient = salesforceClient;
        this.htmlRenderer = htmlRenderer;
        this.pdfRenderService = pdfRenderService;
    }

    public FinalizeResponse finalize(FinalizeRequest req) {
        validator.validate(req);

        FinalizeRequest.SalesforceFileApi sf = req.salesforceFileApi();
        Schema schema = req.schema();
        Map<String, Object> values = req.data() == null ? Map.of() : req.data().safeValues();

        // 2.5 — pull signature images first, then render.
        Map<String, String> sigUriByRole = new HashMap<>();
        Map<String, String[]> sigMetaByRole = new HashMap<>();
        for (String role : signatureRoles(schema)) {
            FinalizeRequest.SignatureInfo info = req.signatures() == null ? null : req.signatures().forRole(role);
            if (info == null) continue;
            String dataUri = salesforceClient.fetchSignatureDataUri(
                    sf.instanceUrl(), info.contentVersionId());
            sigUriByRole.put(role, dataUri);
            sigMetaByRole.put(role, new String[]{info.signedBy(), info.signedAt()});
        }

        // 2.3 + 2.4 — render HTML then PDF.
        String html = htmlRenderer.render(schema, values, sigUriByRole, sigMetaByRole);
        PdfRenderService.RenderResult result = pdfRenderService.renderToPdf(html);

        // 2.6 — hash + upload.
        String hash = "sha256:" + sha256Hex(result.pdf());
        String title = buildTitle(schema, req.submissionId());
        String cvId = salesforceClient.uploadPdf(sf.instanceUrl(), title, result.pdf());

        log.info("Finalized submission {} -> ContentVersion {} ({} pages, {} bytes).",
                req.submissionId(), cvId, result.pageCount(), result.pdf().length);

        return FinalizeResponse.success(cvId, hash, result.pageCount());
    }

    /** Distinct signerRoles referenced by signature fields, in document order. */
    private Set<String> signatureRoles(Schema schema) {
        Set<String> roles = new LinkedHashSet<>();
        for (Schema.Section section : nullSafe(schema.sections())) {
            if (section == null) continue;
            for (Schema.Row row : nullSafe(section.rows())) {
                if (row == null) continue;
                for (Schema.Field field : nullSafe(row.fields())) {
                    if (field != null && "signature".equals(field.type()) && StringUtils.hasText(field.signerRole())) {
                        roles.add(field.signerRole());
                    }
                }
            }
        }
        return roles;
    }

    private String buildTitle(Schema schema, String submissionId) {
        String base = StringUtils.hasText(schema.title()) ? schema.title() : "Form";
        return base + " - " + submissionId;
    }

    private static String sha256Hex(byte[] bytes) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder hex = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                hex.append(Character.forDigit((b >> 4) & 0xF, 16));
                hex.append(Character.forDigit(b & 0xF, 16));
            }
            return hex.toString();
        } catch (Exception e) {
            throw new FinalizeException(ErrorCode.INTERNAL, "SHA-256 unavailable: " + e.getMessage(), e);
        }
    }

    private static <T> List<T> nullSafe(List<T> list) {
        return list == null ? List.of() : list;
    }
}
