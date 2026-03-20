# Standard data pipeline: S3 landing zone → PostgreSQL

This document is the **project standard** for where **raw, searchable-ingest source data** lives and how it reaches the linkage engine in **both local development and AWS**.

## Principles

1. **S3 is the system of record for raw artifacts** (exports, OCR output, JSON/NDJSON lines, CSV dumps, bundles). It is cheap, durable, and shared across environments when you use one bucket (or mirrored buckets) with appropriate IAM.
2. **S3 is not the query engine.** Full-text and linkage **search** run against **PostgreSQL** (`records`, optional `record_embeddings` / pgvector). Raw files in S3 are **ingested** into those tables (and embeddings generated when Titan is enabled).
3. **Same mental model everywhere:** *land → validate/transform → upsert DB → optional vectors.* Local and AWS differ only in **credentials, network path, and who runs the ingest job** (laptop script, ECS task, Lambda, etc.).

## Recommended bucket layout

Use a single bucket (or `dev` / `prod` prefixes) with predictable prefixes:

| Prefix | Purpose |
| :--- | :--- |
| `landing/` | Immutable drops from upstream (append-only; never overwritten in place) |
| `staging/` | Parsed/normalized rows ready for DB load (optional) |
| `archive/` | After successful ingest, optionally move or copy objects here for audit |
| `errors/` | Quarantine for bad files + sidecar error metadata |

**Object naming:** include a stable id or batch id, e.g. `landing/batch=2025-03-20/source=crm/part-00001.ndjson`.

## Ingest paths (standard)

| Path | When to use |
| :--- | :--- |
| **API** | `POST /v1/records` for low-volume or operational upserts (already implemented). |
| **Batch from S3** | A job (script, ECS scheduled task, or Lambda) lists `landing/` or `staging/`, reads objects, maps rows to `records`, calls the same persistence logic or JDBC bulk load, then writes embeddings if configured. *Implement as a follow-on when batch volume requires it.* |

Until a dedicated batch worker ships in-repo, the standard is still: **store raw in S3** + **ingest via your chosen runner** that ends in the same `records` / `record_embeddings` schema Flyway defines.

## Local vs AWS access to the same bucket

### Option A — Shared AWS S3 (recommended for teams)

- **Local:** AWS CLI or SDK uses `~/.aws/credentials`, SSO, or environment variables (`AWS_ACCESS_KEY_ID`, etc.) with `s3:GetObject` / `s3:ListBucket` on the landing prefix.
- **AWS (ECS/Fargate):** Task role grants the same S3 permissions; no long-lived keys in the container.
- **Configuration:** standardize on env vars (see below) so the ingest tooling reads one contract.

### Option B — S3-compatible local store (optional)

- Run **MinIO** (or similar) locally; set `AWS_ENDPOINT_URL` (or your tool’s equivalent) to point at MinIO.
- **Production** keeps real S3; **local** can use a bucket name like `linkage-landing-local` for offline work.
- Use when you must avoid touching shared S3 from every laptop.

### Option C — Sync subset for offline dev

- `aws s3 sync s3://your-bucket/landing/ ./local-landing/` then ingest from disk.
- Good for demos; risk of **stale** data—document the sync cadence.

## Standard environment variables

These are the **contract** for tooling and future batch ingest (align with AWS SDK v2 defaults where applicable):

| Variable | Purpose |
| :--- | :--- |
| `AWS_REGION` | Region of the bucket (and Bedrock). |
| `LINKAGE_S3_BUCKET` | Bucket name for raw landing data. |
| `LINKAGE_S3_PREFIX` | Optional prefix (default `landing/`). |
| `AWS_ENDPOINT_URL` | Optional; set for MinIO/LocalStack (local only). |

**Secrets:** never commit bucket names that embed credentials; use IAM or scoped keys.

## IAM (AWS)

Minimum permissions for **ingest readers**:

- `s3:ListBucket` on `arn:aws:s3:::LINKAGE_S3_BUCKET` with prefix condition matching `LINKAGE_S3_PREFIX`
- `s3:GetObject` on `arn:aws:s3:::LINKAGE_S3_BUCKET/LINKAGE_S3_PREFIX*`

ECS task role (or Lambda execution role) should include the above **in addition to** Bedrock and Secrets Manager policies already described in `DEPLOYMENT_ECS_FARGATE.md`.

## How this relates to Bedrock

- Bedrock **does not read S3** for your linkage queries in the current design.
- Flow: **S3 (raw)** → **ingest** → **Postgres** → **resolve** uses SQL + optional vectors + **then** Bedrock for LLM summary/embeddings as configured.

## References

- Schema and API: `docs/README.md`, `docs/ARCHITECTURE.md`
- ECS/Fargate: `docs/DEPLOYMENT_ECS_FARGATE.md`
