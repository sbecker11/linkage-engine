#!/usr/bin/env bash
# deploy/archive-records.sh
#
# Sprint 6 — Storage and Archival
#
# Archives records older than RETENTION_DAYS (default: 90) from Aurora to S3
# as NDJSON, then prunes the corresponding record_embeddings rows.
#
# Why NDJSON instead of Parquet?
#   Aurora Serverless v2 does not support the native `aws rds start-export-task`
#   Parquet export (that requires a provisioned cluster with an S3 export role).
#   Instead, we use psql COPY TO to stream rows as JSON, which works with any
#   Aurora/PostgreSQL endpoint and requires only a network connection.
#   Archived files are queryable via Athena using a JSON SerDe.
#
# What it does:
#   1. Selects record_ids older than RETENTION_DAYS
#   2. In --dry-run mode: prints count and sample IDs, exits 0 — no DB changes
#   3. In live mode:
#      a. Exports matching rows from `records` + `record_embeddings` to S3 as NDJSON
#      b. Deletes record_embeddings rows for archived records
#      c. Deletes records rows for archived records
#      d. Writes a manifest to S3 with archive metadata
#
# Usage:
#   ./deploy/archive-records.sh --dry-run
#   ./deploy/archive-records.sh
#   RETENTION_DAYS=30 ./deploy/archive-records.sh --dry-run
#   VERBOSE=1 ./deploy/archive-records.sh
#
# Requirements:
#   - psql on PATH (brew install libpq)
#   - AWS CLI v2
#   - DB_URL / DB_USER / DB_PASSWORD set (or sourced from .env)
#   - ARCHIVE_BUCKET set (or defaults to linkage-engine-archive-<account>)

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
APP="linkage-engine"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
DRY_RUN=false
ARCHIVE_DATE=$(date -u +%Y-%m-%d)

# DB connection — prefer env vars, fall back to .env
if [ -f "$(dirname "$0")/../.env" ]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-linkage_db}"
DB_USER="${DB_USER:-ancestry}"
DB_PASSWORD="${DB_PASSWORD:-password}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "local")
ARCHIVE_BUCKET="${ARCHIVE_BUCKET:-${APP}-archive-${ACCOUNT_ID}}"
ARCHIVE_PREFIX="records/${ARCHIVE_DATE}"

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null 2>&1; }
detail() { echo "    $*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📦  archive-records  |  ${APP}  |  region: ${REGION}"
echo "  retention: ${RETENTION_DAYS} days  |  dry_run: ${DRY_RUN}"
echo "  archive: s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

export PGPASSWORD="$DB_PASSWORD"
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A"

# ── 1. Count records eligible for archival ────────────────────────────────────
echo ""
echo "▶ 1/4  Counting records older than ${RETENTION_DAYS} days"

ELIGIBLE_COUNT=$($PSQL -c \
  "SELECT count(*) FROM records WHERE created_at < now() - interval '${RETENTION_DAYS} days';" \
  2>/dev/null || echo "0")

echo "  ✓ ${ELIGIBLE_COUNT} records eligible for archival"

if [ "$ELIGIBLE_COUNT" = "0" ]; then
  echo ""
  echo "  Nothing to archive. Exiting."
  exit 0
fi

# Show sample IDs
SAMPLE_IDS=$($PSQL -c \
  "SELECT record_id FROM records WHERE created_at < now() - interval '${RETENTION_DAYS} days' LIMIT 5;" \
  2>/dev/null || echo "(unable to query)")
detail "sample record_ids: $(echo "$SAMPLE_IDS" | tr '\n' ' ')"

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🔍  DRY RUN — no changes made"
  echo "  Would archive: ${ELIGIBLE_COUNT} records"
  echo "  Would write to: s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/"
  echo "  Re-run without --dry-run to execute."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

# ── 2. Ensure archive bucket exists ──────────────────────────────────────────
echo ""
echo "▶ 2/4  Archive bucket  (${ARCHIVE_BUCKET})"
if aws s3api head-bucket --bucket "$ARCHIVE_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  ✓ already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws_q aws s3api create-bucket --bucket "$ARCHIVE_BUCKET" --region "$REGION"
  else
    aws_q aws s3api create-bucket --bucket "$ARCHIVE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws_q aws s3api put-public-access-block --bucket "$ARCHIVE_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "  ✓ created"
fi

# ── 3. Export records + embeddings to S3 as NDJSON ───────────────────────────
echo ""
echo "▶ 3/4  Exporting ${ELIGIBLE_COUNT} records to S3"

RECORDS_FILE="/tmp/archive-records-${ARCHIVE_DATE}.ndjson"
EMBEDDINGS_FILE="/tmp/archive-embeddings-${ARCHIVE_DATE}.ndjson"

# Export records as JSON lines
$PSQL -c \
  "COPY (
    SELECT row_to_json(r)
    FROM records r
    WHERE created_at < now() - interval '${RETENTION_DAYS} days'
  ) TO STDOUT;" > "$RECORDS_FILE"

EXPORTED_COUNT=$(wc -l < "$RECORDS_FILE" | tr -d ' ')
detail "exported ${EXPORTED_COUNT} record rows → ${RECORDS_FILE}"

# Export embeddings for those records (vector stored as text)
$PSQL -c \
  "COPY (
    SELECT row_to_json(re)
    FROM record_embeddings re
    WHERE re.record_id IN (
      SELECT record_id FROM records
      WHERE created_at < now() - interval '${RETENTION_DAYS} days'
    )
  ) TO STDOUT;" > "$EMBEDDINGS_FILE"

EMBEDDING_COUNT=$(wc -l < "$EMBEDDINGS_FILE" | tr -d ' ')
detail "exported ${EMBEDDING_COUNT} embedding rows → ${EMBEDDINGS_FILE}"

# Upload to S3
aws s3 cp "$RECORDS_FILE" \
  "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/records.ndjson" \
  --region "$REGION"
aws s3 cp "$EMBEDDINGS_FILE" \
  "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/embeddings.ndjson" \
  --region "$REGION"
echo "  ✓ uploaded to s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/"

# Write manifest
MANIFEST=$(python3 -c "
import json, datetime
print(json.dumps({
  'archivedAt':    '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
  'retentionDays': ${RETENTION_DAYS},
  'recordCount':   ${EXPORTED_COUNT},
  'embeddingCount':${EMBEDDING_COUNT},
  'bucket':        '${ARCHIVE_BUCKET}',
  'prefix':        '${ARCHIVE_PREFIX}',
}, indent=2))
")
echo "$MANIFEST" | aws s3 cp - \
  "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/manifest.json" \
  --region "$REGION" --content-type application/json
detail "manifest written"

# ── 4. Prune archived rows from Aurora ───────────────────────────────────────
echo ""
echo "▶ 4/4  Pruning archived rows from Aurora"

# Delete embeddings first (FK constraint)
DELETED_EMBEDDINGS=$($PSQL -c \
  "DELETE FROM record_embeddings
   WHERE record_id IN (
     SELECT record_id FROM records
     WHERE created_at < now() - interval '${RETENTION_DAYS} days'
   )
   RETURNING record_id;" 2>/dev/null | wc -l | tr -d ' ')

DELETED_RECORDS=$($PSQL -c \
  "DELETE FROM records
   WHERE created_at < now() - interval '${RETENTION_DAYS} days'
   RETURNING record_id;" 2>/dev/null | wc -l | tr -d ' ')

echo "  ✓ deleted ${DELETED_EMBEDDINGS} embedding rows"
echo "  ✓ deleted ${DELETED_RECORDS} record rows"

# Cleanup temp files
rm -f "$RECORDS_FILE" "$EMBEDDINGS_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Archival complete"
echo "  Archived:  ${EXPORTED_COUNT} records, ${EMBEDDING_COUNT} embeddings"
echo "  Pruned:    ${DELETED_RECORDS} record rows, ${DELETED_EMBEDDINGS} embedding rows"
echo "  Location:  s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/"
echo ""
echo "  Query archived records with Athena:"
echo "    SELECT * FROM linkage_archive.records"
echo "    WHERE json_extract_scalar(record, '\$.record_id') = 'DEMO-A';"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
