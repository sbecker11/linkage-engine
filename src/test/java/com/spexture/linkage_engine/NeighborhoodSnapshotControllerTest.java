package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class NeighborhoodSnapshotControllerTest {

    private static final List<CandidateRecord> PHILLY_RECORDS = List.of(
        new CandidateRecord("R-1", "John", "Smith", 1850, "Philadelphia"),
        new CandidateRecord("R-2", "John", "Smith", 1851, "Philadelphia"),
        new CandidateRecord("R-3", "Mary", "Jones", 1849, "Philadelphia"),
        new CandidateRecord("R-4", "Mary", "Jones", 1852, "Philadelphia"),
        new CandidateRecord("R-5", "William", "Brown", 1850, "Philadelphia")
    );

    private LinkageRecordStore store;
    private MockMvc mockMvc;

    @BeforeEach
    void setUp() {
        store = mock(LinkageRecordStore.class);
        when(store.findByLocationAndYearRange(anyString(), anyInt(), anyInt()))
            .thenReturn(PHILLY_RECORDS);
    }

    @Test
    void aggregatesCorrectly() throws Exception {
        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, null, false)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Philadelphia")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.location").value("Philadelphia"))
            .andExpect(jsonPath("$.year").value(1850))
            .andExpect(jsonPath("$.recordCount").value(5))
            .andExpect(jsonPath("$.yearRangeMin").value(1849))
            .andExpect(jsonPath("$.yearRangeMax").value(1852))
            .andExpect(jsonPath("$.llmUsed").value(false));
    }

    @Test
    void commonNamesContainTopFrequencyNames() throws Exception {
        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, null, false)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Philadelphia")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.commonNames").isArray())
            // "John Smith" appears twice — should be first
            .andExpect(jsonPath("$.commonNames[0]").value("John Smith"));
    }

    @Test
    void deterministicSummaryWhenLlmDisabled() throws Exception {
        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, null, false)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Philadelphia")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.contextSummary").value(
                org.hamcrest.Matchers.containsString("5 records found near Philadelphia")))
            .andExpect(jsonPath("$.llmUsed").value(false));
    }

    @Test
    void llmSummaryWhenChatModelPresent() throws Exception {
        ChatModel chatModel = mock(ChatModel.class);
        when(chatModel.call(anyString())).thenReturn("Philadelphia in 1850 was a bustling industrial city.");

        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, chatModel, true)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Philadelphia")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.contextSummary").value("Philadelphia in 1850 was a bustling industrial city."))
            .andExpect(jsonPath("$.llmUsed").value(true));
    }

    @Test
    void fallsBackToDeterministicWhenChatModelThrows() throws Exception {
        ChatModel chatModel = mock(ChatModel.class);
        when(chatModel.call(anyString())).thenThrow(new RuntimeException("Bedrock throttled"));

        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, chatModel, true)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Philadelphia")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.llmUsed").value(false))
            .andExpect(jsonPath("$.contextSummary").value(
                org.hamcrest.Matchers.containsString("5 records found")));
    }

    @Test
    void emptyResultsWhenNoRecordsFound() throws Exception {
        when(store.findByLocationAndYearRange(anyString(), anyInt(), anyInt()))
            .thenReturn(List.of());

        mockMvc = MockMvcBuilders.standaloneSetup(
            new NeighborhoodSnapshotController(store, null, false)).build();

        mockMvc.perform(get("/v1/context/neighborhood-snapshot")
                .param("location", "Nowhere")
                .param("year", "1850"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.recordCount").value(0))
            .andExpect(jsonPath("$.contextSummary").value(
                org.hamcrest.Matchers.containsString("No records found")));
    }
}
