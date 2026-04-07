package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

class VectorRerankServiceTest {

    private static final List<CandidateRecord> TWO_CANDIDATES = List.of(
        new CandidateRecord("R-A", "John", "Smith", 1850, "Boston"),
        new CandidateRecord("R-B", "John", "Smith", 1851, "Boston")
    );

    @Test
    void reranksDescendingBySimilarity() {
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        when(embed.embed(any(Document.class))).thenReturn(new float[1024]);
        when(store.cosineSimilarityAmong(any(), any())).thenReturn(Map.of("R-A", 0.5, "R-B", 0.9));

        VectorRerankService service = new VectorRerankService(embed, store);
        VectorRerankService.RerankResult result = service.rerank(TWO_CANDIDATES, "John Smith 1850 Boston");

        assertThat(result.rerankApplied()).isTrue();
        assertThat(result.candidates().get(0).recordId()).isEqualTo("R-B");
        assertThat(result.candidates().get(1).recordId()).isEqualTo("R-A");
        assertThat(result.scores().get(0).vectorSimilarity()).isEqualTo(0.9);
        assertThat(result.scores().get(1).vectorSimilarity()).isEqualTo(0.5);
    }

    @Test
    void returnsOriginalOrderWhenNoEmbeddingModel() {
        VectorRerankService service = new VectorRerankService(null, null);
        VectorRerankService.RerankResult result = service.rerank(TWO_CANDIDATES, "query");

        assertThat(result.rerankApplied()).isFalse();
        assertThat(result.candidates()).isEqualTo(TWO_CANDIDATES);
        assertThat(result.scores()).allMatch(s -> s.vectorSimilarity() == null);
    }

    @Test
    void returnsOriginalOrderWhenNoStoredEmbeddings() {
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        when(embed.embed(any(Document.class))).thenReturn(new float[1024]);
        when(store.cosineSimilarityAmong(any(), any())).thenReturn(Map.of());

        VectorRerankService service = new VectorRerankService(embed, store);
        VectorRerankService.RerankResult result = service.rerank(TWO_CANDIDATES, "query");

        assertThat(result.rerankApplied()).isFalse();
        assertThat(result.candidates()).isEqualTo(TWO_CANDIDATES);
    }

    @Test
    void returnsOriginalOrderWhenEmbedFails() {
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        when(embed.embed(any(Document.class))).thenThrow(new RuntimeException("bedrock unavailable"));

        VectorRerankService service = new VectorRerankService(embed, store);
        VectorRerankService.RerankResult result = service.rerank(TWO_CANDIDATES, "query");

        assertThat(result.rerankApplied()).isFalse();
        verify(store, never()).cosineSimilarityAmong(any(), any());
    }

    @Test
    void returnsEmptyResultForEmptyCandidates() {
        VectorRerankService service = new VectorRerankService(null, null);
        VectorRerankService.RerankResult result = service.rerank(List.of(), "query");

        assertThat(result.rerankApplied()).isFalse();
        assertThat(result.candidates()).isEmpty();
        assertThat(result.scores()).isEmpty();
    }
}
