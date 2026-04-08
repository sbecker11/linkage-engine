package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class RecordIngestControllerTest {

    private static final String VALID_KEY  = "test-api-key-abc123";
    private static final String WRONG_KEY  = "wrong-key";
    private static final String VALID_BODY = """
        {"recordId":"R-2001","givenName":"Ann","familyName":"Lee","eventYear":1920,"location":"NYC"}
        """;

    private MockMvc mockMvc;

    @Mock
    private RecordIngestPort recordIngestPort;

    @BeforeEach
    void setUp() {
        RecordIngestController controller = new RecordIngestController(recordIngestPort);
        ApiKeyFilter filter = new ApiKeyFilter(VALID_KEY);
        mockMvc = MockMvcBuilders.standaloneSetup(controller)
            .addFilter(filter, "/v1/records")
            .setControllerAdvice(new ApiExceptionHandler())
            .build();
    }

    // ── existing tests (must stay green) ─────────────────────────────────────

    @Test
    void ingestReturns204() throws Exception {
        mockMvc.perform(post("/v1/records")
                .header("X-Api-Key", VALID_KEY)
                .contentType(MediaType.APPLICATION_JSON)
                .content(VALID_BODY))
            .andExpect(status().isNoContent());

        verify(recordIngestPort).ingest(any(RecordIngestRequest.class));
    }

    @Test
    void ingestReturns400WhenRecordIdMissing() throws Exception {
        mockMvc.perform(post("/v1/records")
                .header("X-Api-Key", VALID_KEY)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"givenName":"Ann","familyName":"Lee"}
                    """))
            .andExpect(status().isBadRequest());
    }

    // ── Sprint 9 — API key authentication ────────────────────────────────────

    /**
     * SIMULATE: Lambda (or attacker) calls POST /v1/records without an API key.
     * DETECT:   request reaches the ingest service and records are written.
     * MITIGATE: ApiKeyFilter rejects missing X-Api-Key with 401.
     * VERIFY:   response is 401 and ingest port is never called.
     */
    @Test
    void ingestReturns401WithoutApiKey() throws Exception {
        mockMvc.perform(post("/v1/records")
                .contentType(MediaType.APPLICATION_JSON)
                .content(VALID_BODY))
            .andExpect(status().isUnauthorized());

        verify(recordIngestPort, never()).ingest(any());
    }

    /**
     * SIMULATE: Lambda presents a wrong API key (e.g. stale rotated secret).
     * DETECT:   request is accepted despite wrong credentials.
     * MITIGATE: ApiKeyFilter rejects mismatched X-Api-Key with 401.
     * VERIFY:   response is 401 and ingest port is never called.
     */
    @Test
    void ingestReturns401WithWrongApiKey() throws Exception {
        mockMvc.perform(post("/v1/records")
                .header("X-Api-Key", WRONG_KEY)
                .contentType(MediaType.APPLICATION_JSON)
                .content(VALID_BODY))
            .andExpect(status().isUnauthorized());

        verify(recordIngestPort, never()).ingest(any());
    }

    /**
     * SIMULATE: Lambda presents the correct API key.
     * VERIFY:   request passes through, ingest port is called, response is 204.
     */
    @Test
    void ingestReturns204WithValidApiKey() throws Exception {
        mockMvc.perform(post("/v1/records")
                .header("X-Api-Key", VALID_KEY)
                .contentType(MediaType.APPLICATION_JSON)
                .content(VALID_BODY))
            .andExpect(status().isNoContent());

        verify(recordIngestPort).ingest(any(RecordIngestRequest.class));
    }
}
