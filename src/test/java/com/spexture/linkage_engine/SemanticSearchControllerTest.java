package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class SemanticSearchControllerTest {

    private static final List<CandidateRecord> CANDIDATES = List.of(
        new CandidateRecord("R-1001", "John", "Smith", 1850, "Philadelphia"),
        new CandidateRecord("R-1002", "John", "Smith", 1851, "New York")
    );

    @Test
    void localProfileShortCircuitWhenNoEmbeddingModel() throws Exception {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        SemanticSearchController controller = new SemanticSearchController(null, null, store);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(controller).build();

        mockMvc.perform(get("/v1/search/semantic").param("q", "smith philadelphia"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.localProfile").value(true))
            .andExpect(jsonPath("$.totalResults").value(0))
            .andExpect(jsonPath("$.results").isEmpty());
    }

    @Test
    void returnsFilteredResultsAboveMinScore() throws Exception {
        EmbeddingModel embeddingModel = mock(EmbeddingModel.class);
        RecordEmbeddingStore embeddingStore = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        when(embeddingModel.embed(any(Document.class))).thenReturn(new float[]{0.1f, 0.2f});
        when(recordStore.search(any())).thenReturn(CANDIDATES);
        when(embeddingStore.cosineSimilarityAmong(anyList(), any())).thenReturn(
            Map.of("R-1001", 0.92, "R-1002", 0.60)
        );

        SemanticSearchController controller =
            new SemanticSearchController(embeddingModel, embeddingStore, recordStore);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(controller).build();

        // minScore=0.75 → only R-1001 (0.92) passes
        mockMvc.perform(get("/v1/search/semantic")
                .param("q", "smith philadelphia census")
                .param("minScore", "0.75"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.localProfile").value(false))
            .andExpect(jsonPath("$.totalResults").value(1))
            .andExpect(jsonPath("$.results[0].recordId").value("R-1001"))
            .andExpect(jsonPath("$.results[0].score").value(0.92));
    }

    @Test
    void respectsMaxResultsLimit() throws Exception {
        EmbeddingModel embeddingModel = mock(EmbeddingModel.class);
        RecordEmbeddingStore embeddingStore = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        when(embeddingModel.embed(any(Document.class))).thenReturn(new float[]{0.1f});
        when(recordStore.search(any())).thenReturn(CANDIDATES);
        when(embeddingStore.cosineSimilarityAmong(anyList(), any())).thenReturn(
            Map.of("R-1001", 0.95, "R-1002", 0.90)
        );

        SemanticSearchController controller =
            new SemanticSearchController(embeddingModel, embeddingStore, recordStore);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(controller).build();

        mockMvc.perform(get("/v1/search/semantic")
                .param("q", "john smith")
                .param("maxResults", "1")
                .param("minScore", "0.0"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.totalResults").value(1));
    }

    @Test
    void localProfileShortCircuitWhenNoEmbeddingStore() throws Exception {
        EmbeddingModel em = mock(EmbeddingModel.class);
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        // store present but embeddingStore absent
        SemanticSearchController controller = new SemanticSearchController(em, null, store);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(controller).build();

        mockMvc.perform(get("/v1/search/semantic").param("q", "test"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.localProfile").value(true));
    }

    @Test
    void returnsEmptyWhenNoCandidatesFound() throws Exception {
        EmbeddingModel embeddingModel = mock(EmbeddingModel.class);
        RecordEmbeddingStore embeddingStore = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        when(embeddingModel.embed(any(Document.class))).thenReturn(new float[]{0.1f});
        when(recordStore.search(any())).thenReturn(List.of());

        SemanticSearchController controller =
            new SemanticSearchController(embeddingModel, embeddingStore, recordStore);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(controller).build();

        mockMvc.perform(get("/v1/search/semantic").param("q", "nobody"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.totalResults").value(0))
            .andExpect(jsonPath("$.localProfile").value(false));
    }
}
