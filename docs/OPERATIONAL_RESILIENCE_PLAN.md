# Operational Resilience Plan — "Pipeline Hardening"

Systematic test-first hardening of the linkage-engine across ingest reliability,
database health, security, observability, and demo lifecycle management.

---

## Strategy name: **Pipeline Hardening**

Each sprint follows the same four-step pattern:

1. **Simulate** — write a test that reproduces the threat (starts red)
2. **Detect** — assert the problem is detected and surfaced
3. **Mitigate** — write production code that makes the test green (auto-fix or admin alert)
4. **Verify** — proof-of-success criteria that confirm the sprint is done

---

## Sprint 1 — Generator Integrity

**Objective:** Guarantee every record produced by `generate-synthetic-data.py`
is internally coherent and globally unique across runs.

**Threats:** Duplicate `recordId` across runs · `birthYear ≥ eventYear`

**Proof of success:**
- `pytest deploy/lambda/test_generator.py` passes with 0 failures
- Two runs with different seeds produce zero overlapping `recordId` values
- No record has `birthYear ≥ eventYear`
- No record implies age < 1 or age > 110

**Tasks:**
- [x] `test_ids_include_batch_date` — assert IDs embed batch date, not bare `SYN-NNNNN`
- [x] `test_ids_unique_across_seeds` — seed=0 and seed=1 produce no ID collision
- [x] `test_birth_year_before_event_year` — all records satisfy `birthYear < eventYear`
- [x] `test_age_in_plausible_range` — 1 ≤ age ≤ 110 for all records with `birthYear`
- [x] Fix generator: embed batch date + seed in `recordId` prefix (`SYN-YYYYMMDD-sN-NNNNN`)
- [x] Fix generator: `rand_birth_year` already satisfies coherence; regression tests confirm

---

## Sprint 2 — Lambda Idempotency and Retry

**Objective:** Lambda handles duplicate S3 events, transient API failures, and
Aurora cold-start timeouts without data loss or silent corruption.

**Threats:** Double S3 invocation · Aurora cold start (503) · DLQ on exhaustion

**Proof of success:**
- `pytest deploy/lambda/test_linkage_engine_store.py` passes with 0 failures
- Invoking Lambda twice with the same event produces identical DB state
- 503 triggers exponential backoff; after N retries the record goes to DLQ
- DLQ message contains bucket, key, line number, and `recordId`

**Tasks:**
- [x] `test_409_treated_as_success` — mock API 409, assert `ok` increments
- [x] `test_double_invocation_idempotent` — call handler twice, assert same result
- [x] `test_503_triggers_retry` — mock 503 then 204, assert retry succeeds
- [x] `test_503_exhausted_sends_to_dlq` — mock always 503, assert DLQ message sent
- [x] `test_dlq_message_contains_context` — assert payload has bucket/key/line/recordId
- [x] Add exponential backoff + DLQ send to `linkage-engine-store.py` (`post_record_with_retry`, `_send_to_dlq`)

---

## Sprint 3 — Validation Pipeline

**Objective:** Enforce a three-prefix pipeline (raw-intake → validated → quarantine)
so that only fully-validated JSON records reach the database. Every output line
carries full provenance so validated and quarantine records can always be paired
back to their origin. Track ingress volume and quarantine spikes in CloudWatch
with admin alerting.

**Pipeline architecture:**

```
External party
      │  s3:PutObject (presigned URL or uploader role)
      ▼
┌─────────────────────────────┐
│  landing/                   │  linkage-engine-landing-<account>
│  (raw intake prefix)        │  unchanged — uploader writes here
└────────────┬────────────────┘
             │  S3 ObjectCreated → Lambda linkage-engine-validate
             ▼
    ┌─────────────────┐       ┌──────────────────────┐
    │  validated/     │       │  quarantine/          │
    │  (same bucket,  │       │  (same bucket,        │
    │   new prefix)   │       │   new prefix)         │
    └────────┬────────┘       └──────────┬────────────┘
             │                           │
             │  S3 ObjectCreated         │  CloudWatch metric filter
             │  → Lambda ingest          │  → alarm on spike
             ▼                           ▼
        /v1/records API            SNS → admin email
```

**Three prefixes in the same bucket** (no new bucket needed — avoids cross-bucket
copy costs and simplifies IAM):

| Prefix | Purpose | Written by |
|---|---|---|
| `landing/` | Raw intake — external party drops files here | Uploader role / presigned URL |
| `validated/` | Passed all validation rules — safe to ingest | Validator Lambda |
| `quarantine/` | Failed validation — preserved for audit/replay | Validator Lambda |

**Validation rules applied in order:**

1. **JSON format check** — file must be valid NDJSON (one JSON object per line); non-JSON files are quarantined immediately
2. **JSON schema validation** — each record must match the `RecordIngestRequest` schema (required fields present, correct types)
3. **Null disqualification** — records with null values in required fields (`recordId`, `givenName`, `familyName`, `eventYear`, `location`) are quarantined
4. **Field format conversion** — normalise `givenName`/`familyName` to title-case; strip leading/trailing whitespace from all string fields; coerce numeric strings to integers where schema expects `int`
5. **Out-of-range rules** — `eventYear` must be 1800–1950; `birthYear` (if present) must satisfy `birthYear < eventYear` and imply age 1–110; `location` must be non-empty after strip

**Output provenance** — every output line (both `validated/` and `quarantine/`) carries
three fields so any record can be traced back to its exact source line, even after a
mid-file Lambda crash and S3 at-least-once replay:

| Field | Type | Example | Purpose |
|---|---|---|---|
| `_sourceKey` | string | `"landing/batch-20260406.ndjson"` | Original S3 key in `landing/` |
| `_sourceLine` | int | `12` | 1-based line number in the source file |
| `_batchId` | UUID | `"a3f7c2d1-…"` | Generated once per invocation; replay gets a new UUID — detects duplicates |

This means:
- **Pairing validated ↔ quarantine:** `_sourceKey` + `_sourceLine` uniquely identifies origin — no dependency on `recordId`
- **Crash between writes:** replay gets a new `_batchId`; downstream systems can detect and deduplicate
- **JSON parse failures:** quarantine entry includes `_reason`, `_raw` (200 chars), and full provenance even when no `recordId` exists

**Example output lines:**

```json
// validated/
{"recordId":"SYN-20260406-s0-00001","givenName":"William","familyName":"Harper",
 "eventYear":1850,"location":"Boston",
 "_sourceKey":"landing/batch-20260406.ndjson","_sourceLine":12,"_batchId":"a3f7c2d1-…"}

// quarantine/ — validation failure
{"_reasons":["missing required field: familyName"],"recordId":"SYN-20260406-s0-00007",
 "_sourceKey":"landing/batch-20260406.ndjson","_sourceLine":7,"_batchId":"a3f7c2d1-…"}

// quarantine/ — JSON parse failure
{"_reason":"invalid JSON","_raw":"William Harper, age 30, farmer…",
 "_sourceKey":"landing/batch-20260406.ndjson","_sourceLine":3,"_batchId":"a3f7c2d1-…"}
```

**Threats:**
- Partial S3 upload (truncated file) reaching the ingest Lambda
- Non-JSON or binary files dropped into the landing prefix
- Records with null required fields silently inserted as incomplete rows
- `eventYear` values in the future or impossibly distant past corrupting linkage scoring
- PII (`rawContent` containing SSN, email, phone) reaching the database or embeddings
- Quarantine spike (bulk bad data from external party) going unnoticed
- Mid-file Lambda crash leaving no audit trail of rejected records
- Replay of the same S3 event producing undetectable duplicate ingestion
- **Provenance fields (`_sourceKey`, `_sourceLine`, `_batchId`, `_reasons`) injected by the validator cause HTTP 400 when a quarantine file is replayed through the ingest Lambda** — `RecordIngestRequest` is a strict Java record; Spring Boot's Jackson deserialiser rejects unknown properties by default, so every line in a replayed quarantine file fails with 400 and is never inserted
- Quarantine files accumulating silently with no record of whether they were ever reviewed or replayed (addressed in Sprint 3c)

**Proof of success:**
- `pytest deploy/lambda/test_linkage_engine_validate.py` passes with 0 failures (13 tests)
- `pytest deploy/lambda/test_linkage_engine_store.py` passes with 0 failures (6 tests, including quarantine-replay test)
- A non-JSON file dropped in `landing/` is copied to `quarantine/` and never reaches `validated/`
- A valid NDJSON file is copied to `validated/` and triggers the ingest Lambda
- A file with 1 bad record in 100 routes 99 lines to `validated/` and 1 line to `quarantine/`
- Every output line carries `_sourceKey`, `_sourceLine`, and `_batchId`
- All output lines from one invocation share the same `_batchId`
- CloudWatch alarm fires when `QuarantinedRecords` > 50 in a 5-minute window → SNS admin notification
- A quarantine file replayed through the ingest Lambda succeeds (provenance fields stripped before POST)

**Tasks:**

*Bucket / infrastructure:*
- [x] Add `validated/` and `quarantine/` prefixes to bucket policy in `provision-lambda.sh`
- [x] Provision `linkage-engine-validate` Lambda triggered by `landing/` ObjectCreated events
- [x] Re-point ingest Lambda trigger from `landing/` to `validated/` prefix

*CloudWatch:*
- [x] Metric filters: `IngressRecords` and `QuarantinedRecords` on Validator Lambda logs
- [x] Alarm: `QuarantinedRecords` sum > 50 in 5 minutes → SNS `linkage-engine-alerts`
- [x] Dashboard widget: ingress volume vs quarantine rate

*Validation Lambda (`deploy/lambda/linkage-engine-validate.py`):*
- [x] Pre-flight: quarantine zero-byte files and files with no valid JSON lines
- [x] Per-line: JSON schema check, null disqualification, format conversion, out-of-range rules
- [x] Per-line: PII redaction from `rawContent` (SSN, email, US phone → `[REDACTED]`)
- [x] Route valid lines → `validated/<key>`, invalid lines → `quarantine/<key>`
- [x] Inject provenance (`_sourceKey`, `_sourceLine`, `_batchId`) into every output line
- [x] Emit structured log line: `ingress=N validated=N quarantined=N` per invocation

*Ingest Lambda (`deploy/lambda/linkage-engine-store.py`):*
- [x] Strip all underscore-prefixed provenance fields (`_sourceKey`, `_sourceLine`, `_batchId`, `_reasons`, `_reason`, `_raw`) from each record before POSTing — keeps the `/v1/records` API strict while making quarantine-file replay safe
- [x] When source key starts with `quarantine/`, read existing `.manifest` (if present), append a replay entry, write updated manifest back to `<quarantine-key>.manifest`

*Tests (`deploy/lambda/test_linkage_engine_validate.py`) — 16 tests:*
- [x] `test_non_json_file_quarantined`
- [x] `test_empty_file_quarantined`
- [x] `test_valid_file_routed_to_validated`
- [x] `test_schema_violation_quarantines_line`
- [x] `test_null_required_field_quarantines_line`
- [x] `test_field_format_conversion_applied`
- [x] `test_out_of_range_event_year_quarantined`
- [x] `test_birth_year_incoherence_quarantined`
- [x] `test_pii_redacted_before_validated`
- [x] `test_cloudwatch_metrics_emitted`
- [x] `test_validated_line_carries_provenance_fields`
- [x] `test_quarantine_line_carries_provenance_fields`
- [x] `test_batch_id_is_consistent_within_invocation`
- [x] `test_manifest_written_alongside_quarantine_file` — `quarantine/<key>.manifest` created when any lines are quarantined
- [x] `test_manifest_contains_required_fields` — manifest has `quarantineKey`, `sourceKey`, `batchId`, `quarantinedAt`, `lineCount`, `reasons`, `replayStatus: "pending"`
- [x] `test_manifest_line_count_matches_quarantine_output` — `lineCount` equals the number of lines written to the quarantine file

*Tests (`deploy/lambda/test_linkage_engine_store.py`) — 8 tests:*
- [x] `test_quarantine_replay_strips_provenance_fields` — POST body must not contain any `_`-prefixed keys when ingesting a quarantine file
- [x] `test_manifest_updated_after_successful_replay` — after full replay, manifest `replayStatus` is `"replayed"` and `replays[0]` contains `ok`, `failed`, `replayedAt`
- [x] `test_manifest_status_partial_when_some_lines_fail` — if any lines fail, `replayStatus` is `"partial"`

---

## Sprint 3c — Quarantine Manifest

**Objective:** Give every quarantine file a companion `.manifest` so operators
can see at a glance what was rejected, why, and whether it has been replayed —
without cross-referencing any other prefix or system.

**Manifest location:**
```
quarantine/batch-20260406.ndjson           ← quarantine data (unchanged)
quarantine/batch-20260406.ndjson.manifest  ← lifecycle record lives here
```

**Two-phase lifecycle:**

*Phase 1 — written by `linkage-engine-validate.py` at quarantine time:*
```json
{
  "quarantineKey": "quarantine/batch-20260406.ndjson",
  "sourceKey":     "landing/batch-20260406.ndjson",
  "batchId":       "a3f7c2d1-…",
  "quarantinedAt": "2026-04-06T14:23:00Z",
  "lineCount":     7,
  "reasons":       ["eventYear out of range", "missing required field: familyName"],
  "replayStatus":  "pending"
}
```

*Phase 2 — updated by `linkage-engine-store.py` when a `quarantine/` file is replayed:*
```json
{
  "quarantineKey": "quarantine/batch-20260406.ndjson",
  "sourceKey":     "landing/batch-20260406.ndjson",
  "batchId":       "a3f7c2d1-…",
  "quarantinedAt": "2026-04-06T14:23:00Z",
  "lineCount":     7,
  "reasons":       ["eventYear out of range", "missing required field: familyName"],
  "replayStatus":  "replayed",
  "replays": [
    {
      "replayedAt":    "2026-04-07T09:11:00Z",
      "replayBatchId": "f9e2a1b3-…",
      "ok":            6,
      "failed":        1,
      "errors": [{"line": 3, "recordId": "SYN-…-00003", "status": 400}]
    }
  ]
}
```

**`replayStatus` values:**

| Value | Meaning |
|---|---|
| `"pending"` | Quarantined, never replayed |
| `"replayed"` | All lines ingested successfully on last replay |
| `"partial"` | Last replay had at least one failed line — needs attention |

**Threats addressed:**
- Quarantine files accumulating silently with no record of whether they were ever reviewed or replayed
- Operator replaying a file but having no way to confirm success without querying the database
- Multiple replay attempts producing ambiguous state — `replays` array preserves full history

**Proof of success:**
- `pytest deploy/lambda/test_linkage_engine_validate.py` passes with 0 failures (16 tests)
- `pytest deploy/lambda/test_linkage_engine_store.py` passes with 0 failures (8 tests)
- After validation, `quarantine/<key>.manifest` exists with `replayStatus: "pending"`
- After successful replay, manifest `replayStatus` is `"replayed"` and `replays[0].ok` matches line count
- After partial replay, manifest `replayStatus` is `"partial"`
- `aws s3 ls s3://<bucket>/quarantine/ --recursive` shows both `.ndjson` and `.manifest` files side by side

**Tasks:**

*Validation Lambda (`deploy/lambda/linkage-engine-validate.py`):*
- [x] After writing quarantine lines, write `<quarantine-key>.manifest` with phase-1 fields
- [x] `reasons` field = deduplicated list of all `_reasons` values seen across quarantined lines

*Ingest Lambda (`deploy/lambda/linkage-engine-store.py`):*
- [x] Detect when source key starts with `quarantine/`
- [x] After processing, read existing `.manifest` (if present), append replay entry, write back
- [x] Set `replayStatus` to `"replayed"` if `failed == 0`, else `"partial"`

*Tests (`deploy/lambda/test_linkage_engine_validate.py`):*
- [x] `test_manifest_written_alongside_quarantine_file`
- [x] `test_manifest_contains_required_fields`
- [x] `test_manifest_line_count_matches_quarantine_output`

*Tests (`deploy/lambda/test_linkage_engine_store.py`):*
- [x] `test_manifest_updated_after_successful_replay`
- [x] `test_manifest_status_partial_when_some_lines_fail`

---

## Sprint 3d — File Chunking and Parallel Ingest

**Objective:** Prevent Lambda TTL exhaustion on large files by ensuring no single
invocation processes more than `CHUNK_SIZE` records. Deliver in three phases so
the simplest fix ships first and complexity is added only when throughput demands it.

**Why this matters:** Lambda has a hard 15-minute TTL. With Aurora cold-start retries
(worst case ~7 s/record), a file of just 130 records can exhaust the budget. A file
of 10,000 records would take ~19 hours sequentially — impossible in a single invocation.

**Full pipeline architecture (all three phases complete):**

```
linkage-engine-raw-<account>        ← external party writes here (PutObject only)
      │  S3 ObjectCreated → linkage-engine-ingestor  (splits into CHUNK_SIZE chunks)
      ▼
linkage-engine-landing-<account>    ← ingestor writes chunks here
      │  S3 ObjectCreated → linkage-engine-validate  (validates, routes)
      ▼
validated/  +  quarantine/          ← same landing bucket, existing prefixes
      │  S3 ObjectCreated → linkage-engine-store     (persists to DB)
      ▼
Aurora PostgreSQL
```

**Bucket responsibilities:**

| Bucket | Written by | IAM access |
|---|---|---|
| `linkage-engine-raw-<account>` | External party | Uploader role: `s3:PutObject` only — no list, no get, no delete |
| `linkage-engine-landing-<account>` | `linkage-engine-ingestor` | Ingestor role: `s3:GetObject` on raw bucket, `s3:PutObject` on landing bucket |

**Why a separate raw bucket (not a prefix):**
- Uploader role scoped to the entire raw bucket — no prefix filter needed, zero risk of touching landing chunks
- Each bucket has one purpose and one bucket policy — no cross-prefix confusion
- S3 event triggers are per-bucket — no prefix filter gymnastics, no trigger loops
- Clean audit trail: raw bucket shows exactly what external parties uploaded, unmodified

**Phased approach:**

| Phase | What changes | Prerequisite |
|---|---|---|
| **3d-i** (now) | Cap `generate-synthetic-data.py` and `upload-to-s3.sh` at `CHUNK_SIZE = 200` lines | None — zero infrastructure change |
| **3d-ii** (before accepting external uploads) | Create `linkage-engine-raw` bucket; build `linkage-engine-ingestor` Lambda; update uploader IAM role | **Must be complete before any external party uploads raw data** |
| **3d-iii** (when needed) | Parent manifest aggregation via DynamoDB atomic counter | Phase 3d-ii complete |

**`CHUNK_SIZE` tuning formula:**

```
CHUNK_SIZE = floor(safe_budget_seconds / p99_latency_per_record)
```

Where `safe_budget_seconds = 600` (half the TTL). Measure `p99_latency_per_record`
from CloudWatch Lambda duration logs under real load. Starting default: **200**.

**Threats addressed:**
- Single Lambda invocation timing out mid-file (TTL = 15 min hard limit)
- Partial ingest leaving manifest `replayStatus: "pending"` with no progress indicator
- External party uploading an arbitrarily large file that cannot be controlled at source
- External party accessing or deleting landing chunks (separate bucket prevents this entirely)

**Proof of success (Phase 3d-i):**
- `generate-synthetic-data.py --count 1000` produces 5 files of 200 lines each, not one file of 1000
- `upload-to-s3.sh` refuses to upload a file exceeding `CHUNK_SIZE` lines and prints a clear error
- `CHUNK_SIZE` is a single named constant in both scripts — not a magic number

**Proof of success (Phase 3d-ii):**
- `linkage-engine-raw-<account>` bucket exists; uploader role has `s3:PutObject` only
- A 1,000-line file dropped in the raw bucket triggers 5 parallel validate invocations, each ≤ 200 lines
- Original file archived to `raw/archive/` after splitting; landing bucket contains only chunks
- Each chunk has its own `quarantine/<chunk-key>.manifest`

**Tasks:**

*Phase 3d-i — upload-time chunking (implement now):*
- [x] Add `CHUNK_SIZE = 200` constant to `generate-synthetic-data.py`; split output into multiple files when `--count > CHUNK_SIZE`
- [x] Add `CHUNK_SIZE` guard to `upload-to-s3.sh`; print error and exit if any single file exceeds limit
- [x] Document `CHUNK_SIZE` tuning formula as a comment in both files
- [x] Tests: `test_large_count_produces_multiple_files`, `test_each_chunk_within_chunk_size`, `test_chunk_ids_unique_across_chunks`

*Phase 3d-ii — ingestor Lambda and raw bucket (implement before external uploads):*
- [ ] Provision `linkage-engine-raw-<account>` bucket: public access blocked, versioning off, uploader role `s3:PutObject` only
- [ ] New Lambda `linkage-engine-ingestor` (`linkage-engine-ingestor.py`) triggered by raw bucket ObjectCreated
- [ ] Ingestor reads file, splits into `CHUNK_SIZE`-line chunks, writes each to landing bucket, archives original to `raw/archive/`
- [ ] Update uploader IAM role from `landing/` prefix on landing bucket → entire raw bucket
- [ ] Update `generate-presigned-url.sh` to target raw bucket
- [ ] Provision in `provision-lambda.sh`

*Phase 3d-iii — parent manifest aggregation (implement when needed):*
- [ ] DynamoDB table `linkage-engine-chunk-counter`: atomic decrement per chunk completion
- [ ] When counter reaches 0, write `raw/archive/<original-key>.manifest` aggregating all chunk manifests

---

## Sprint 4 — Embedding Gap Detection

**Objective:** Detect records saved to `records` with no row in `record_embeddings`
and expose a health endpoint for monitoring and reconciliation.

**Threats:** Bedrock throttle/timeout during ingest leaving embedding gaps

**Proof of success:**
- `GET /v1/ingest/health` returns `{"embeddingGapCount": N, "status": "degraded"}` when gaps exist
- `POST /v1/reindex` closes all gaps
- `GET /v1/ingest/health` returns `{"embeddingGapCount": 0, "status": "ok"}` after reindex

**Tasks:**
- [x] `EmbeddingGapDetectionTest::gapDetectedWhenEmbeddingMissing`
- [x] `EmbeddingGapDetectionTest::healthEndpointReportsDegradedWhenGapsExist`
- [x] `EmbeddingGapDetectionTest::healthEndpointReportsOkAfterReindex`
- [x] `IngestHealthController` — `GET /v1/ingest/health` returns `embeddingGapCount` and `status`
- [x] `IngestHealthService` — counts gaps via `records LEFT JOIN record_embeddings WHERE re.record_id IS NULL`

---

## Sprint 5 — Migration Safety

**Objective:** Prevent Flyway migrations from corrupting in-flight ingest batches;
surface migration status in the health endpoint.

**Threats:** Flyway migration running while Lambda is mid-ingest

**Proof of success:**
- `GET /v1/ingest/health` includes `{"flywayStatus":"up-to-date","pendingMigrations":0}`
- Pending migration causes health to return `degraded`
- Lambda pre-flight check aborts ingest with admin log when health is degraded

**Tasks:**
- [ ] `IngestHealthControllerTest::healthIncludesFlywayStatus`
- [ ] `IngestHealthControllerTest::pendingMigrationCausesDegradedStatus`
- [ ] `test_aborts_when_health_degraded` — mock health returning degraded, assert Lambda exits early
- [ ] Add Flyway status to `IngestHealthController`
- [ ] Add pre-flight health check call to `linkage-engine-store.py`

---

## Sprint 6 — Storage and Archival

**Objective:** Define and enforce data retention policies; archive old records to
S3 to bound active Aurora storage costs.

**Threats:** Unbounded storage growth · embedding table dominates storage (6KB/record)

**Proof of success:**
- `deploy/archive-records.sh` moves records older than N years to S3 Parquet
- CloudWatch alarm fires when Aurora storage exceeds threshold
- Archived records are queryable via Athena (schema documented)
- `record_embeddings` rows for archived records are pruned

**Tasks:**
- [ ] Define retention policy: archive records with `created_at` older than 90 days (configurable)
- [ ] `deploy/archive-records.sh` — exports to S3 via `aws rds start-export-task` or COPY TO
- [ ] CloudWatch alarm: Aurora `FreeLocalStorage` < 20% of allocated
- [ ] `test_archive_script_dry_run` — assert correct records selected, no DB mutation in dry-run
- [ ] Document Athena table DDL for archived Parquet in `docs/DATA_PIPELINE_S3.md`

---

## Sprint 7 — Database Performance

**Objective:** Optimize query performance for the most common access patterns;
replace exact vector scan with HNSW approximate nearest-neighbour index.

**Threats:** O(n) vector scan · missing composite indices · unused indices wasting write throughput

**Proof of success:**
- `EXPLAIN ANALYZE` on the three most common queries shows index scans, not seq scans
- Vector similarity search uses HNSW index (confirmed via `EXPLAIN`)
- `pg_stat_user_indexes` shows no zero-scan indices after 24h of traffic

**Tasks:**
- [ ] Add composite index `(lower(family_name), event_year)` — primary linkage query pattern
- [ ] Add partial index on `birth_year IS NOT NULL` — AgeConsistencyRule filter
- [ ] Add HNSW index on `record_embeddings.embedding` via Flyway migration
- [ ] `V6__performance_indices.sql` Flyway migration
- [ ] `IndexPerformanceTest::vectorSearchUsesHnswIndex` — assert EXPLAIN output contains `hnsw`
- [ ] Document index strategy in `docs/ARCHITECTURE.md`

---

## Sprint 8 — Operational Reliability

**Objective:** Validate backup/recovery, tune JVM memory, add cost and memory
alarms, and enforce secrets rotation.

**Threats:** Untested PITR · JVM heap spike past 1.5GB · unbounded AWS cost · stale DB password

**Proof of success:**
- PITR restore test completes successfully to a point-in-time within the last 24h
- ECS task runs stably under load with `-Xmx1400m` set
- CloudWatch alarm fires when ECS memory utilization > 80%
- AWS Budget alarm fires when monthly spend exceeds threshold
- Secrets Manager rotation policy set to 30 days

**Tasks:**
- [ ] Increase Aurora backup retention to 7 days in `deploy/provision-aws.sh`
- [ ] Document PITR restore procedure in `docs/AURORA_POSTGRESQL.md`
- [ ] Add `-Xmx1400m -Xms512m` to `ENTRYPOINT` in `Dockerfile`
- [ ] CloudWatch alarm: ECS `MemoryUtilization` > 80% → SNS notification
- [ ] AWS Budget: monthly spend alarm at $50 threshold
- [ ] Secrets Manager rotation: 30-day automatic rotation via `deploy/provision-aws.sh`
- [ ] `MemoryTuningTest::appStartsWithinMemoryBudget` — assert heap usage < 1400m after startup

---

## Sprint 9a — Intake Access Control

**Objective:** Give the external data-dumping party the minimum AWS permissions
needed to upload files — and nothing else. Prevent any principal from deleting
objects from the landing bucket.

**Threats:** External party uses broad credentials and accidentally (or
maliciously) deletes or overwrites ingested files · Credentials leaked from
external party give attacker read/list access to the bucket

**Proof of success:**
- External party can `s3:PutObject` on `landing/*` — and only that
- `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:DeleteBucket` are denied
  for **all** principals at the bucket-policy level (not just the uploader role)
- Lambda ingest role is unaffected — it can still `GetObject` / `ListBucket`
- A presigned URL generated by `deploy/generate-presigned-url.sh` works for
  non-AWS external parties with zero AWS credentials on their side

**Access control model:**

| Principal | Mechanism | Permissions |
|---|---|---|
| External AWS party | Assume `linkage-engine-uploader-role` | `s3:PutObject` on `landing/*` only |
| External non-AWS party | Presigned PUT URL (1-hour TTL) | Single object PUT, scoped by URL |
| Lambda store | `linkage-engine-store-role` | `s3:GetObject`, `s3:HeadObject`, `s3:ListBucket` on `validated/*` |
| Everyone | Bucket policy `Deny` | `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:DeleteBucket` — always denied |

**Tasks:**
- [x] `linkage-engine-uploader-role` — IAM role with `s3:PutObject` on `landing/*` only; trust policy scoped to this account (step 6 of `provision-lambda.sh`)
- [x] Bucket policy — `Deny` `DeleteObject` / `DeleteObjectVersion` / `DeleteBucket` for all principals; explicit `Allow` for Lambda ingest role and uploader role (step 7 of `provision-lambda.sh`)
- [x] `deploy/generate-presigned-url.sh` — assumes uploader role, generates presigned PUT URL with configurable TTL (default 1 hour); prints `curl` upload command to stderr, URL to stdout

**To grant access to an external AWS account:**

Edit the trust policy of `linkage-engine-uploader-role` to add their account:
```json
"Principal": { "AWS": [
  "arn:aws:iam::<YOUR_ACCOUNT>:root",
  "arn:aws:iam::<EXTERNAL_ACCOUNT>:root"
]}
```

**To generate a one-time upload URL for a non-AWS party:**
```bash
./deploy/generate-presigned-url.sh data/batch-2026-04-06.ndjson
# Optionally extend TTL:
./deploy/generate-presigned-url.sh data/batch.ndjson --ttl 7200
```

---

## Sprint 9 — Security Hardening

**Objective:** Add TLS to the ALB, require API authentication for write endpoints,
and rate-limit the ingest API.

**Threats:** HTTP-only ALB (credentials in transit) · unauthenticated write access · Lambda flood

**Proof of success:**
- ALB serves HTTPS on port 443 with valid ACM certificate
- `POST /v1/records` without a valid API key returns 401
- More than 100 requests/second from a single source returns 429
- `GET /chord-diagram.html` remains publicly accessible (no auth required)

**Tasks:**
- [ ] Provision ACM certificate + HTTPS listener in `deploy/provision-aws.sh`
- [ ] Add API key header validation to `RecordIngestController` (Spring Security or simple filter)
- [ ] Store API key in Secrets Manager; inject via ECS task definition
- [ ] ALB rate limiting rule (WAF or ALB request count condition)
- [ ] `RecordIngestControllerTest::ingestReturns401WithoutApiKey`
- [ ] `RecordIngestControllerTest::ingestReturns204WithValidApiKey`

---

## Sprint 10 — Observability and Disruption Alerting

**Objective:** Ensure every identified disruption type (TTL exhaustion, cold start,
mid-file crash, duplicate invocation, Aurora 5xx, Bedrock throttle) fires a
CloudWatch alarm before an operator discovers it manually. Add structured metrics
for request latency and ingest throughput. Build a unified dashboard.

**Disruption coverage matrix — current state vs. target:**

| Disruption | Detected today? | Alerted today? | Auto-recovered? | Sprint 10 adds |
|---|---|---|---|---|
| Lambda TTL exhaustion | Partially (manifest stays pending) | No | No | Alarm on `Duration` > 600s |
| Lambda cold start | Yes (retry logs) | No | Yes (retry loop) | Alarm on `InitDuration` > 10s |
| Mid-file crash (OOM / force-kill) | Yes (`_batchId` gap) | No | Partial (S3 re-triggers) | Alarm on `Errors` > 0 |
| Duplicate S3 invocation | Yes (`_batchId` differs) | No | Yes (409 idempotency) | Dashboard widget (informational) |
| Aurora 5xx / cold-start | Yes (DLQ, manifest partial) | No | Yes (retry loop) | Alarm on DLQ depth > 0 |
| Bedrock throttle / gap | Yes (health endpoint) | No | Manual reindex | Alarm on `embeddingGapCount` > 0 |
| Quarantine spike | Yes (metric filter) | Yes (existing alarm) | No | Already done (Sprint 3) |
| Resolve p99 latency | No | No | N/A | Alarm on p99 > 5000ms |

---

**CloudWatch alarm definitions:**

| Alarm name | Metric | Threshold | Period | Action |
|---|---|---|---|---|
| `le-lambda-validate-ttl-warning` | `linkage-engine-validate` `Duration` | > 600,000 ms | 1 invocation | SNS `linkage-engine-alerts` |
| `le-lambda-store-ttl-warning` | `linkage-engine-store` `Duration` | > 600,000 ms | 1 invocation | SNS `linkage-engine-alerts` |
| `le-lambda-validate-errors` | `linkage-engine-validate` `Errors` | > 0 | 5 min | SNS `linkage-engine-alerts` |
| `le-lambda-store-errors` | `linkage-engine-store` `Errors` | > 0 | 5 min | SNS `linkage-engine-alerts` |
| `le-store-dlq-depth` | `linkage-engine-store-dlq` `ApproximateNumberOfMessagesVisible` | > 0 | 5 min | SNS `linkage-engine-alerts` |
| `le-embedding-gaps` | Custom metric `EmbeddingGapCount` (from health endpoint) | > 0 | 15 min | SNS `linkage-engine-alerts` |
| `le-resolve-p99-latency` | `linkage-engine` `resolve.p99` (Micrometer → CloudWatch) | > 5000 ms | 5 min | SNS `linkage-engine-alerts` |
| `le-quarantine-spike` | `QuarantinedRecords` (metric filter on validate logs) | > 50 | 5 min | SNS `linkage-engine-alerts` (already exists — Sprint 3) |

---

**Proof of success:**
- All 7 new alarms exist in CloudWatch and are in `OK` state under normal load
- Each alarm has been manually triggered in a test run and confirmed to fire to SNS
- CloudWatch dashboard `linkage-engine-ops` shows all alarm states, DLQ depth, Lambda duration p99, ingest throughput, resolve latency, and ECS CPU/memory on one screen
- `GET /v1/ingest/health` includes `{"lastBatchSize": N, "lastBatchAt": "ISO8601", "ingestRatePerMin": N, "embeddingGapCount": N}`
- `EmbeddingGapCount` custom metric is published to CloudWatch every 15 minutes by a scheduled Lambda or ECS task

**Tasks:**

*Lambda duration alarms (TTL warning at 2/3 of limit):*
- [ ] CloudWatch alarm `le-lambda-validate-ttl-warning`: `Duration` > 600,000 ms on `linkage-engine-validate`
- [ ] CloudWatch alarm `le-lambda-store-ttl-warning`: `Duration` > 600,000 ms on `linkage-engine-store`

*Lambda error alarms (mid-file crash, unhandled exception):*
- [ ] CloudWatch alarm `le-lambda-validate-errors`: `Errors` > 0 on `linkage-engine-validate`
- [ ] CloudWatch alarm `le-lambda-store-errors`: `Errors` > 0 on `linkage-engine-store`

*DLQ depth alarm (Aurora 5xx exhaustion):*
- [ ] CloudWatch alarm `le-store-dlq-depth`: SQS `ApproximateNumberOfMessagesVisible` > 0 on `linkage-engine-store-dlq`

*Embedding gap alarm (Bedrock throttle):*
- [ ] Scheduled publisher: every 15 min, call `GET /v1/ingest/health` and publish `EmbeddingGapCount` as a custom CloudWatch metric
- [ ] CloudWatch alarm `le-embedding-gaps`: `EmbeddingGapCount` > 0 for two consecutive periods

*Application latency metrics:*
- [ ] Add `@Timed` (Micrometer) to `RecordIngestService.ingest` and `LinkageService.resolve`
- [ ] Expose `/actuator/metrics` and `/actuator/prometheus`
- [ ] CloudWatch alarm `le-resolve-p99-latency`: resolve p99 > 5000 ms → SNS

*Dashboard (`linkage-engine-ops`):*
- [ ] Row 1 — Alarm state panel: all 8 alarms as green/red indicators
- [ ] Row 2 — Lambda: duration p99, error rate, DLQ depth (validate + store side by side)
- [ ] Row 3 — Ingest pipeline: ingress rate, validated rate, quarantine rate, embedding gap count
- [ ] Row 4 — Application: resolve p50/p99, ECS CPU/memory, Aurora ACU utilization

*Health endpoint enhancements:*
- [ ] Add `lastBatchSize`, `lastBatchAt`, `ingestRatePerMin` to `GET /v1/ingest/health` response

*Provision:*
- [ ] Add all alarms and dashboard to `provision-lambda.sh` (idempotent)

---

## Sprint 11 — Demo Lifecycle

**Objective:** Provide one-command shutdown (cost → $0) and one-command
commission (ready for live demo) with documented warm-up time.

**This is the most operationally critical sprint for a demo application.**

**Proof of success:**
- `./deploy/demo-stop.sh` brings AWS cost to $0 within 5 minutes
- `./deploy/demo-start.sh` has the app serving requests within 10 minutes
- Both scripts are idempotent and print elapsed time
- A pre-demo checklist verifies the app is healthy before going live

**Shutdown — what gets stopped vs destroyed:**

| Resource | Action | Cost impact |
|---|---|---|
| ECS service | Scale to 0 tasks | Fargate billing stops immediately |
| Aurora cluster | Pause (MinCapacity=0) | Billing stops after ~5 min idle |
| ALB | **Keep running** | ~$0.008/hr — negligible, avoids DNS TTL wait |
| ECR images | Keep | Storage cost ~$0.10/GB/mo |
| Secrets Manager | Keep | $0.40/secret/mo |
| Lambda | Keep (no idle cost) | Free tier covers demo usage |
| S3 | Keep | Storage cost only |
| CloudWatch logs | Keep | Storage cost only |

**Commission — startup sequence:**

1. Scale ECS service desired count → 1
2. Aurora resumes on first connection (~15s cold start)
3. Spring Boot starts (~15s)
4. Flyway validates migrations
5. ALB health check passes → traffic flows
6. Seed data verified via `demo/seed-data.sh` if DB was reset

**Tasks:**
- [x] `deploy/demo-stop.sh` — scale ECS to 0, pause Aurora, print cost summary
- [x] `deploy/demo-start.sh` — scale ECS to 1, wait for health, run pre-demo checklist
- [x] `deploy/demo-checklist.sh` — verify ALB health, seed data present, Bedrock reachable
- [ ] `test_demo_stop_is_idempotent` — run stop twice, assert no errors
- [ ] `test_demo_start_reaches_healthy` — mock ECS/ALB, assert checklist passes
- [ ] Add estimated warm-up time to `docs/DEPLOYMENT_ECS_FARGATE.md`
- [ ] Add `demo-stop` / `demo-start` to `deploy/` README

---

## Definition of Done (all sprints)

- All new tests pass in `./mvnw verify` and `pytest`
- No regression in existing test suite (coverage ≥ 80%)
- Each threat has: a test that reproduces it, a test that detects it, and either
  automatic mitigation or a logged admin action with enough context to act on
- Task checkboxes in this document updated as work completes

---

## Sprint order recommendation

For a demo app, prioritize in this order:

1. **Sprint 11** (Demo Lifecycle) — enables safe cost management immediately
2. **Sprint 1** (Generator Integrity) — needed before any bulk data load
3. **Sprint 2** (Lambda Resilience) — needed before production ingest
4. **Sprint 9a** (Intake Access Control) — lock down the bucket before sharing upload access
5. **Sprint 3** (Validation Pipeline) — three-bucket model, schema/null/range/PII validation, CloudWatch quarantine alarm
6. **Sprint 8** (Reliability) — backup + memory before showing to anyone
7. Sprints 4–7, 9–10 in order
