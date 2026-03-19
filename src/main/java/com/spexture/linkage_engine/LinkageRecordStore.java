package com.spexture.linkage_engine;

import java.util.List;

public interface LinkageRecordStore {
    int countAllRecords();
    List<CandidateRecord> findDeterministicCandidates(LinkageResolveRequest request);
}
