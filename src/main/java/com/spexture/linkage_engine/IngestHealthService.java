package com.spexture.linkage_engine;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationState;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Queries the database for records that have no corresponding embedding row,
 * and checks Flyway for pending schema migrations.
 *
 * An embedding gap means Bedrock timed out or was throttled during ingest,
 * leaving the record unsearchable by vector similarity.
 *
 * A pending migration means a new SQL script has been added but not yet
 * applied — the store Lambda should abort ingest until the schema is current.
 */
@Service
public class IngestHealthService {

    private final JdbcTemplate jdbcTemplate;
    private final Flyway flyway;

    public IngestHealthService(JdbcTemplate jdbcTemplate, Flyway flyway) {
        this.jdbcTemplate = jdbcTemplate;
        this.flyway = flyway;
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

    /**
     * Returns the number of Flyway migrations that are in PENDING state
     * (scripts present on the classpath but not yet applied to the DB).
     */
    public int countPendingMigrations() {
        int pending = 0;
        for (MigrationInfo info : flyway.info().all()) {
            if (info.getState() == MigrationState.PENDING) {
                pending++;
            }
        }
        return pending;
    }
}
