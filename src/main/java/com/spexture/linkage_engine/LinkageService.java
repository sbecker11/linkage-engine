package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.stereotype.Service;

@Service
@ConditionalOnBean(LinkageRecordStore.class)
public class LinkageService implements LinkageResolver {

    private final ChatModel chatModel;
    private final LinkageRecordStore linkageRecordStore;
    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;

    public LinkageService(
        ChatModel chatModel,
        LinkageRecordStore linkageRecordStore,
        @Autowired(required = false) EmbeddingModel embeddingModel,
        @Autowired(required = false) RecordEmbeddingStore recordEmbeddingStore
    ) {
        this.chatModel = chatModel;
        this.linkageRecordStore = linkageRecordStore;
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
    }

    @Override
    public LinkageResolveResponse resolve(LinkageResolveRequest request) {
        List<String> rulesTriggered = new ArrayList<>();
        rulesTriggered.add("deterministic_name_match");
        if (request.approxYear() != null) {
            rulesTriggered.add("year_window_filter");
        }
        if (!isBlank(request.location())) {
            rulesTriggered.add("location_filter");
        }

        int totalCandidates = linkageRecordStore.countAllRecords();
        List<CandidateRecord> deterministicMatches = linkageRecordStore.findDeterministicCandidates(request);

        List<CandidateRecord> rankedCandidates = deterministicMatches;
        List<CandidateScore> candidateScores = deterministicMatches.stream()
            .map(c -> new CandidateScore(c.recordId(), null))
            .collect(Collectors.toCollection(ArrayList::new));

        if (embeddingModel != null
            && recordEmbeddingStore != null
            && !deterministicMatches.isEmpty()) {
            try {
                String queryText = LinkageEmbeddingText.queryText(request);
                float[] queryVector = embeddingModel.embed(new org.springframework.ai.document.Document(queryText));
                List<String> ids = deterministicMatches.stream().map(CandidateRecord::recordId).toList();
                Map<String, Double> sims = recordEmbeddingStore.cosineSimilarityAmong(ids, queryVector);
                if (!sims.isEmpty()) {
                    rulesTriggered.add("hybrid_vector_rerank");
                    rankedCandidates = new ArrayList<>(deterministicMatches);
                    rankedCandidates.sort(Comparator.comparingDouble(
                        (CandidateRecord c) -> sims.getOrDefault(c.recordId(), -1.0)
                    ).reversed());
                    candidateScores.clear();
                    for (CandidateRecord c : rankedCandidates) {
                        candidateScores.add(new CandidateScore(c.recordId(), sims.get(c.recordId())));
                    }
                }
            } catch (RuntimeException ex) {
                rulesTriggered.add("hybrid_vector_rerank_skipped");
            }
        }

        String semanticSummary = chatModel.call(buildPrompt(request, rankedCandidates));
        double confidenceScore = computeConfidenceScore(rankedCandidates.size(), request, candidateScores);

        List<String> reasons = new ArrayList<>();
        reasons.add("Deterministic SQL filtering reduced records from " + totalCandidates + " to " + deterministicMatches.size() + ".");
        if (rulesTriggered.contains("hybrid_vector_rerank")) {
            reasons.add("Reranked deterministic candidates using pgvector cosine similarity on stored embeddings.");
        }
        if (request.approxYear() != null) {
            reasons.add("Applied approxYear window of +/-2 years.");
        }
        if (!isBlank(request.location())) {
            reasons.add("Applied exact location filter before semantic ranking.");
        }

        return new LinkageResolveResponse(
            "deterministic SQL-style narrowing followed by optional vector rerank and probabilistic semantic summary",
            totalCandidates,
            deterministicMatches.size(),
            rankedCandidates,
            List.copyOf(candidateScores),
            confidenceScore,
            reasons,
            rulesTriggered,
            semanticSummary
        );
    }

    private String buildPrompt(LinkageResolveRequest request, List<CandidateRecord> matches) {
        String header = "You are a linkage resolver. Rank the candidate records and provide a confidence-oriented summary.";
        String query = "Query person: " + request.givenName() + " " + request.familyName()
            + ", approxYear=" + request.approxYear() + ", location=" + request.location() + ".";
        String candidates = "Candidates (after SQL and optional vector rerank): " + matches;
        String instruction = "Explain likely best matches and why in plain text.";
        return String.join(" ", header, query, candidates, instruction);
    }

    private double computeConfidenceScore(int deterministicMatches, LinkageResolveRequest request, List<CandidateScore> scores) {
        if (deterministicMatches == 0) {
            return 0.15;
        }
        double score = 0.45 + Math.min(0.3, deterministicMatches * 0.15);
        if (request.approxYear() != null) {
            score += 0.1;
        }
        if (!isBlank(request.location())) {
            score += 0.1;
        }
        double topVec = scores.stream()
            .map(CandidateScore::vectorSimilarity)
            .filter(v -> v != null)
            .mapToDouble(Double::doubleValue)
            .max()
            .orElse(0.0);
        if (topVec >= 0.85) {
            score += 0.05;
        }
        return Math.min(0.95, score);
    }

    private boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
