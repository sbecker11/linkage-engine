package com.spexture.linkage_engine;

import java.util.List;

import jakarta.validation.constraints.NotBlank;

record LinkageResolveRequest(
    @NotBlank(message = "givenName is required")
    String givenName,
    @NotBlank(message = "familyName is required")
    String familyName,
    Integer approxYear,
    String location
) {}

record CandidateRecord(String recordId, String givenName, String familyName, Integer year, String location) {}

/**
 * Cosine similarity score after SQL narrowing; {@code vectorSimilarity} is null when no embedding exists for that row.
 */
record CandidateScore(String recordId, Double vectorSimilarity) {}

record LinkageResolveResponse(
    String strategy,
    int totalCandidates,
    int deterministicMatches,
    List<CandidateRecord> candidates,
    List<CandidateScore> candidateScores,
    double confidenceScore,
    List<String> reasons,
    List<String> rulesTriggered,
    String semanticSummary
) {}

record RecordIngestRequest(
    @NotBlank(message = "recordId is required")
    String recordId,
    @NotBlank(message = "givenName is required")
    String givenName,
    @NotBlank(message = "familyName is required")
    String familyName,
    Integer eventYear,
    String location,
    String source,
    /** When true (default), compute and store an embedding if an {@link org.springframework.ai.embedding.EmbeddingModel} bean exists. */
    Boolean computeEmbedding
) {

    RecordIngestRequest {
        if (source == null || source.isBlank()) {
            source = "ingest-api";
        }
        if (computeEmbedding == null) {
            computeEmbedding = Boolean.TRUE;
        }
    }
}
