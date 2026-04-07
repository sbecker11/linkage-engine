package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * Orchestrates the four-stage hybrid linkage resolution pipeline:
 *
 * <pre>
 * POST /v1/linkage/resolve
 *   └─ Stage 1: SQL search          — deterministic narrowing via name/year/location filters (always on)
 *   └─ Stage 2: vector rerank       — cosine similarity reorder (gates on EmbeddingModel bean)
 *   └─ Stage 3: semantic summary    — LLM narrative (gates on ChatModel + LINKAGE_SEMANTIC_LLM_ENABLED)
 *   └─ Stage 4: spatio-temporal     — historical transit plausibility check (always on; no-op when location/year absent)
 * </pre>
 *
 * <p>Each stage degrades gracefully when its dependency is absent. The local profile runs
 * all four stages end-to-end without Bedrock credentials.
 *
 * <p>Dependency injection uses {@link org.springframework.beans.factory.ObjectProvider} for
 * optional beans rather than {@code @ConditionalOnBean} — bean ordering in autoconfiguration
 * is non-deterministic; runtime null-checks via ObjectProvider are not.
 */
@Service
public class LinkageService implements LinkageResolver {

    private static final Logger log = LoggerFactory.getLogger(LinkageService.class);

    private final LinkageRecordStore linkageRecordStore;
    private final VectorRerankService vectorRerankService;
    private final SemanticSummaryService semanticSummaryService;
    private final ConflictResolver conflictResolver;

    @Autowired
    public LinkageService(
        LinkageRecordStore linkageRecordStore,
        VectorRerankService vectorRerankService,
        SemanticSummaryService semanticSummaryService,
        ConflictResolver conflictResolver
    ) {
        this.linkageRecordStore = linkageRecordStore;
        this.vectorRerankService = vectorRerankService;
        this.semanticSummaryService = semanticSummaryService;
        this.conflictResolver = conflictResolver;
    }

    @Override
    public LinkageResolveResponse resolve(LinkageResolveRequest request) {
        List<String> rulesTriggered = new ArrayList<>();

        // Stage 1 — SQL search
        int totalRecords = linkageRecordStore.countAllRecords();
        RecordSearchRequest searchRequest = toSearchRequest(request);
        List<CandidateRecord> sqlCandidates = linkageRecordStore.search(searchRequest);
        log.info("[resolve] stage=sql total={} candidates={} givenName={} familyName={} year={} location={}",
            totalRecords, sqlCandidates.size(),
            request.givenName(), request.familyName(), request.approxYear(), request.location());
        rulesTriggered.add("sql_search");
        if (request.approxYear() != null) rulesTriggered.add("year_window_filter");
        if (!isBlank(request.location()))  rulesTriggered.add("location_filter");

        // Stage 2 — vector rerank
        String queryText = buildQueryText(request);
        VectorRerankService.RerankResult rerank = vectorRerankService.rerank(sqlCandidates, queryText);
        log.info("[resolve] stage=rerank applied={} candidates={}",
            rerank.rerankApplied(), rerank.candidates().size());
        if (rerank.rerankApplied()) rulesTriggered.add("hybrid_vector_rerank");

        // Stage 3 — semantic summary
        SemanticSummaryService.SummaryResult summary =
            semanticSummaryService.summarize(searchRequest, rerank.candidates(), rerank.scores());
        log.info("[resolve] stage=summary llmUsed={} summaryLen={}",
            summary.llmUsed(), summary.summary().length());
        rulesTriggered.add(summary.llmUsed() ? "semantic_llm_summary" : "semantic_llm_summary_disabled");

        // Merge candidates + scores into a single ranked list
        List<RankedCandidate> rankedCandidates = mergeRanked(rerank.candidates(), rerank.scores());

        double confidenceScore = computeConfidenceScore(rerank.candidates().size(), request, rerank.scores());

        // Stage 4 — spatio-temporal validation on query→top-candidate pair
        SpatioTemporalResponse spatioResult = null;
        if (!rerank.candidates().isEmpty() && !isBlank(request.location()) && request.approxYear() != null) {
            CandidateRecord top = rerank.candidates().get(0);
            if (top.year() != null && !isBlank(top.location())) {
                SpatioTemporalRequest spatioReq = new SpatioTemporalRequest(
                    new SpatioTemporalRecord("query", request.givenName(), request.location(), null, null,
                        request.approxYear(), null, null),
                    new SpatioTemporalRecord(top.recordId(), top.givenName(), top.location(), null, null,
                        top.year(), null, null)
                );
                spatioResult = conflictResolver.resolve(spatioReq);
                log.info("[resolve] stage=spatiotemporal plausible={} adjustment={}",
                    spatioResult.plausible(), spatioResult.confidenceAdjustment());
                rulesTriggered.add("spatiotemporal_validation");
                if (spatioResult.confidenceAdjustment() > 0) {
                    confidenceScore = Math.max(0.05,
                        confidenceScore - spatioResult.confidenceAdjustment() / 100.0);
                }
            }
        }

        List<String> reasons = buildReasons(totalRecords, sqlCandidates.size(), rerank, request, spatioResult);

        return new LinkageResolveResponse(
            "sql-search → vector-rerank → semantic-summary → spatiotemporal-validation",
            totalRecords,
            sqlCandidates.size(),
            rankedCandidates,
            confidenceScore,
            reasons,
            rulesTriggered,
            summary.summary(),
            spatioResult
        );
    }

    private RecordSearchRequest toSearchRequest(LinkageResolveRequest req) {
        return new RecordSearchRequest(
            req.givenName(), req.familyName(), req.approxYear(), req.location(), req.rawQuery()
        );
    }

    private String buildQueryText(LinkageResolveRequest request) {
        if (request.rawQuery() != null && !request.rawQuery().isBlank()) {
            return request.rawQuery();
        }
        return LinkageEmbeddingText.toEmbeddingText(
            request.givenName(), request.familyName(), request.approxYear(), request.location()
        );
    }

    private List<String> buildReasons(int total, int sqlCount,
                                       VectorRerankService.RerankResult rerank,
                                       LinkageResolveRequest request,
                                       SpatioTemporalResponse spatioResult) {
        List<String> reasons = new ArrayList<>();
        reasons.add("SQL search reduced " + total + " records to " + sqlCount + " candidates.");
        if (rerank.rerankApplied()) {
            reasons.add("Reranked by pgvector cosine similarity.");
        }
        if (request.approxYear() != null) {
            reasons.add("Applied year window ±5.");
        }
        if (!isBlank(request.location())) {
            reasons.add("Applied location filter.");
        }
        if (spatioResult != null) {
            reasons.add("Spatio-temporal validation: plausible=" + spatioResult.plausible()
                + " mode=" + spatioResult.transitMode()
                + " travelDays=" + String.format("%.1f", spatioResult.travelDays())
                + " availDays=" + String.format("%.1f", spatioResult.availableDays()) + ".");
        }
        return reasons;
    }

    private double computeConfidenceScore(int candidateCount, LinkageResolveRequest request,
                                           List<CandidateScore> scores) {
        if (candidateCount == 0) return 0.15;
        double score = 0.45 + Math.min(0.3, candidateCount * 0.15);
        if (request.approxYear() != null) score += 0.1;
        if (!isBlank(request.location()))  score += 0.1;
        double topVec = scores.stream()
            .map(CandidateScore::vectorSimilarity)
            .filter(v -> v != null)
            .mapToDouble(Double::doubleValue)
            .max().orElse(0.0);
        if (topVec >= 0.85) score += 0.05;
        return Math.min(0.95, score);
    }

    /** Zips candidates and scores into a single inline list. */
    private List<RankedCandidate> mergeRanked(List<CandidateRecord> candidates,
                                               List<CandidateScore> scores) {
        // Build a score lookup by recordId for O(1) access
        java.util.Map<String, Double> scoreMap = new java.util.HashMap<>();
        for (CandidateScore s : scores) {
            scoreMap.put(s.recordId(), s.vectorSimilarity());
        }
        return candidates.stream()
            .map(c -> new RankedCandidate(
                c.recordId(), c.givenName(), c.familyName(), c.year(), c.location(),
                scoreMap.get(c.recordId())
            ))
            .toList();
    }

    private boolean isBlank(String v) { return v == null || v.isBlank(); }
}
