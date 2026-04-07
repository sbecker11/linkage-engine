package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * Reranks SQL candidates by cosine similarity against stored embeddings.
 * Skipped transparently when no {@link EmbeddingModel} is available (local profile).
 */
@Service
public class VectorRerankService {

    private static final Logger log = LoggerFactory.getLogger(VectorRerankService.class);

    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;

    @Autowired
    public VectorRerankService(
        @Autowired(required = false) EmbeddingModel embeddingModel,
        @Autowired(required = false) RecordEmbeddingStore recordEmbeddingStore
    ) {
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
    }

    /**
     * Returns a {@link RerankResult} with candidates sorted by similarity descending.
     * If embedding is unavailable or no stored embeddings exist, returns candidates in original order
     * with null similarity scores.
     */
    public RerankResult rerank(List<CandidateRecord> candidates, String queryText) {
        if (embeddingModel == null || recordEmbeddingStore == null || candidates.isEmpty()) {
            log.debug("Vector rerank skipped: embeddingModel={}, store={}, candidates={}",
                embeddingModel != null, recordEmbeddingStore != null, candidates.size());
            List<CandidateScore> scores = candidates.stream()
                .map(c -> new CandidateScore(c.recordId(), null))
                .toList();
            return new RerankResult(candidates, scores, false);
        }

        try {
            float[] queryVector = embeddingModel.embed(new Document(queryText));
            List<String> ids = candidates.stream().map(CandidateRecord::recordId).toList();
            Map<String, Double> sims = recordEmbeddingStore.cosineSimilarityAmong(ids, queryVector);

            if (sims.isEmpty()) {
                log.debug("Vector rerank: no stored embeddings found for {} candidates", candidates.size());
                List<CandidateScore> scores = candidates.stream()
                    .map(c -> new CandidateScore(c.recordId(), null))
                    .toList();
                return new RerankResult(candidates, scores, false);
            }

            List<CandidateRecord> reranked = new ArrayList<>(candidates);
            reranked.sort(Comparator.comparingDouble(
                (CandidateRecord c) -> sims.getOrDefault(c.recordId(), -1.0)
            ).reversed());

            List<CandidateScore> scores = reranked.stream()
                .map(c -> new CandidateScore(c.recordId(), sims.get(c.recordId())))
                .toList();

            log.debug("Vector rerank: reranked {} candidates, top similarity={}",
                reranked.size(), scores.isEmpty() ? "n/a" : scores.get(0).vectorSimilarity());
            return new RerankResult(reranked, scores, true);

        } catch (RuntimeException ex) {
            log.warn("Vector rerank failed, returning original order: {}", ex.getMessage());
            List<CandidateScore> scores = candidates.stream()
                .map(c -> new CandidateScore(c.recordId(), null))
                .toList();
            return new RerankResult(candidates, scores, false);
        }
    }

    record RerankResult(
        List<CandidateRecord> candidates,
        List<CandidateScore> scores,
        boolean rerankApplied
    ) {}
}
