package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;

class LinkageServiceSpatioTemporalTest {

    private static final List<CandidateRecord> ONE_CANDIDATE = List.of(
        new CandidateRecord("R-1", "John", "Smith", 1851, "San Francisco")
    );
    private static final List<CandidateScore> ONE_SCORE = List.of(
        new CandidateScore("R-1", null)
    );

    private LinkageService service(ConflictResolver resolver) {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(5);
        when(store.search(any())).thenReturn(ONE_CANDIDATE);

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString())).thenReturn(
            new VectorRerankService.RerankResult(ONE_CANDIDATE, ONE_SCORE, false)
        );

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList())).thenReturn(
            new SemanticSummaryService.SummaryResult("Top candidate: R-1", false)
        );

        return new LinkageService(store, rerank, summary, resolver);
    }

    @Test
    void confidenceDecreasesWhenConflictDetected() {
        // Boston 1850 → SF 1850 (same year, ~120 days required via Cape Horn, but only 1 day available)
        // Use a candidate with year=1850 and same query year=1850 → availableDays=1 → impossible
        List<CandidateRecord> impossibleCandidate = List.of(
            new CandidateRecord("R-1", "John", "Smith", 1850, "San Francisco")
        );
        List<CandidateScore> impossibleScore = List.of(new CandidateScore("R-1", null));

        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.countAllRecords()).thenReturn(5);
        when(store.search(any())).thenReturn(impossibleCandidate);

        VectorRerankService rerank = mock(VectorRerankService.class);
        when(rerank.rerank(anyList(), anyString())).thenReturn(
            new VectorRerankService.RerankResult(impossibleCandidate, impossibleScore, false)
        );

        SemanticSummaryService summary = mock(SemanticSummaryService.class);
        when(summary.summarize(any(), anyList(), anyList())).thenReturn(
            new SemanticSummaryService.SummaryResult("Top candidate: R-1", false)
        );

        ConflictResolver realResolver = new ConflictResolver(new HistoricalTransitService());
        LinkageService svc = new LinkageService(store, rerank, summary, realResolver);

        // Query: Boston 1850 → candidate: SF 1850 → 1 day available, 120 days required
        LinkageResolveRequest request = new LinkageResolveRequest(
            "John", "Smith", 1850, "Boston", null
        );
        LinkageResolveResponse response = svc.resolve(request);

        assertThat(response.spatioTemporalResult()).isNotNull();
        assertThat(response.spatioTemporalResult().plausible()).isFalse();
        assertThat(response.confidenceScore()).isLessThan(0.8);
        assertThat(response.rulesTriggered()).contains("spatiotemporal_validation");
    }

    @Test
    void confidenceUnchangedWhenPlausible() {
        // Mock resolver that always returns plausible with zero penalty
        ConflictResolver mockResolver = mock(ConflictResolver.class);
        when(mockResolver.resolve(any())).thenReturn(
            new SpatioTemporalResponse(true, 1.5, 365.0, 363.5, "railroad_eastern", List.of(), 0)
        );

        LinkageService svc = service(mockResolver);
        LinkageResolveRequest request = new LinkageResolveRequest(
            "John", "Smith", 1850, "Philadelphia", null
        );
        double baseScore = svc.resolve(request).confidenceScore();

        // Run again with no spatio penalty — score should be the same
        LinkageResolveResponse response = svc.resolve(request);
        assertThat(response.confidenceScore()).isEqualTo(baseScore);
        assertThat(response.spatioTemporalResult().plausible()).isTrue();
    }

    @Test
    void spatioTemporalSkippedWhenNoLocation() {
        ConflictResolver resolver = mock(ConflictResolver.class);
        LinkageService svc = service(resolver);

        // No location → spatio-temporal should be skipped
        LinkageResolveRequest request = new LinkageResolveRequest(
            "John", "Smith", 1850, null, null
        );
        LinkageResolveResponse response = svc.resolve(request);

        assertThat(response.spatioTemporalResult()).isNull();
        assertThat(response.rulesTriggered()).doesNotContain("spatiotemporal_validation");
    }
}
