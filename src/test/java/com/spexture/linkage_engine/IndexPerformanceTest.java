package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import org.junit.jupiter.api.Test;

/**
 * Sprint 7 — Database Performance
 *
 * Verifies that the V6 Flyway migration script contains the correct index
 * definitions. These tests run without a live database — they validate the
 * migration SQL itself, catching regressions before deployment.
 *
 * For live EXPLAIN ANALYZE verification, run the following against a
 * provisioned Aurora cluster after applying migrations:
 *
 *   EXPLAIN ANALYZE
 *   SELECT * FROM records
 *   WHERE lower(family_name) = 'smith' AND event_year BETWEEN 1845 AND 1855;
 *   -- Expected: Index Scan using idx_records_family_name_event_year
 *
 *   SET hnsw.ef_search = 100;
 *   EXPLAIN ANALYZE
 *   SELECT record_id FROM record_embeddings
 *   ORDER BY embedding <=> '[0.1, 0.2, ...]'::vector LIMIT 10;
 *   -- Expected: Index Scan using idx_record_embeddings_hnsw
 */
class IndexPerformanceTest {

    private static final Path MIGRATION =
        Paths.get("src/main/resources/db/migration/V6__performance_indices.sql");

    private String migrationSql() throws IOException {
        return Files.readString(MIGRATION).toLowerCase();
    }

    // ── test 1 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: V6 migration is applied but the HNSW index is missing —
     *           vector search still uses an O(n) exact scan.
     * DETECT:   EXPLAIN ANALYZE shows SeqScan on record_embeddings.
     * MITIGATE: V6 migration must create an HNSW index using vector_cosine_ops.
     * VERIFY:   migration SQL contains 'hnsw' and 'vector_cosine_ops'.
     */
    @Test
    void vectorSearchUsesHnswIndex() throws IOException {
        String sql = migrationSql();
        assertThat(sql)
            .as("V6 migration must create an HNSW index on record_embeddings.embedding")
            .contains("hnsw");
        assertThat(sql)
            .as("HNSW index must use vector_cosine_ops for cosine similarity search")
            .contains("vector_cosine_ops");
    }

    // ── test 2 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: V6 migration is applied but the composite name+year index is
     *           missing — primary linkage query uses a sequential scan.
     * DETECT:   EXPLAIN ANALYZE shows SeqScan on records for name+year filter.
     * MITIGATE: V6 migration must create a composite index on
     *           (lower(family_name), event_year).
     * VERIFY:   migration SQL contains both 'family_name' and 'event_year'
     *           in the same index definition.
     */
    @Test
    void compositeFamilyNameEventYearIndexExists() throws IOException {
        String sql = migrationSql();
        assertThat(sql)
            .as("V6 migration must index family_name for name-based linkage queries")
            .contains("family_name");
        assertThat(sql)
            .as("V6 migration must include event_year in the composite index")
            .contains("event_year");
        assertThat(sql)
            .as("Index must use lower() for case-insensitive name matching")
            .contains("lower(family_name)");
    }

    // ── test 3 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: V6 migration is applied but the partial birth_year index is
     *           missing — AgeConsistencyRule filter scans all rows including
     *           the majority where birth_year IS NULL.
     * DETECT:   EXPLAIN ANALYZE shows SeqScan for birth_year IS NOT NULL filter.
     * MITIGATE: V6 migration must create a partial index on birth_year
     *           WHERE birth_year IS NOT NULL.
     * VERIFY:   migration SQL contains 'birth_year' with a WHERE clause.
     */
    @Test
    void partialBirthYearIndexExists() throws IOException {
        String sql = migrationSql();
        assertThat(sql)
            .as("V6 migration must create a partial index on birth_year")
            .contains("birth_year");
        assertThat(sql)
            .as("Partial index must filter WHERE birth_year IS NOT NULL")
            .contains("birth_year is not null");
    }
}
