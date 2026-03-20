package com.spexture.linkage_engine;

/**
 * Writes {@code records} rows (upsert).
 */
public interface LinkageRecordMutator {

    void upsertRecord(RecordIngestRequest request);
}
