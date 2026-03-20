package com.spexture.linkage_engine;

import java.util.Collection;
import java.util.Map;

/**
 * Persists and scores vectors in {@code record_embeddings} (pgvector).
 */
public interface RecordEmbeddingStore {

    /**
     * Cosine similarity scores in [0,1] for rows that exist; ids without a row are omitted.
     */
    Map<String, Double> cosineSimilarityAmong(Collection<String> recordIds, float[] queryEmbedding);

    void upsertEmbedding(String recordId, float[] embedding, String modelId);
}
