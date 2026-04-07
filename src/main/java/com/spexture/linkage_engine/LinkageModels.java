package com.spexture.linkage_engine;

import java.util.List;

import jakarta.validation.constraints.NotBlank;

record LinkageResolveRequest(
    @NotBlank(message = "givenName is required")
    String givenName,
    @NotBlank(message = "familyName is required")
    String familyName,
    Integer approxYear,
    String location,
    /** Optional free-text query used for embedding; falls back to structured fields if absent. */
    String rawQuery
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
    String semanticSummary,
    /** Null when no top-candidate pair was available for validation. */
    SpatioTemporalResponse spatioTemporalResult
) {}

/**
 * Broader search request: partial name match, ±5 year window, optional location, limit 20.
 * {@code rawQuery} is the free-text string used for embedding (falls back to structured fields).
 */
record RecordSearchRequest(
    String givenName,
    String familyName,
    Integer approxYear,
    String location,
    String rawQuery
) {}

/**
 * One anchor point in a spatio-temporal plausibility check.
 * {@code lat}/{@code lon} are optional; if absent, {@code location} is resolved via the built-in city table.
 */
record SpatioTemporalRecord(
    String recordId,
    String location,
    Double lat,
    Double lon,
    int year,
    Integer month
) {}

record SpatioTemporalRequest(
    SpatioTemporalRecord from,
    SpatioTemporalRecord to
) {}

record SpatioTemporalResponse(
    boolean plausible,
    double travelDays,
    double availableDays,
    double margin,
    String transitMode,
    List<String> rulesTriggered,
    int confidenceAdjustment
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
    /** Raw transcription text from the original document (OCR output, typed notes, etc.). Cleansed before embedding. */
    String rawContent,
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
