package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(ChatController.class)
class ChatControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private ChatModel chatModel;

    @MockBean
    private LinkageRecordStore linkageRecordStore;

    @MockBean
    private LinkageRecordMutator linkageRecordMutator;

    @Test
    void askReturnsModelResponse() throws Exception {
        when(chatModel.call("hello")).thenReturn("hi there");

        mockMvc.perform(get("/api/ask").param("q", "hello"))
            .andExpect(status().isOk())
            .andExpect(content().string("hi there"));
    }

    @Test
    void askReturnsBadGatewayWhenModelFails() throws Exception {
        when(chatModel.call(anyString())).thenThrow(new RuntimeException("model unavailable"));

        mockMvc.perform(get("/api/ask").param("q", "hello"))
            .andExpect(status().isBadGateway())
            .andExpect(jsonPath("$.error").value("Unable to get response from model."));
    }

    @Test
    void dateTimeAtLocationReturnsModelResponse() throws Exception {
        when(chatModel.call(anyString())).thenReturn("Current time in Chicago is ...");

        mockMvc.perform(post("/api/dateTimeAtLocation")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"location\":\"Chicago\"}"))
            .andExpect(status().isOk())
            .andExpect(content().string("Current time in Chicago is ..."));
    }
}
