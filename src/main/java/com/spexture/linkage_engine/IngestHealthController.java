package com.spexture.linkage_engine;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Sprints 4 + 5 — Embedding Gap Detection and Migration Safety
 *
 * GET /v1/ingest/health
 *   Returns embedding gap count, Flyway migration status, and an overall status:
 *     {
 *       "embeddingGapCount": N,
 *       "flywayStatus":      "up-to-date" | "pending",
 *       "pendingMigrations": N,
 *       "status":            "ok" | "degraded"
 *     }
 *
 * status="degraded" when:
 *   - embeddingGapCount > 0  (Bedrock timed out for some records), OR
 *   - pendingMigrations > 0  (schema migration not yet applied)
 *
 * The store Lambda calls this endpoint before processing any records and
 * aborts ingest when status="degraded" to prevent writing to a stale schema.
 */
@RestController
@RequestMapping("/v1/ingest")
public class IngestHealthController {

    private final IngestHealthService ingestHealthService;

    public IngestHealthController(IngestHealthService ingestHealthService) {
        this.ingestHealthService = ingestHealthService;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        int gaps    = ingestHealthService.countEmbeddingGaps();
        int pending = ingestHealthService.countPendingMigrations();

        String flywayStatus = pending > 0 ? "pending" : "up-to-date";
        String status       = (gaps > 0 || pending > 0) ? "degraded" : "ok";

        // LinkedHashMap preserves insertion order for readable JSON responses
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("embeddingGapCount", gaps);
        body.put("flywayStatus",      flywayStatus);
        body.put("pendingMigrations", pending);
        body.put("status",            status);

        return ResponseEntity.ok(body);
    }
}
