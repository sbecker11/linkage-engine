package com.spexture.linkage_engine;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/**
 * Sprint 10 — Health endpoint enhancements
 *
 * Simulate: operator calls GET /v1/ingest/health and needs ingest throughput
 *           information to verify the pipeline is running as expected.
 * Detect:   health response lacks lastBatchSize, lastBatchAt, ingestRatePerMin.
 * Mitigate: IngestHealthService tracks these fields; controller includes them.
 */
@ExtendWith(MockitoExtension.class)
class IngestHealthEnhancedTest {

    private MockMvc mvc(IngestHealthService service) {
        return MockMvcBuilders
            .standaloneSetup(new IngestHealthController(service))
            .build();
    }

    // ── test 1 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: a batch of 42 records was just ingested.
     * DETECT:   health response does not include lastBatchSize.
     * VERIFY:   GET /v1/ingest/health returns lastBatchSize=42.
     */
    @Test
    void healthIncludesLastBatchSize() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(0);
        when(service.countPendingMigrations()).thenReturn(0);
        when(service.getLastBatchSize()).thenReturn(42);
        when(service.getLastBatchAt()).thenReturn("2026-04-08T12:00:00Z");
        when(service.getIngestRatePerMin()).thenReturn(14.0);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.lastBatchSize").value(42))
            .andExpect(jsonPath("$.lastBatchAt").value("2026-04-08T12:00:00Z"))
            .andExpect(jsonPath("$.ingestRatePerMin").value(14.0));
    }

    // ── test 2 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: no batches have been processed since startup.
     * DETECT:   health response omits lastBatchSize / lastBatchAt entirely.
     * VERIFY:   fields are present with zero/null sentinel values, not absent.
     */
    @Test
    void healthShowsZeroWhenNoBatchesProcessed() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(0);
        when(service.countPendingMigrations()).thenReturn(0);
        when(service.getLastBatchSize()).thenReturn(0);
        when(service.getLastBatchAt()).thenReturn(null);
        when(service.getIngestRatePerMin()).thenReturn(0.0);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.lastBatchSize").value(0))
            .andExpect(jsonPath("$.ingestRatePerMin").value(0.0));
    }
}
