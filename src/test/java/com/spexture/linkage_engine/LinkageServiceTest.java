package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

class LinkageServiceTest {

    @Test
    void resolveReturnsStructuredResponse() {
        ChatModel chatModel = mock(ChatModel.class);
        LinkageRecordStore repository = mock(LinkageRecordStore.class);
        when(chatModel.call(anyString())).thenReturn("Likely match: R-1001.");
        when(repository.countAllRecords()).thenReturn(4);
        when(repository.findDeterministicCandidates(any())).thenReturn(List.of(
            new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston")
        ));
        LinkageService service = new LinkageService(chatModel, repository, null, null);

        LinkageResolveResponse response = service.resolve(
            new LinkageResolveRequest("John", "Smith", 1851, "Boston")
        );

        assertEquals(4, response.totalCandidates());
        assertEquals(1, response.deterministicMatches());
        assertEquals("R-1001", response.candidates().get(0).recordId());
        assertEquals(1, response.candidateScores().size());
        assertEquals("R-1001", response.candidateScores().get(0).recordId());
        assertTrue(response.confidenceScore() > 0.0);
        assertFalse(response.reasons().isEmpty());
        assertFalse(response.rulesTriggered().isEmpty());
        assertEquals("Likely match: R-1001.", response.semanticSummary());
    }

    @Test
    void resolveReranksWhenEmbeddingsPresent() {
        ChatModel chatModel = mock(ChatModel.class);
        LinkageRecordStore repository = mock(LinkageRecordStore.class);
        EmbeddingModel embeddingModel = mock(EmbeddingModel.class);
        RecordEmbeddingStore embeddingStore = mock(RecordEmbeddingStore.class);

        when(chatModel.call(anyString())).thenReturn("summary");
        when(repository.countAllRecords()).thenReturn(10);
        when(repository.findDeterministicCandidates(any())).thenReturn(List.of(
            new CandidateRecord("R-A", "John", "Smith", 1850, "Boston"),
            new CandidateRecord("R-B", "John", "Smith", 1851, "Boston")
        ));
        when(embeddingModel.embed(any(Document.class))).thenReturn(new float[1024]);
        when(embeddingStore.cosineSimilarityAmong(any(), any())).thenReturn(Map.of(
            "R-A", 0.5,
            "R-B", 0.9
        ));

        LinkageService service = new LinkageService(chatModel, repository, embeddingModel, embeddingStore);

        LinkageResolveResponse response = service.resolve(
            new LinkageResolveRequest("John", "Smith", 1851, "Boston")
        );

        assertTrue(response.rulesTriggered().contains("hybrid_vector_rerank"));
        assertEquals("R-B", response.candidates().get(0).recordId());
        assertEquals("R-B", response.candidateScores().get(0).recordId());
        assertEquals(0.9, response.candidateScores().get(0).vectorSimilarity(), 0.001);
    }

    @Test
    void resolveUsesDeterministicSummaryWhenSemanticLlmDisabled() {
        ChatModel chatModel = mock(ChatModel.class);
        LinkageRecordStore repository = mock(LinkageRecordStore.class);

        when(repository.countAllRecords()).thenReturn(4);
        when(repository.findDeterministicCandidates(any())).thenReturn(List.of(
            new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston")
        ));

        LinkageService service = new LinkageService(chatModel, repository, null, null, false);

        LinkageResolveResponse response = service.resolve(
            new LinkageResolveRequest("John", "Smith", 1851, "Boston")
        );

        assertTrue(response.rulesTriggered().contains("semantic_llm_summary_disabled"));
        assertTrue(response.semanticSummary().startsWith("Top deterministic candidate: R-1001"));
        verify(chatModel, never()).call(anyString());
    }
}
