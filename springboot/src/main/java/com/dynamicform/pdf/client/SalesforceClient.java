package com.dynamicform.pdf.client;

import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Salesforce REST client for the finalize flow.
 *
 * <p><b>Auth: OAuth 2.0 — two flows supported, selected by {@code SF_AUTH_TYPE}:</b>
 * <ul>
 *   <li>{@code client_credentials} (default) — Spring Boot authenticates itself
 *       to Salesforce so Apex never has to pass a session token. Requires the
 *       Connected App to have <i>Client Credentials Flow</i> enabled with a
 *       "Run As" user.</li>
 *   <li>{@code jwt} — JWT bearer flow. The Connected App must have <i>Use digital
 *       signatures</i> enabled with the matching public certificate uploaded.
 *       Spring Boot signs a short-lived RS256 assertion with the private key
 *       and exchanges it for an access token. No client secret is sent.</li>
 * </ul>
 *
 * <p>The token is obtained once and cached; it is pre-emptively refreshed
 * {@code refresh-buffer-seconds} before it expires, so a long-running instance
 * never sends a stale token mid-request. The lock ensures only one thread
 * fetches a new token concurrently.
 *
 * <p>Responsibilities:
 * <ul>
 *   <li>{@link #fetchSignatureDataUri} — GET ContentVersion VersionData, return as data-URI.</li>
 *   <li>{@link #uploadPdf} — POST new ContentVersion, return its Id. Apex does the
 *       linking DML (USER_MODE, audit).</li>
 * </ul>
 */
@Component
public class SalesforceClient {

    private static final Logger log = LoggerFactory.getLogger(SalesforceClient.class);

    private final String apiVersion;
    private final String tokenUrl;
    private final String clientId;
    private final String clientSecret;
    private final long refreshBufferSeconds;
    private final RestClient restClient;

    // JWT-bearer-only fields (null when SF_AUTH_TYPE=client_credentials).
    private final String authType;
    private final JwtTokenProvider jwtProvider;

    // ---------- token cache (thread-safe) ----------
    private final ReentrantLock tokenLock = new ReentrantLock();
    /** Cached access token value. Null means "not yet obtained". */
    private volatile String cachedToken;
    /** Wall-clock expiry (epoch second). 0 = expired/unknown. */
    private volatile long tokenExpiresAt;

    public SalesforceClient(
            @Value("${finalizer.salesforce-api-version:61.0}") String apiVersion,
            @Value("${finalizer.salesforce-oauth.token-url}") String tokenUrl,
            @Value("${finalizer.salesforce-oauth.client-id}") String clientId,
            @Value("${finalizer.salesforce-oauth.client-secret:}") String clientSecret,
            @Value("${finalizer.salesforce-oauth.refresh-buffer-seconds:60}") long refreshBufferSeconds,
            @Value("${finalizer.salesforce-oauth.auth-type:client_credentials}") String authType,
            @Value("${finalizer.salesforce-oauth.jwt-username:}") String jwtUsername,
            @Value("${finalizer.salesforce-oauth.jwt-audience:}") String jwtAudience,
            @Value("${finalizer.salesforce-oauth.jwt-private-key:}") String jwtPrivateKey) {
        this.apiVersion = apiVersion;
        this.tokenUrl = tokenUrl;
        this.clientId = clientId;
        this.clientSecret = clientSecret;
        this.refreshBufferSeconds = refreshBufferSeconds;
        this.restClient = RestClient.builder().build();
        this.authType = authType == null ? "client_credentials" : authType.trim().toLowerCase();

        if ("jwt".equals(this.authType)) {
            if (jwtUsername == null || jwtUsername.isBlank()
                    || jwtAudience == null || jwtAudience.isBlank()
                    || jwtPrivateKey == null || jwtPrivateKey.isBlank()) {
                throw new IllegalStateException(
                        "SF_AUTH_TYPE=jwt requires SF_JWT_USERNAME, SF_JWT_AUDIENCE and SF_JWT_PRIVATE_KEY.");
            }
            this.jwtProvider = new JwtTokenProvider(clientId, jwtUsername, jwtAudience, jwtPrivateKey);
            log.info("Salesforce auth: JWT bearer flow (user={}, aud={}).", jwtUsername, jwtAudience);
        } else {
            this.jwtProvider = null;
            if (clientSecret == null || clientSecret.isBlank()) {
                throw new IllegalStateException(
                        "SF_AUTH_TYPE=client_credentials requires SF_CLIENT_SECRET.");
            }
            log.info("Salesforce auth: client_credentials flow.");
        }
    }

    // ---------------------------------------------------------------
    // Public API (no accessToken params — service authenticates itself)
    // ---------------------------------------------------------------

    /**
     * GET the binary VersionData for a ContentVersion and return it as a data-URI
     * suitable for embedding in the {@code <img src="...">} inside the HTML.
     */
    public String fetchSignatureDataUri(String instanceUrl, String contentVersionId) {
        String token = token();
        String url = base(instanceUrl) + "/services/data/v" + apiVersion
                + "/sobjects/ContentVersion/" + contentVersionId + "/VersionData";
        try {
            ResponseEntity<byte[]> resp = restClient.get()
                    .uri(url)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                    .retrieve()
                    .toEntity(byte[].class);

            byte[] body = resp.getBody();
            if (body == null || body.length == 0) {
                throw new FinalizeException(ErrorCode.INTERNAL,
                        "Empty VersionData for ContentVersion " + contentVersionId + ".");
            }
            MediaType ct = resp.getHeaders().getContentType();
            String mime = (ct == null) ? "image/png" : ct.toString();
            return "data:" + mime + ";base64," + Base64.getEncoder().encodeToString(body);

        } catch (RestClientResponseException e) {
            throw mapHttpError(e, "fetch signature " + contentVersionId);
        } catch (FinalizeException fe) {
            throw fe;
        } catch (Exception e) {
            throw new FinalizeException(ErrorCode.INTERNAL,
                    "Failed to fetch signature " + contentVersionId + ": " + e.getMessage(), e);
        }
    }

    /**
     * POST a new ContentVersion holding the finalized PDF bytes. Returns the new
     * ContentVersion Id. Linking it to the submission stays in Apex (USER_MODE).
     */
    @SuppressWarnings("unchecked")
    public String uploadPdf(String instanceUrl, String title, byte[] pdfBytes) {
        String token = token();
        String url = base(instanceUrl) + "/services/data/v" + apiVersion + "/sobjects/ContentVersion";
        String fileName = title.endsWith(".pdf") ? title : title + ".pdf";
        Map<String, Object> body = Map.of(
                "Title", title,
                "PathOnClient", fileName,
                "VersionData", Base64.getEncoder().encodeToString(pdfBytes)
        );
        try {
            Map<String, Object> result = restClient.post()
                    .uri(url)
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(Map.class);

            if (result == null || !Boolean.TRUE.equals(result.get("success")) || result.get("id") == null) {
                throw new FinalizeException(ErrorCode.INTERNAL,
                        "ContentVersion create did not return success: " + result);
            }
            return String.valueOf(result.get("id"));

        } catch (RestClientResponseException e) {
            throw mapHttpError(e, "upload PDF ContentVersion");
        } catch (FinalizeException fe) {
            throw fe;
        } catch (Exception e) {
            throw new FinalizeException(ErrorCode.INTERNAL, "Failed to upload PDF: " + e.getMessage(), e);
        }
    }

    // ---------------------------------------------------------------
    // Token management
    // ---------------------------------------------------------------

    /** Returns a valid cached token, refreshing if within the buffer window. */
    private String token() {
        // Fast path: token is cached and not near expiry.
        if (cachedToken != null && Instant.now().getEpochSecond() < tokenExpiresAt - refreshBufferSeconds) {
            return cachedToken;
        }
        // Slow path: acquire lock and refresh (only one thread does the HTTP call).
        tokenLock.lock();
        try {
            // Re-check inside the lock: another thread may have refreshed while we waited.
            if (cachedToken != null && Instant.now().getEpochSecond() < tokenExpiresAt - refreshBufferSeconds) {
                return cachedToken;
            }
            return fetchNewToken();
        } finally {
            tokenLock.unlock();
        }
    }

    @SuppressWarnings("unchecked")
    private String fetchNewToken() {
        log.info("Fetching Salesforce OAuth token from {} (flow={}).", tokenUrl, authType);
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();

        if ("jwt".equals(authType)) {
            // JWT bearer flow: sign a short-lived RS256 assertion, exchange for token.
            form.add("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer");
            form.add("assertion", jwtProvider.buildAssertion());
        } else {
            // client_credentials flow.
            form.add("grant_type", "client_credentials");
            form.add("client_id", clientId);
            form.add("client_secret", clientSecret);
        }

        try {
            Map<String, Object> resp = restClient.post()
                    .uri(tokenUrl)
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(Map.class);

            if (resp == null || resp.get("access_token") == null) {
                throw new FinalizeException(ErrorCode.AUTH_FAILED,
                        "Salesforce token endpoint returned no access_token.");
            }
            String token = String.valueOf(resp.get("access_token"));
            // Salesforce tokens typically expire in 7200s (2h) for client_credentials
            // and 30 min for JWT bearer. Use the returned expires_in when present.
            long expiresIn = 7200L;
            if (resp.get("expires_in") instanceof Number n) {
                expiresIn = n.longValue();
            }
            cachedToken = token;
            tokenExpiresAt = Instant.now().getEpochSecond() + expiresIn;
            log.info("Salesforce OAuth token obtained (expires in {}s).", expiresIn);
            return token;

        } catch (RestClientResponseException e) {
            throw mapHttpError(e, "OAuth token fetch");
        } catch (FinalizeException fe) {
            throw fe;
        } catch (Exception e) {
            throw new FinalizeException(ErrorCode.AUTH_FAILED,
                    "Salesforce token fetch failed: " + e.getMessage(), e);
        }
    }

    // ---------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------

    private FinalizeException mapHttpError(RestClientResponseException e, String action) {
        int status = e.getStatusCode().value();
        // Log only status code — never log tokens or client secrets.
        log.warn("Salesforce {} failed with HTTP {}.", action, status);
        ErrorCode code = (status == 401 || status == 403) ? ErrorCode.AUTH_FAILED : ErrorCode.INTERNAL;
        return new FinalizeException(code,
                "Salesforce " + action + " failed (HTTP " + status + ").", e);
    }

    private static String base(String instanceUrl) {
        if (instanceUrl == null || instanceUrl.isBlank()) {
            throw new FinalizeException(ErrorCode.VALIDATION_FAILED, "instanceUrl is required.");
        }
        return instanceUrl.endsWith("/")
                ? instanceUrl.substring(0, instanceUrl.length() - 1)
                : instanceUrl;
    }
}
