package com.spexture.linkage_engine;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
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
class LinkageControllerTest {

    private MockMvc mockMvc;

    @Mock
    private LinkageResolver linkageResolver;

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new LinkageController(linkageResolver))
            .setControllerAdvice(new ApiExceptionHandler())
            .build();
    }

    @Test
    void resolveReturnsBadRequestWhenNameMissing() throws Exception {
        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"\",\"familyName\":\"Smith\"}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("Validation failed."));
    }

    @Test
    void resolveReturnsRankedCandidates() throws Exception {
        LinkageResolveResponse response = new LinkageResolveResponse(
            "deterministic SQL-style narrowing followed by probabilistic semantic ranking",
            4,
            1,
            java.util.List.of(new RankedCandidate("R-1001", "John", "Smith", 1850, "Boston", 0.91)),
            0.8,
            java.util.List.of("Deterministic filtering reduced records."),
            java.util.List.of("deterministic_name_match"),
            "Most likely match is R-1001 with high confidence.",
            null
        );
        when(linkageResolver.resolve(org.mockito.ArgumentMatchers.any())).thenReturn(response);

        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"John\",\"familyName\":\"Smith\",\"approxYear\":1851,\"location\":\"Boston\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.strategy").exists())
            .andExpect(jsonPath("$.deterministicMatches").value(1))
            .andExpect(jsonPath("$.rankedCandidates[0].recordId").value("R-1001"))
            .andExpect(jsonPath("$.rankedCandidates[0].vectorSimilarity").value(0.91))
            .andExpect(jsonPath("$.confidenceScore").value(0.8))
            .andExpect(jsonPath("$.semanticSummary").value("Most likely match is R-1001 with high confidence."));
    }

    @Test
    void resolveReturnsBadGatewayWhenModelFails() throws Exception {
        when(linkageResolver.resolve(org.mockito.ArgumentMatchers.any())).thenThrow(new RuntimeException("bedrock unavailable"));

        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"John\",\"familyName\":\"Smith\"}"))
            .andExpect(status().isBadGateway())
            .andExpect(jsonPath("$.error").value("Unable to score linkage candidates with model."));
    }
}
