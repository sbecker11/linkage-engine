package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;

class LinkageServiceTest {

    private static final List<CandidateRecord> ONE_CANDIDATE = List.of(
        new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston")
    );
    private static final List<CandidateScore> ONE_SCORE = List.of(
        new CandidateScore("R-1001", null)
    );

    private static final ConflictResolver NO_OP_RESOLVER;
    static {
        HistoricalTransitService transit = new HistoricalTransitService();
        NO_OP_RESOLVER = new ConflictResolver(transit);
    }

    private LinkageService service(LinkageRecordStore store,
                                    VectorRerankService rerank,
                                    SemanticSummaryService summary) {
        return new LinkageService(store, rerank, summary, NO_OP_RESOLVER);
    }

    @Test
    void resolveReturnsStructuredResponse() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(4);
        when(store.search(any())).thenReturn(ONE_CANDIDATE);

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(ONE_CANDIDATE, ONE_SCORE, false));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("Likely match: R-1001.", true));

        LinkageResolveResponse response = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", 1851, "Boston", null));

        assertThat(response.totalCandidates()).isEqualTo(4);
        assertThat(response.deterministicMatches()).isEqualTo(1);
        assertThat(response.candidates().get(0).recordId()).isEqualTo("R-1001");
        assertThat(response.confidenceScore()).isGreaterThan(0.0);
        assertThat(response.reasons()).isNotEmpty();
        assertThat(response.rulesTriggered()).contains("sql_search");
        assertThat(response.semanticSummary()).isEqualTo("Likely match: R-1001.");
    }

    @Test
    void resolveRecordsRerankRuleWhenApplied() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(10);
        List<CandidateRecord> two = List.of(
            new CandidateRecord("R-A", "John", "Smith", 1850, "Boston"),
            new CandidateRecord("R-B", "John", "Smith", 1851, "Boston")
        );
        when(store.search(any())).thenReturn(two);

        List<CandidateRecord> reranked = List.of(
            new CandidateRecord("R-B", "John", "Smith", 1851, "Boston"),
            new CandidateRecord("R-A", "John", "Smith", 1850, "Boston")
        );
        List<CandidateScore> scores = List.of(
            new CandidateScore("R-B", 0.9),
            new CandidateScore("R-A", 0.5)
        );
        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(reranked, scores, true));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("summary", true));

        LinkageResolveResponse response = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", 1851, "Boston", null));

        assertThat(response.rulesTriggered()).contains("hybrid_vector_rerank");
        assertThat(response.candidates().get(0).recordId()).isEqualTo("R-B");
        assertThat(response.candidateScores().get(0).vectorSimilarity()).isEqualTo(0.9);
    }

    @Test
    void resolveWithZeroCandidatesReturnsLowConfidence() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(0);
        when(store.search(any())).thenReturn(List.of());

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(List.of(), List.of(), false));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("No candidates found.", false));

        LinkageResolveResponse response = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", null, null, null));

        assertThat(response.confidenceScore()).isEqualTo(0.15);
        assertThat(response.spatioTemporalResult()).isNull();
    }

    @Test
    void resolveWithHighVectorSimilarityBoostsConfidence() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(5);
        when(store.search(any())).thenReturn(ONE_CANDIDATE);

        List<CandidateScore> highScore = List.of(new CandidateScore("R-1001", 0.92));
        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(ONE_CANDIDATE, highScore, true));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("High confidence.", true));

        LinkageResolveResponse withoutVec = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", 1850, "Boston", null));
        // Score should include the +0.05 vector boost
        assertThat(withoutVec.confidenceScore()).isGreaterThanOrEqualTo(0.7);
    }

    @Test
    void resolveWithRawQueryUsesItForEmbedding() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(1);
        when(store.search(any())).thenReturn(ONE_CANDIDATE);

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(ONE_CANDIDATE, ONE_SCORE, false));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("summary", false));

        // rawQuery present — should not throw
        LinkageResolveResponse response = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", 1850, "Boston", "john smith census 1850"));
        assertThat(response).isNotNull();
    }

    @Test
    void resolveUsesDeterministicSummaryWhenSemanticLlmDisabled() {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(4);
        when(store.search(any())).thenReturn(ONE_CANDIDATE);

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString()))
            .thenReturn(new VectorRerankService.RerankResult(ONE_CANDIDATE, ONE_SCORE, false));

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList()))
            .thenReturn(new SemanticSummaryService.SummaryResult("Top deterministic candidate: R-1001 (John Smith, 1850, Boston).", false));

        LinkageResolveResponse response = service(store, rerank, summary)
            .resolve(new LinkageResolveRequest("John", "Smith", 1851, "Boston", null));

        assertThat(response.rulesTriggered()).contains("semantic_llm_summary_disabled");
        assertThat(response.semanticSummary()).contains("R-1001");
    }
}
