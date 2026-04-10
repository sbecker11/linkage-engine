package com.spexture.linkage_engine;

import java.io.IOException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Sprint 9 — Security Hardening: API key authentication for write endpoints.
 *
 * Intercepts every request to /v1/records and requires a matching
 * X-Api-Key header. Requests without the header, or with a wrong value,
 * are rejected with 401 before reaching the controller.
 *
 * The expected key is injected via the INGEST_API_KEY environment variable
 * (stored in Secrets Manager and surfaced to the ECS task via task definition
 * secretOptions). When INGEST_API_KEY is blank or absent the filter is
 * disabled and all requests pass through — this preserves local-dev
 * behaviour without requiring a key to be set.
 *
 * Read endpoints (GET /v1/*, /actuator/*, /chord-diagram.html) are not
 * covered by this filter — it is registered only on /v1/records.
 */
public class ApiKeyFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(ApiKeyFilter.class);
    static final String HEADER_NAME = "X-Api-Key";

    private final String expectedKey;

    public ApiKeyFilter(String expectedKey) {
        this.expectedKey = expectedKey;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain)
            throws ServletException, IOException {

        if (expectedKey == null || expectedKey.isBlank()) {
            // No key configured — filter is disabled (local dev / test without env var)
            chain.doFilter(request, response);
            return;
        }

        // Only protect write operations — GET/HEAD pass through unauthenticated
        String method = request.getMethod();
        if ("GET".equalsIgnoreCase(method) || "HEAD".equalsIgnoreCase(method)) {
            chain.doFilter(request, response);
            return;
        }

        String provided = request.getHeader(HEADER_NAME);
        if (provided == null || !provided.equals(expectedKey)) {
            log.warn("Rejected request to {} — missing or invalid {}",
                     request.getRequestURI(), HEADER_NAME);
            response.setStatus(HttpStatus.UNAUTHORIZED.value());
            response.setContentType("application/json");
            response.getWriter().write("{\"error\":\"Unauthorized — valid X-Api-Key required\"}");
            return;
        }

        chain.doFilter(request, response);
    }
}
