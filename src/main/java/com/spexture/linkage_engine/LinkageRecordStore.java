package com.spexture.linkage_engine;

import java.util.List;

public interface LinkageRecordStore {
    int countAllRecords();
    /** Exact-match deterministic search (legacy, ±2 year). */
    List<CandidateRecord> findDeterministicCandidates(LinkageResolveRequest request);
    /** Broader search: partial name (LIKE), ±5 year window, optional location, limit 20. */
    List<CandidateRecord> search(RecordSearchRequest request);
}
