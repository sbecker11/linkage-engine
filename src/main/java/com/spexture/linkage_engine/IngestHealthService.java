package com.spexture.linkage_engine;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationState;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Queries the database for records that have no corresponding embedding row,
 * checks Flyway for pending schema migrations, and tracks ingest throughput
 * statistics for the health endpoint.
 *
 * An embedding gap means Bedrock timed out or was throttled during ingest,
 * leaving the record unsearchable by vector similarity.
 *
 * A pending migration means a new SQL script has been added but not yet
 * applied — the store Lambda should abort ingest until the schema is current.
 *
 * Throughput stats (lastBatchSize, lastBatchAt, ingestRatePerMin) are updated
 * by RecordIngestController on each successful POST /v1/records batch.
 */
@Service
public class IngestHealthService {

    private static final DateTimeFormatter ISO_UTC =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    private final JdbcTemplate jdbcTemplate;
    private final Flyway flyway;

    // Throughput tracking — updated atomically by RecordIngestController
    private final AtomicInteger lastBatchSize   = new AtomicInteger(0);
    private final AtomicReference<String> lastBatchAt = new AtomicReference<>(null);
    // Rolling 1-minute ingest rate: records ingested in the last 60s window
    private final AtomicLong windowStartMs      = new AtomicLong(System.currentTimeMillis());
    private final AtomicInteger windowCount     = new AtomicInteger(0);
    private volatile double ingestRatePerMin    = 0.0;

    public IngestHealthService(JdbcTemplate jdbcTemplate, Flyway flyway) {
        this.jdbcTemplate = jdbcTemplate;
        this.flyway = flyway;
    }

    /**
     * Called by RecordIngestController after each successful ingest.
     * Updates lastBatchSize, lastBatchAt, and the rolling ingest rate.
     */
    public void recordIngest(int batchSize) {
        lastBatchSize.set(batchSize);
        lastBatchAt.set(ISO_UTC.format(Instant.now()));

        long now = System.currentTimeMillis();
        long elapsed = now - windowStartMs.get();
        if (elapsed >= 60_000) {
            // Roll the window: compute rate from the completed window
            ingestRatePerMin = windowCount.get() * 60_000.0 / elapsed;
            windowStartMs.set(now);
            windowCount.set(batchSize);
        } else {
            windowCount.addAndGet(batchSize);
        }
    }

    public int getLastBatchSize()       { return lastBatchSize.get(); }
    public String getLastBatchAt()      { return lastBatchAt.get(); }
    public double getIngestRatePerMin() { return ingestRatePerMin; }

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
