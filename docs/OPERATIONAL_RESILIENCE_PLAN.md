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
- `pytest deploy/lambda/test_ingest_from_s3.py` passes with 0 failures
- Invoking Lambda twice with the same event produces identical DB state
- 503 triggers exponential backoff; after N retries the record goes to DLQ
- DLQ message contains bucket, key, line number, and `recordId`

**Tasks:**
- [x] `test_409_treated_as_success` — mock API 409, assert `ok` increments
- [x] `test_double_invocation_idempotent` — call handler twice, assert same result
- [x] `test_503_triggers_retry` — mock 503 then 204, assert retry succeeds
- [x] `test_503_exhausted_sends_to_dlq` — mock always 503, assert DLQ message sent
- [x] `test_dlq_message_contains_context` — assert payload has bucket/key/line/recordId
- [x] Add exponential backoff + DLQ send to `ingest-from-s3.py` (`post_record_with_retry`, `_send_to_dlq`)

---

## Sprint 3 — Validation Pipeline

**Objective:** Enforce a three-bucket pipeline (raw-intake → validated → quarantine)
so that only fully-validated JSON records reach the database. Track ingress volume
and quarantine spikes in CloudWatch with admin alerting.

**Pipeline architecture:**

```
External party
      │  s3:PutObject (presigned URL or uploader role)
      ▼
┌─────────────────────────────┐
│  raw-intake/                │  linkage-engine-landing-<account>
│  (existing landing bucket)  │  unchanged — uploader writes here
└────────────┬────────────────┘
             │  S3 ObjectCreated → Lambda validate-and-route
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

**Threats:**
- Partial S3 upload (truncated file) reaching the ingest Lambda
- Non-JSON or binary files dropped into the landing prefix
- Records with null required fields silently inserted as incomplete rows
- `eventYear` values in the future or impossibly distant past corrupting linkage scoring
- PII (`rawContent` containing SSN, email, phone) reaching the database or embeddings
- Quarantine spike (bulk bad data from external party) going unnoticed

**Proof of success:**
- `pytest deploy/lambda/test_validate_and_route.py` passes with 0 failures
- A non-JSON file dropped in `landing/` is copied to `quarantine/` and never reaches `validated/`
- A valid NDJSON file is copied to `validated/` and triggers the ingest Lambda
- A file with 1 bad record in 100 routes 99 lines to `validated/` and 1 line to `quarantine/` (line-level routing)
- CloudWatch metric `QuarantinedRecords` increments for every quarantined line
- CloudWatch alarm fires when `QuarantinedRecords` > 50 in a 5-minute window → SNS admin notification
- PII patterns (SSN, email, phone) in `rawContent` are redacted before the record is written to `validated/`
- `IngressRecords` CloudWatch metric tracks total lines seen per invocation

**Tasks:**

*Bucket / infrastructure:*
- [x] Add `validated/` and `quarantine/` prefixes to bucket policy in `provision-lambda.sh` — Validator Lambda needs `s3:PutObject` on both; ingest Lambda needs `s3:GetObject` on `validated/` only
- [x] Provision second Lambda `linkage-engine-validate` triggered by `landing/` ObjectCreated events (replaces direct `landing/` → ingest trigger)
- [x] Re-point ingest Lambda trigger from `landing/` to `validated/` prefix

*CloudWatch:*
- [x] CloudWatch metric filter on Validator Lambda logs: `IngressRecords` (total lines seen) and `QuarantinedRecords` (lines failed validation)
- [x] CloudWatch alarm: `QuarantinedRecords` sum > 50 in 5 minutes → SNS topic `linkage-engine-alerts` → admin email
- [x] CloudWatch dashboard widget: ingress volume vs quarantine rate (ratio)

*Validation Lambda (`deploy/lambda/validate-and-route.py`):*
- [x] Pre-flight: reject zero-byte files immediately → quarantine whole file
- [x] Pre-flight: reject files where 0 lines are valid JSON → quarantine whole file with reason
- [x] Per-line validation: JSON schema check against `RecordIngestRequest` schema
- [x] Per-line validation: null disqualification for required fields
- [x] Per-line validation: field format conversion (title-case names, strip whitespace, coerce numeric strings)
- [x] Per-line validation: out-of-range rules (`eventYear` 1800–1950, `birthYear` coherence, non-empty `location`)
- [x] Per-line: PII redaction from `rawContent` (SSN `\d{3}-\d{2}-\d{4}`, email, US phone)
- [x] Route valid lines → `validated/<original-key>`, invalid lines → `quarantine/<original-key>`
- [x] Emit structured log lines: `ingress=N validated=N quarantined=N` per invocation

*Tests (`deploy/lambda/test_validate_and_route.py`):*
- [x] `test_non_json_file_quarantined` — binary/text file → quarantine, never reaches validated
- [x] `test_empty_file_quarantined` — zero-byte file → quarantine with reason logged
- [x] `test_valid_file_routed_to_validated` — clean NDJSON → all lines in validated
- [x] `test_schema_violation_quarantines_line` — missing `familyName` → that line quarantined, rest validated
- [x] `test_null_required_field_quarantines_line` — `recordId: null` → quarantined
- [x] `test_field_format_conversion_applied` — `"william"` → `"William"`, `" Boston "` → `"Boston"`
- [x] `test_out_of_range_event_year_quarantined` — `eventYear: 2099` → quarantined
- [x] `test_birth_year_incoherence_quarantined` — `birthYear >= eventYear` → quarantined
- [x] `test_pii_redacted_before_validated` — SSN/email in `rawContent` → redacted in validated copy
- [x] `test_cloudwatch_metrics_emitted` — assert log lines contain `ingress=` and `quarantined=`

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
- [ ] `EmbeddingGapDetectionTest::gapDetectedWhenEmbeddingMissing`
- [ ] `EmbeddingGapDetectionTest::healthEndpointReportsDegradedWhenGapsExist`
- [ ] `EmbeddingGapDetectionTest::healthEndpointReportsOkAfterReindex`
- [ ] `IngestHealthController` — `GET /v1/ingest/health` queries `records LEFT JOIN record_embeddings`
- [ ] `IngestHealthService` — counts gaps, calls reindex if `?autoRepair=true`

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
- [ ] Add pre-flight health check call to `ingest-from-s3.py`

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
| Lambda ingest | `linkage-engine-ingest-role` | `s3:GetObject`, `s3:HeadObject`, `s3:ListBucket` on `landing/*` |
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

## Sprint 10 — Observability

**Objective:** Add structured metrics for request latency, ingest throughput,
and resolve pipeline stages; build a CloudWatch dashboard.

**Threats:** Blind spots in production — no p99 latency, no ingest rate, no per-stage timing

**Proof of success:**
- CloudWatch dashboard shows: ingest rate (records/min), resolve p50/p99, ECS CPU/memory
- `GET /v1/ingest/health` includes `{"lastBatchSize": N, "lastBatchAt": "ISO8601", "ingestRatePerMin": N}`
- Alarm fires when resolve p99 > 5s

**Tasks:**
- [ ] Add `@Timed` (Micrometer) to `RecordIngestService.ingest` and `LinkageService.resolve`
- [ ] Expose `/actuator/metrics` and `/actuator/prometheus`
- [ ] CloudWatch metric filter on Lambda logs for `ok=` and `failed=` counts
- [ ] CloudWatch dashboard: ingest throughput, resolve latency, ECS utilization, DLQ depth
- [ ] Alarm: resolve p99 > 5000ms → SNS

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
