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
 * Sprint 5 — Migration Safety
 *
 * Simulate: a Flyway migration is pending while the store Lambda is mid-ingest.
 * Detect:   GET /v1/ingest/health exposes flywayStatus and pendingMigrations.
 * Mitigate: store Lambda calls health before processing; aborts when degraded.
 */
@ExtendWith(MockitoExtension.class)
class MigrationSafetyTest {

    private MockMvc mvc(IngestHealthService service) {
        return MockMvcBuilders
            .standaloneSetup(new IngestHealthController(service))
            .build();
    }

    // ── test 1 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: no pending migrations — normal steady state.
     * DETECT:   health endpoint must include flywayStatus="up-to-date"
     *           and pendingMigrations=0.
     * VERIFY:   GET /v1/ingest/health returns both fields with expected values.
     */
    @Test
    void healthIncludesFlywayStatus() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(0);
        when(service.countPendingMigrations()).thenReturn(0);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.flywayStatus").value("up-to-date"))
            .andExpect(jsonPath("$.pendingMigrations").value(0))
            .andExpect(jsonPath("$.status").value("ok"));
    }

    // ── test 2 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: a new Flyway migration script has been added but not yet applied
     *           (e.g. app redeployed before schema migration ran).
     * DETECT:   health endpoint must return flywayStatus="pending",
     *           pendingMigrations=1, and status="degraded".
     * VERIFY:   store Lambda can read this and abort before touching the DB.
     */
    @Test
    void pendingMigrationCausesDegradedStatus() throws Exception {
        IngestHealthService service = mock(IngestHealthService.class);
        when(service.countEmbeddingGaps()).thenReturn(0);
        when(service.countPendingMigrations()).thenReturn(1);

        mvc(service).perform(get("/v1/ingest/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.flywayStatus").value("pending"))
            .andExpect(jsonPath("$.pendingMigrations").value(1))
            .andExpect(jsonPath("$.status").value("degraded"));
    }
}
