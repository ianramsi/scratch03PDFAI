package com.dynamicform.pdf.security;

import com.dynamicform.pdf.model.ErrorCode;
import com.dynamicform.pdf.model.FinalizeResponse;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;

/**
 * Authenticates inbound finalize calls with a shared secret in the
 * {@code X-API-Key} header (supplied by the Salesforce Named Credential).
 *
 * <p>Only {@code /api/v1/forms/finalize} is protected; {@code /ping} stays open
 * for connectivity checks. A network-exposed endpoint without this check would
 * let anyone trigger PDF generation against a Salesforce org, so the key is
 * mandatory. Comparison is constant-time to avoid timing leaks.
 */
@Component
public class ApiKeyFilter extends OncePerRequestFilter {

    private static final String HEADER = "X-API-Key";
    private static final String PROTECTED_PATH = "/api/v1/forms/finalize";

    private final String apiKey;
    private final ObjectMapper objectMapper;

    public ApiKeyFilter(@Value("${finalizer.api-key}") String apiKey, ObjectMapper objectMapper) {
        this.apiKey = apiKey;
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !PROTECTED_PATH.equals(request.getServletPath());
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String provided = request.getHeader(HEADER);
        if (!StringUtils.hasText(provided) || !constantTimeEquals(provided, apiKey)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.setHeader(HttpHeaders.WWW_AUTHENTICATE, "ApiKey");
            objectMapper.writeValue(response.getWriter(),
                    FinalizeResponse.error(ErrorCode.AUTH_FAILED, "Invalid or missing API key."));
            return;
        }
        chain.doFilter(request, response);
    }

    private boolean constantTimeEquals(String a, String b) {
        return MessageDigest.isEqual(a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
    }
}
