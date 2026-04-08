package com.spexture.linkage_engine;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Queries the database for records that have no corresponding embedding row.
 * An embedding gap means Bedrock timed out or was throttled during ingest,
 * leaving the record unsearchable by vector similarity.
 */
@Service
public class IngestHealthService {

    private final JdbcTemplate jdbcTemplate;

    public IngestHealthService(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Returns the number of records in {@code records} that have no row in
     * {@code record_embeddings} (LEFT JOIN … WHERE re.record_id IS NULL).
     */
    public int countEmbeddingGaps() {
        Integer count = jdbcTemplate.queryForObject(
            """
            select count(*)
            from records r
            left join record_embeddings re on re.record_id = r.record_id
            where re.record_id is null
            """,
            Integer.class
        );
        return count != null ? count : 0;
    }
}
