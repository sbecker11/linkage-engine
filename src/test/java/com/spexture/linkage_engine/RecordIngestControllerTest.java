package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
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

    private MockMvc mockMvc;

    @Mock
    private RecordIngestPort recordIngestPort;

    @BeforeEach
    void setUp() {
        RecordIngestController controller = new RecordIngestController(recordIngestPort);
        mockMvc = MockMvcBuilders.standaloneSetup(controller)
            .setControllerAdvice(new ApiExceptionHandler())
            .build();
    }

    @Test
    void ingestReturns204() throws Exception {
        mockMvc.perform(post("/v1/records")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"recordId":"R-2001","givenName":"Ann","familyName":"Lee","eventYear":1920,"location":"NYC"}
                    """))
            .andExpect(status().isNoContent());

        verify(recordIngestPort).ingest(any(RecordIngestRequest.class));
    }

    @Test
    void ingestReturns400WhenRecordIdMissing() throws Exception {
        mockMvc.perform(post("/v1/records")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"givenName":"Ann","familyName":"Lee"}
                    """))
            .andExpect(status().isBadRequest());
    }
}
