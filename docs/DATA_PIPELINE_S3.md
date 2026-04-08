# Data Pipeline — S3 Storage and Archival

This document describes the S3 bucket layout for the linkage-engine ingest
pipeline, the archival strategy for aged-out records, and how to query
archived data with Amazon Athena.

---

## 1. S3 Bucket Layout

### `linkage-engine-raw-<account>` — External upload target

| Prefix | Purpose |
|---|---|
| `<filename>.ndjson` | Raw NDJSON uploaded by external parties (PutObject only) |
| `archive/<filename>.ndjson` | Original file after `linkage-engine-ingestor` has chunked it |

- External parties have `s3:PutObject` only (IAM role or presigned URL).
- `linkage-engine-ingestor` Lambda reads from root, writes chunks to the
  landing bucket, then moves the original to `archive/`.

### `linkage-engine-landing-<account>` — Internal pipeline bucket

| Prefix | Purpose |
|---|---|
| `landing/<file>-chunk-NNN.ndjson` | Chunked raw files awaiting validation |
| `validated/<file>-chunk-NNN.ndjson` | Records that passed all validation rules |
| `quarantine/<file>-chunk-NNN.ndjson` | Records that failed one or more rules |
| `quarantine/<file>-chunk-NNN.manifest` | Lifecycle manifest for each quarantined file |

### `linkage-engine-archive-<account>` — Long-term cold storage

| Prefix | Purpose |
|---|---|
| `records/<YYYY-MM-DD>/records.ndjson` | Archived `records` rows (JSON lines) |
| `records/<YYYY-MM-DD>/embeddings.ndjson` | Archived `record_embeddings` rows (JSON lines) |
| `records/<YYYY-MM-DD>/manifest.json` | Archive run metadata |

---

## 2. Archival Policy

Records are archived when their `created_at` timestamp is older than
`RETENTION_DAYS` (default: 90 days). Run the archive script manually or
schedule it via EventBridge:

```bash
# Dry run — shows count and sample IDs, no DB changes
./deploy/archive-records.sh --dry-run

# Live run — exports to S3, prunes Aurora rows
./deploy/archive-records.sh

# Custom retention window
RETENTION_DAYS=30 ./deploy/archive-records.sh --dry-run
```

The script:
1. Counts eligible records (older than `RETENTION_DAYS`)
2. Exports `records` + `record_embeddings` to S3 as NDJSON
3. Writes a `manifest.json` with archive metadata
4. Deletes `record_embeddings` rows (FK constraint first)
5. Deletes `records` rows

---

## 3. Athena DDL — Querying Archived Records

Create an Athena database and tables to query archived NDJSON with standard SQL.

### 3a. Create Athena database

```sql
CREATE DATABASE IF NOT EXISTS linkage_archive
  LOCATION 's3://linkage-engine-archive-<account>/';
```

### 3b. Records table

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS linkage_archive.records (
  record_id       STRING,
  given_name      STRING,
  family_name     STRING,
  event_type      STRING,
  event_year      INT,
  event_location  STRING,
  birth_year      INT,
  gender          STRING,
  notes           STRING,
  created_at      STRING,
  updated_at      STRING
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES (
  'serialization.format' = '1',
  'ignore.malformed.json' = 'true'
)
LOCATION 's3://linkage-engine-archive-<account>/records/'
TBLPROPERTIES (
  'has_encrypted_data' = 'false',
  'projection.enabled' = 'true',
  'projection.archive_date.type' = 'date',
  'projection.archive_date.range' = '2024-01-01,NOW',
  'projection.archive_date.format' = 'yyyy-MM-dd',
  'projection.archive_date.interval' = '1',
  'projection.archive_date.interval.unit' = 'DAYS',
  'storage.location.template' =
    's3://linkage-engine-archive-<account>/records/${archive_date}/'
);
```

### 3c. Embeddings table

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS linkage_archive.embeddings (
  record_id   STRING,
  embedding   STRING,
  model_id    STRING,
  created_at  STRING
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES (
  'serialization.format' = '1',
  'ignore.malformed.json' = 'true'
)
LOCATION 's3://linkage-engine-archive-<account>/records/'
TBLPROPERTIES (
  'has_encrypted_data' = 'false',
  'projection.enabled' = 'true',
  'projection.archive_date.type' = 'date',
  'projection.archive_date.range' = '2024-01-01,NOW',
  'projection.archive_date.format' = 'yyyy-MM-dd',
  'projection.archive_date.interval' = '1',
  'projection.archive_date.interval.unit' = 'DAYS',
  'storage.location.template' =
    's3://linkage-engine-archive-<account>/records/${archive_date}/'
);
```

### 3d. Example queries

```sql
-- Find all archived records for a family name
SELECT record_id, given_name, family_name, event_year, event_location
FROM linkage_archive.records
WHERE lower(family_name) = 'smith'
  AND archive_date BETWEEN '2026-01-01' AND '2026-12-31'
ORDER BY event_year;

-- Count archived records by event type
SELECT event_type, count(*) AS total
FROM linkage_archive.records
GROUP BY event_type
ORDER BY total DESC;

-- Find archived records with embeddings
SELECT r.record_id, r.given_name, r.family_name
FROM linkage_archive.records r
JOIN linkage_archive.embeddings e ON r.record_id = e.record_id
WHERE r.archive_date = '2026-04-08';
```

---

## 4. Storage Cost Estimates

| Tier | Approx. size per 1,000 records | Monthly cost (S3 Standard) |
|---|---|---|
| `records.ndjson` | ~500 KB | ~$0.01 |
| `embeddings.ndjson` | ~6 MB (1536-dim float32) | ~$0.14 |
| Total per 1,000 records/month | ~6.5 MB | ~$0.15 |

At 90-day retention, a dataset of 100,000 records generates ~650 MB of archive
data per archival run — approximately $0.015/month in S3 Standard storage.

Use S3 Intelligent-Tiering or Glacier Instant Retrieval for older archives to
reduce storage costs further.

---

## 5. Monitoring

The `le-aurora-storage-low` CloudWatch alarm (provisioned by `provision-aws.sh`)
fires when Aurora `FreeLocalStorage` drops below 20 GiB, giving advance warning
before an archival run is needed.

Check current storage:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeLocalStorage \
  --dimensions Name=DBClusterIdentifier,Value=linkage-engine-aurora \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Average \
  --region us-west-1
```
