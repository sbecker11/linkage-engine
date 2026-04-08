#!/usr/bin/env bash
# deploy/upload-to-s3.sh
#
# Creates the S3 landing bucket (if needed) and uploads a local NDJSON file.
# The Lambda ingest function is triggered automatically via S3 event notification
# once the object lands in the bucket (set up by deploy/provision-lambda.sh).
#
# Usage:
#   ./deploy/upload-to-s3.sh                                    # generate + upload 200 records
#   ./deploy/upload-to-s3.sh --file data/my-records.ndjson      # upload existing file
#   ./deploy/upload-to-s3.sh --count 1000                       # generate 1000 records then upload
#   VERBOSE=1 ./deploy/upload-to-s3.sh                          # show AWS responses

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${LINKAGE_S3_BUCKET:-linkage-engine-landing-${ACCOUNT_ID}}"
PREFIX="${LINKAGE_S3_PREFIX:-landing}"
APP=linkage-engine

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
if [ -z "$FILE" ]; then
  echo ""
  echo "▶ 1/3  Generating synthetic data  (${COUNT} records)"
  mkdir -p data
  FILE="data/synthetic-genealogy-${BATCH_DATE}.ndjson"
  python3 "$(dirname "$0")/generate-synthetic-data.py" \
    --count "$COUNT" \
    --seed  "$SEED" \
    --out   "$FILE"
else
  echo ""
  echo "▶ 1/3  Using existing file: ${FILE}"
  [ -f "$FILE" ] || { echo "  ✗ file not found: ${FILE}"; exit 1; }
  RECORD_COUNT=$(wc -l < "$FILE" | tr -d ' ')
  echo "  ✓ ${RECORD_COUNT} records"
fi

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

# ── 3. Upload ─────────────────────────────────────────────────────────────────
echo ""
echo "▶ 3/3  Uploading"
FILENAME=$(basename "$FILE")
S3_KEY="${PREFIX}/${BATCH_ID}/source=${APP}/${FILENAME}"

aws s3 cp "$FILE" "s3://${BUCKET}/${S3_KEY}" \
  --region "$REGION" \
  --metadata "source=${APP},batch=${BATCH_DATE},generator=synthetic"

echo "  ✓ uploaded"
detail "s3://${BUCKET}/${S3_KEY}"

FILE_SIZE=$(wc -c < "$FILE" | tr -d ' ')
RECORD_COUNT=$(wc -l < "$FILE" | tr -d ' ')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Upload complete"
echo ""
echo "  File:     ${FILE}  (${RECORD_COUNT} records, ${FILE_SIZE} bytes)"
echo "  S3 key:   s3://${BUCKET}/${S3_KEY}"
echo ""
echo "  If deploy/provision-lambda.sh has been run, the Lambda ingest"
echo "  function will trigger automatically within a few seconds."
echo ""
echo "  To check ingest progress:"
echo "    aws logs tail /aws/lambda/${APP}-ingest --region ${REGION} --follow"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
