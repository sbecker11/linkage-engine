-- Sprint 7 — Database Performance
--
-- Adds three indices to address the most common query patterns:
--
-- 1. Composite index on (lower(family_name), event_year)
--    Covers the primary linkage query: name + year filter in LinkageRecordRepository.
--    lower() ensures case-insensitive matching without a separate cleansed column.
--
-- 2. Partial index on birth_year IS NOT NULL
--    AgeConsistencyRule and BiologicalPlausibilityRule filter on birth_year presence.
--    Partial index avoids indexing the majority of rows where birth_year is NULL.
--
-- 3. HNSW approximate nearest-neighbour index on record_embeddings.embedding
--    Replaces the default IVFFlat exact scan with HNSW for sub-linear vector search.
--    m=16 (max connections per layer) and ef_construction=64 are pgvector defaults;
--    tune ef_search at query time via SET hnsw.ef_search = 100 for higher recall.
--    Requires pgvector >= 0.5.0.

-- 1. Composite index: name + year (primary linkage query pattern)
CREATE INDEX IF NOT EXISTS idx_records_family_name_event_year
    ON records (lower(family_name), event_year);

-- 2. Partial index: records with a known birth year (age-rule filter)
CREATE INDEX IF NOT EXISTS idx_records_birth_year_not_null
    ON records (birth_year)
    WHERE birth_year IS NOT NULL;

-- 3. HNSW vector index (approximate nearest-neighbour — replaces exact scan)
CREATE INDEX IF NOT EXISTS idx_record_embeddings_hnsw
    ON record_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
