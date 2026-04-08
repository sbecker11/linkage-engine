package com.spexture.linkage_engine;

import java.util.Map;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Sprint 4 — Embedding Gap Detection
 *
 * GET /v1/ingest/health
 *   Returns the count of records with no embedding row and a status string:
 *     {"embeddingGapCount": N, "status": "ok"|"degraded"}
 *
 * A gap count > 0 means Bedrock timed out or was throttled for those records.
 * Call PUT /v1/vectors/reindex to close the gaps.
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
        int gaps = ingestHealthService.countEmbeddingGaps();
        String status = gaps > 0 ? "degraded" : "ok";
        return ResponseEntity.ok(Map.of(
            "embeddingGapCount", gaps,
            "status", status
        ));
    }
}
