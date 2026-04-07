package com.spexture.linkage_engine;

import java.util.List;

public interface LinkageRecordStore {
    int countAllRecords();
    /** Exact-match deterministic search (legacy, ±2 year). */
    List<CandidateRecord> findDeterministicCandidates(LinkageResolveRequest request);
    /** Broader search: partial name (LIKE), ±5 year window, optional location, limit 20. */
    List<CandidateRecord> search(RecordSearchRequest request);
    /**
     * Returns all records created or updated at or after {@code since} (epoch millis).
     * Pass {@code null} to return all records.
     */
    List<ReindexRecord> findSince(java.time.Instant since);

    /**
     * Returns candidates near the given location and year (±{@code yearTolerance}).
     * Used for neighborhood snapshot aggregation.
     */
    List<CandidateRecord> findByLocationAndYearRange(String location, int year, int yearTolerance);
}
