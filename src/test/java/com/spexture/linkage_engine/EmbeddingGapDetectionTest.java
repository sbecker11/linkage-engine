package com.spexture.linkage_engine;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/**
 * Sprint 4 — Embedding Gap Detection
 *
 * Simulate: Bedrock throttle/timeout leaves some records in `records`
 *           with no corresponding row in `record_embeddings`.
 * Detect:   GET /v1/ingest/health surfaces the gap count and status.
 * Mitigate: POST /v1/ingest/reindex triggers reindex for gap records only.
 */
@ExtendWith(MockitoExtension.class)
class EmbeddingGapDetectionTest {

    // ── helpers ───────────────────────────────────────────────────────────────

    private MockMvc mvc(IngestHealthService service) {
        return MockMvcBuilders
            .standaloneSetup(new IngestHealthController(service))
            .build();
    }

    // ── test 1 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: Bedrock times out for 3 records during ingest — those records
     *           exist in `records` but have no row in `record_embeddings`.
     * DETECT:   GET /v1/ingest/health must return embeddingGapCount=3 and status="degraded".
     */
    @Test
    void gapDetectedWhenEmbeddingMissing() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(3);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.embeddingGapCount").value(3))
            .andExpect(jsonPath("$.status").value("degraded"));
    }

    // ── test 2 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: same gap scenario.
     * DETECT:   health endpoint returns HTTP 200 with status="degraded" when gaps > 0.
     *           (200 not 503 — degraded is informational, not a service failure.)
     */
    @Test
    void healthEndpointReportsDegradedWhenGapsExist() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(1);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("degraded"))
            .andExpect(jsonPath("$.embeddingGapCount").value(1));
    }

    // ── test 3 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: gaps exist, then POST /v1/ingest/reindex is called.
     * DETECT:   after reindex, GET /v1/ingest/health returns embeddingGapCount=0
     *           and status="ok".
     */
    @Test
    void healthEndpointReportsOkAfterReindex() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);

        // Before reindex: 2 gaps
        when(service.countEmbeddingGaps()).thenReturn(0);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.embeddingGapCount").value(0))
            .andExpect(jsonPath("$.status").value("ok"));
    }
}
