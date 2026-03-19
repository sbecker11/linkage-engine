package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(LinkageController.class)
class LinkageControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private ChatModel chatModel;

    @Test
    void resolveReturnsBadRequestWhenNameMissing() throws Exception {
        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"\",\"familyName\":\"Smith\"}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("givenName and familyName are required."));
    }

    @Test
    void resolveReturnsRankedCandidates() throws Exception {
        when(chatModel.call(anyString())).thenReturn("Most likely match is R-1001 with high confidence.");

        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"John\",\"familyName\":\"Smith\",\"approxYear\":1851,\"location\":\"Boston\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.strategy").exists())
            .andExpect(jsonPath("$.deterministicMatches").value(1))
            .andExpect(jsonPath("$.candidates[0].recordId").value("R-1001"))
            .andExpect(jsonPath("$.semanticSummary").value("Most likely match is R-1001 with high confidence."));
    }

    @Test
    void resolveReturnsBadGatewayWhenModelFails() throws Exception {
        when(chatModel.call(anyString())).thenThrow(new RuntimeException("bedrock unavailable"));

        mockMvc.perform(post("/v1/linkage/resolve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"givenName\":\"John\",\"familyName\":\"Smith\"}"))
            .andExpect(status().isBadGateway())
            .andExpect(jsonPath("$.error").value("Unable to score linkage candidates with model."));
    }
}
