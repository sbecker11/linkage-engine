#!/usr/bin/env bash
# deploy/upload-to-s3.sh
#
# Creates the S3 landing bucket (if needed) and uploads local NDJSON chunk files.
# The validate Lambda is triggered automatically via S3 event notification once
# each chunk lands in the bucket (set up by deploy/provision-lambda.sh).
#
# Files exceeding CHUNK_SIZE lines are rejected — use generate-synthetic-data.py
# (which auto-splits) or the linkage-engine-ingestor Lambda (Phase 3d-ii) for
# large external files.
#
# CHUNK_SIZE tuning: CHUNK_SIZE = floor(600 / p99_latency_per_record)
# where 600s = half the 15-min Lambda TTL. Default: 200.
#
# Usage:
#   ./deploy/upload-to-s3.sh                                    # generate + upload ≤200 records
#   ./deploy/upload-to-s3.sh --file data/my-records.ndjson      # upload existing file (must be ≤200 lines)
#   ./deploy/upload-to-s3.sh --count 1000                       # generate 1000 records → 5 chunk files, upload all
#   VERBOSE=1 ./deploy/upload-to-s3.sh                          # show AWS responses

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${LINKAGE_S3_BUCKET:-linkage-engine-landing-${ACCOUNT_ID}}"
PREFIX="${LINKAGE_S3_PREFIX:-landing}"
APP=linkage-engine

# Maximum lines per file — must match CHUNK_SIZE in generate-synthetic-data.py.
# Files exceeding this limit are rejected to protect the validate Lambda from TTL exhaustion.
# Tune: CHUNK_SIZE = floor(600 / p99_latency_per_record)
CHUNK_SIZE=200

# ── Parse args ────────────────────────────────────────────────────────────────
FILE=""
COUNT=200
SEED=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --file)  FILE="$2";  shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --seed)  SEED="$2";  shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null; }
detail() { echo "    $*"; }

BATCH_DATE=$(date -u +%Y-%m-%d)
BATCH_ID="batch=${BATCH_DATE}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  S3 upload  |  bucket: ${BUCKET}  |  prefix: ${PREFIX}/${BATCH_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Generate NDJSON if no file provided ────────────────────────────────────
FILES_TO_UPLOAD=()

if [ -z "$FILE" ]; then
  echo ""
  echo "▶ 1/3  Generating synthetic data  (${COUNT} records, CHUNK_SIZE=${CHUNK_SIZE})"
  mkdir -p data
  BASE_FILE="data/synthetic-genealogy-${BATCH_DATE}.ndjson"
  python3 "$(dirname "$0")/generate-synthetic-data.py" \
    --count "$COUNT" \
    --seed  "$SEED" \
    --out   "$BASE_FILE"
  # Collect all chunk files produced (single file or chunk-NNN files)
  STEM="data/synthetic-genealogy-${BATCH_DATE}"
  if [ -f "${STEM}.ndjson" ]; then
    FILES_TO_UPLOAD+=("${STEM}.ndjson")
  fi
  for chunk in "${STEM}"-chunk-*.ndjson; do
    [ -f "$chunk" ] && FILES_TO_UPLOAD+=("$chunk")
  done
else
  echo ""
  echo "▶ 1/3  Using existing file: ${FILE}"
  [ -f "$FILE" ] || { echo "  ✗ file not found: ${FILE}"; exit 1; }
  LINE_COUNT=$(wc -l < "$FILE" | tr -d ' ')
  if [ "$LINE_COUNT" -gt "$CHUNK_SIZE" ]; then
    echo "  ✗ file has ${LINE_COUNT} lines — exceeds CHUNK_SIZE=${CHUNK_SIZE}"
    echo ""
    echo "  Files larger than CHUNK_SIZE risk Lambda TTL exhaustion."
    echo "  Options:"
    echo "    1. Use generate-synthetic-data.py (auto-splits into chunks)"
    echo "    2. Split manually: split -l ${CHUNK_SIZE} ${FILE} chunk-"
    echo "    3. Use the linkage-engine-ingestor Lambda (Phase 3d-ii) for external files"
    exit 1
  fi
  echo "  ✓ ${LINE_COUNT} lines (within CHUNK_SIZE=${CHUNK_SIZE})"
  FILES_TO_UPLOAD+=("$FILE")
fi

echo "  ✓ ${#FILES_TO_UPLOAD[@]} file(s) to upload"

# ── 2. Create S3 bucket (idempotent) ──────────────────────────────────────────
echo ""
echo "▶ 2/3  S3 bucket  (${BUCKET})"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  ✓ already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws_q aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION"
  else
    aws_q aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  # Block all public access
  aws_q aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "  ✓ created  (public access blocked)"
fi
detail "s3://${BUCKET}"

# ── 3. Upload all chunk files ──────────────────────────────────────────────────
echo ""
echo "▶ 3/3  Uploading ${#FILES_TO_UPLOAD[@]} file(s)"
TOTAL_RECORDS=0
for UPLOAD_FILE in "${FILES_TO_UPLOAD[@]}"; do
  FILENAME=$(basename "$UPLOAD_FILE")
  S3_KEY="${PREFIX}/${BATCH_ID}/source=${APP}/${FILENAME}"
  aws s3 cp "$UPLOAD_FILE" "s3://${BUCKET}/${S3_KEY}" \
    --region "$REGION" \
    --metadata "source=${APP},batch=${BATCH_DATE},generator=synthetic"
  LINE_COUNT=$(wc -l < "$UPLOAD_FILE" | tr -d ' ')
  TOTAL_RECORDS=$((TOTAL_RECORDS + LINE_COUNT))
  detail "s3://${BUCKET}/${S3_KEY}  (${LINE_COUNT} records)"
done
echo "  ✓ uploaded ${#FILES_TO_UPLOAD[@]} file(s), ${TOTAL_RECORDS} total records"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Upload complete"
echo ""
echo "  Files:    ${#FILES_TO_UPLOAD[@]} chunk(s), ${TOTAL_RECORDS} total records"
echo "  S3 path:  s3://${BUCKET}/${PREFIX}/${BATCH_ID}/source=${APP}/"
echo ""
echo "  If deploy/provision-lambda.sh has been run, the validate Lambda"
echo "  will trigger automatically for each file within a few seconds."
echo ""
echo "  To check validate progress:"
echo "    aws logs tail /aws/lambda/${APP}-validate --region ${REGION} --follow"
echo "  To check store progress:"
echo "    aws logs tail /aws/lambda/${APP}-store --region ${REGION} --follow"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
