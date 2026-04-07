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
 * Kept for internal pipeline use; the public API surface uses {@link RankedCandidate}.
 */
record CandidateScore(String recordId, Double vectorSimilarity) {}

/**
 * A candidate with its inline similarity score — the public-facing shape returned in
 * {@link LinkageResolveResponse#rankedCandidates()}.
 * {@code vectorSimilarity} is {@code null} when embeddings are not active (local profile).
 */
record RankedCandidate(
    String recordId,
    String givenName,
    String familyName,
    Integer year,
    String location,
    Double vectorSimilarity
) {}

record LinkageResolveResponse(
    String strategy,
    int totalCandidates,
    int deterministicMatches,
    List<RankedCandidate> rankedCandidates,
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
 * Full record as stored in the {@code records} table — used by the list endpoint
 * and the chord-diagram data pipeline.
 */
record LinkageRecord(
    String recordId,
    String givenName,
    String familyName,
    Integer year,
    String location
) {}

/** Full record projection used by the reindex pipeline. */
record ReindexRecord(
    String recordId,
    String givenName,
    String familyName,
    Integer eventYear,
    String location,
    String source,
    String rawContent
) {}

/** Result item from a semantic similarity search. */
record SemanticSearchResult(
    String recordId,
    double score,
    String snippet,
    java.util.Map<String, Object> metadata
) {}

/** Response envelope for GET /v1/search/semantic. */
record SemanticSearchResponse(
    List<SemanticSearchResult> results,
    boolean localProfile,
    int totalResults
) {}

/** Response for PUT /v1/vectors/reindex. */
record ReindexResponse(
    int recordsProcessed,
    int chunksWritten,
    long durationMs,
    List<String> errors
) {}

/** Aggregated neighborhood context for GET /v1/context/neighborhood-snapshot. */
record NeighborhoodSnapshot(
    String location,
    int year,
    int recordCount,
    List<String> commonNames,
    int yearRangeMin,
    int yearRangeMax,
    String contextSummary,
    boolean llmUsed
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
