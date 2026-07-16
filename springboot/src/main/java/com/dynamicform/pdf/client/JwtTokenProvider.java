package com.dynamicform.pdf.client;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;

import java.security.KeyFactory;
import java.security.NoSuchAlgorithmException;
import java.security.interfaces.RSAPrivateKey;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Base64;
import java.util.Date;

/**
 * Builds a short-lived RS256 JWT assertion for the Salesforce OAuth
 * <b>urn:ietf:params:oauth:grant-type:jwt-bearer</b> flow. The assertion is
 * then exchanged at {@code /services/oauth2/token} for a Bearer access token.
 *
 * <p>The Connected App must have <i>Use digital signatures</i> enabled and the
 * corresponding public certificate (PEM) uploaded in Setup. The {@code sub} of
 * the JWT must match a Salesforce user that has been granted access to the
 * Connected App (the "Run As" user).
 *
 * <p>The private key is passed as a PEM string via env var. It may contain
 * literal newlines or {@code \n} escape sequences — both are normalised.
 */
public final class JwtTokenProvider {

    private final String clientId;
    private final String username;
    private final String audience;
    private final RSAPrivateKey privateKey;

    public JwtTokenProvider(String clientId, String username, String audience, String privateKeyPem) {
        this.clientId = clientId;
        this.username = username;
        this.audience = audience;
        this.privateKey = parsePrivateKey(privateKeyPem);
    }

    /**
     * Build a signed JWT assertion, valid for 3 minutes.
     */
    public String buildAssertion() {
        try {
            long nowMs = System.currentTimeMillis();
            JWTClaimsSet claims = new JWTClaimsSet.Builder()
                    .issuer(clientId)
                    .subject(username)
                    .audience(audience)
                    .issueTime(new Date(nowMs))
                    .expirationTime(new Date(nowMs + 3 * 60 * 1000L))  // 3 min
                    .build();
            JWSHeader header = new JWSHeader.Builder(JWSAlgorithm.RS256).build();
            SignedJWT jwt = new SignedJWT(header, claims);
            jwt.sign(new RSASSASigner(privateKey));
            return jwt.serialize();
        } catch (JOSEException e) {
            throw new FinalizeException(ErrorCode.AUTH_FAILED,
                    "Failed to sign JWT assertion: " + e.getMessage(), e);
        }
    }

    // ----- helpers -----

    /**
     * Parse a PEM-encoded PKCS#8 RSA private key. Accepts keys with literal
     * newlines or {@code \n} escape sequences (common in env-var-friendly
     * .env files). Whitespace inside the base64 body is ignored.
     */
    static RSAPrivateKey parsePrivateKey(String pem) {
        if (pem == null || pem.isBlank()) {
            throw new FinalizeException(ErrorCode.AUTH_FAILED,
                    "SF_PRIVATE_KEY is empty. Provide the PEM-encoded RSA private key.");
        }
        String normalised = pem
                .replace("\\n", "\n")
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s+", "");
        try {
            byte[] der = Base64.getDecoder().decode(normalised);
            PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(der);
            KeyFactory kf = KeyFactory.getInstance("RSA");
            return (RSAPrivateKey) kf.generatePrivate(spec);
        } catch (IllegalArgumentException | NoSuchAlgorithmException | InvalidKeySpecException e) {
            throw new FinalizeException(ErrorCode.AUTH_FAILED,
                    "SF_PRIVATE_KEY is not a valid PKCS#8 PEM RSA private key: " + e.getMessage(), e);
        }
    }
}
