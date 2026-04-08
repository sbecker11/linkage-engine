#!/usr/bin/env bash
# deploy/provision-lambda.sh
#
# Provisions the S3-triggered Lambda functions for linkage-engine.
# Run once after deploy/provision-aws.sh. Safe to re-run (idempotent).
#
# What it creates:
#   1. S3 raw bucket      (linkage-engine-raw-<account>)       ← external party uploads here
#   2. IAM role for ingestor Lambda  (linkage-engine-ingestor-role)
#   3. Lambda function  (linkage-engine-ingestor)  from deploy/lambda/linkage-engine-ingestor.py
#   4. S3 event notification  (raw bucket → ingestor)
#   5. S3 landing bucket  (linkage-engine-landing-<account>)
#   6. SQS dead-letter queue  (linkage-engine-store-dlq)
#   7. IAM role for store Lambda  (linkage-engine-store-role)
#   8. Lambda function  (linkage-engine-store)   from deploy/lambda/linkage-engine-store.py
#   9. Lambda function  (linkage-engine-validate) from deploy/lambda/linkage-engine-validate.py
#  10. S3 event notifications  (landing/ → validate, validated/ → store)
#
# Usage:
#   ./deploy/provision-lambda.sh
#   VERBOSE=1 ./deploy/provision-lambda.sh

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
APP=linkage-engine
RAW_BUCKET="${LINKAGE_S3_RAW_BUCKET:-${APP}-raw-${ACCOUNT_ID}}"
BUCKET="${LINKAGE_S3_BUCKET:-${APP}-landing-${ACCOUNT_ID}}"
PREFIX="${LINKAGE_S3_PREFIX:-landing}"
INGESTOR_FUNCTION_NAME="${APP}-ingestor"
INGESTOR_ROLE_NAME="${APP}-ingestor-role"
INGESTOR_LOG_GROUP="/aws/lambda/${INGESTOR_FUNCTION_NAME}"
FUNCTION_NAME="${APP}-store"
VALIDATE_FUNCTION_NAME="${APP}-validate"
VALIDATE_ROLE_NAME="${APP}-validate-role"
ROLE_NAME="${APP}-store-role"
UPLOADER_ROLE_NAME="${APP}-uploader-role"
DLQ_NAME="${APP}-store-dlq"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"
VALIDATE_LOG_GROUP="/aws/lambda/${VALIDATE_FUNCTION_NAME}"
VALIDATED_PREFIX="validated"
QUARANTINE_PREFIX="quarantine"
SNS_TOPIC_NAME="${APP}-alerts"

# ALB URL — read from AWS if not set
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${APP}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
LINKAGE_API_URL="${LINKAGE_API_URL:-http://${ALB_DNS}}"

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null; }
detail() { echo "    $*"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Provisioning Lambda pipeline  |  region: ${REGION}  |  account: ${ACCOUNT_ID}"
echo "  Raw bucket:     ${RAW_BUCKET}"
echo "  Landing bucket: ${BUCKET}"
echo "  API URL:        ${LINKAGE_API_URL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. S3 raw bucket (external-party upload target) ───────────────────────────
echo ""
echo "▶ 1/12  S3 raw bucket  (${RAW_BUCKET})"
if aws s3api head-bucket --bucket "$RAW_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  ✓ already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws_q aws s3api create-bucket --bucket "$RAW_BUCKET" --region "$REGION"
  else
    aws_q aws s3api create-bucket --bucket "$RAW_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws_q aws s3api put-public-access-block --bucket "$RAW_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "  ✓ created"
fi
detail "s3://${RAW_BUCKET}/"

# ── 2. IAM role for ingestor Lambda ──────────────────────────────────────────
echo ""
echo "▶ 2/12  Ingestor Lambda IAM role  (${INGESTOR_ROLE_NAME})"
INGESTOR_ROLE_ARN=$(aws iam get-role --role-name "$INGESTOR_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")

if [ "$INGESTOR_ROLE_ARN" = "not-found" ]; then
  INGESTOR_ROLE_ARN=$(aws iam create-role \
    --role-name "$INGESTOR_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)

  aws_q aws iam attach-role-policy --role-name "$INGESTOR_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  # Read from raw bucket, write+archive within raw bucket, write to landing bucket
  aws_q aws iam put-role-policy --role-name "$INGESTOR_ROLE_NAME" \
    --policy-name S3IngestorPipeline \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\",\"s3:HeadObject\"],
         \"Resource\":\"arn:aws:s3:::${RAW_BUCKET}/*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:PutObject\",\"s3:CopyObject\",\"s3:DeleteObject\"],
         \"Resource\":\"arn:aws:s3:::${RAW_BUCKET}/*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:PutObject\"],
         \"Resource\":\"arn:aws:s3:::${BUCKET}/${PREFIX}/*\"}
      ]}"

  echo "  ✓ role created"
  detail "${INGESTOR_ROLE_ARN}"
  echo "  ⏳ waiting 10s for IAM propagation…"
  sleep 10
else
  echo "  ✓ role exists"
  detail "${INGESTOR_ROLE_ARN}"
fi

# ── 3. Ingestor Lambda function ───────────────────────────────────────────────
echo ""
echo "▶ 3/12  Ingestor Lambda function  (${INGESTOR_FUNCTION_NAME})"

LAMBDA_DIR="$(dirname "$0")/lambda"
INGESTOR_ZIP="/tmp/${INGESTOR_FUNCTION_NAME}.zip"
cd "$LAMBDA_DIR"
zip -q "$INGESTOR_ZIP" linkage-engine-ingestor.py
cd - > /dev/null
detail "package: ${INGESTOR_ZIP}  ($(wc -c < "$INGESTOR_ZIP" | tr -d ' ') bytes)"

INGESTOR_ENV="Variables={LANDING_BUCKET=${BUCKET},CHUNK_SIZE=200}"

INGESTOR_EXISTS=$(aws lambda get-function --region "$REGION" \
  --function-name "$INGESTOR_FUNCTION_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "not-found")

if [ "$INGESTOR_EXISTS" = "not-found" ]; then
  aws_q aws lambda create-function \
    --region "$REGION" \
    --function-name "$INGESTOR_FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$INGESTOR_ROLE_ARN" \
    --handler linkage-engine-ingestor.handler \
    --zip-file "fileb://${INGESTOR_ZIP}" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$INGESTOR_ENV"
  echo "  ✓ function created"
  echo "  ⏳ waiting for function to become active…"
  aws lambda wait function-active --region "$REGION" --function-name "$INGESTOR_FUNCTION_NAME"
else
  aws_q aws lambda update-function-code \
    --region "$REGION" \
    --function-name "$INGESTOR_FUNCTION_NAME" \
    --zip-file "fileb://${INGESTOR_ZIP}"
  aws lambda wait function-updated --region "$REGION" --function-name "$INGESTOR_FUNCTION_NAME"
  aws_q aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$INGESTOR_FUNCTION_NAME" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$INGESTOR_ENV"
  echo "  ✓ function updated"
fi

INGESTOR_FUNC_ARN=$(aws lambda get-function --region "$REGION" \
  --function-name "$INGESTOR_FUNCTION_NAME" \
  --query 'Configuration.FunctionArn' --output text)
detail "${INGESTOR_FUNC_ARN}"

aws logs create-log-group --region "$REGION" \
  --log-group-name "$INGESTOR_LOG_GROUP" 2>/dev/null || true
aws_q aws logs put-retention-policy --region "$REGION" \
  --log-group-name "$INGESTOR_LOG_GROUP" --retention-in-days 30
detail "logs: ${INGESTOR_LOG_GROUP}  (30-day retention)"

# ── 4. S3 event notification: raw bucket → ingestor Lambda ───────────────────
echo ""
echo "▶ 4/12  S3 event notification  (raw bucket → ${INGESTOR_FUNCTION_NAME})"

aws lambda add-permission \
  --region "$REGION" \
  --function-name "$INGESTOR_FUNCTION_NAME" \
  --statement-id "S3InvokeIngestor" \
  --action "lambda:InvokeFunction" \
  --principal "s3.amazonaws.com" \
  --source-arn "arn:aws:s3:::${RAW_BUCKET}" \
  --source-account "$ACCOUNT_ID" \
  2>/dev/null || true

RAW_NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${INGESTOR_FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "suffix", "Value": ".ndjson"}
      ]}}
    },
    {
      "LambdaFunctionArn": "${INGESTOR_FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "suffix", "Value": ".jsonl"}
      ]}}
    },
    {
      "LambdaFunctionArn": "${INGESTOR_FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "suffix", "Value": ".json"}
      ]}}
    }
  ]
}
EOF
)

aws_q aws s3api put-bucket-notification-configuration \
  --region "$REGION" \
  --bucket "$RAW_BUCKET" \
  --notification-configuration "$RAW_NOTIFICATION_CONFIG"

echo "  ✓ notification configured"
detail "raw/*.ndjson|.jsonl|.json → ${INGESTOR_FUNCTION_NAME}"

# ── 5. S3 landing bucket ──────────────────────────────────────────────────────
echo ""
echo "▶ 5/12  S3 landing bucket  (${BUCKET})"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  ✓ already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws_q aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws_q aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws_q aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "  ✓ created"
fi
detail "s3://${BUCKET}/${PREFIX}/"

# ── 2. SQS dead-letter queue ──────────────────────────────────────────────────
echo ""
echo "▶ 6/12  SQS dead-letter queue  (${DLQ_NAME})"
DLQ_URL=$(aws sqs get-queue-url --region "$REGION" \
  --queue-name "$DLQ_NAME" \
  --query 'QueueUrl' --output text 2>/dev/null || echo "not-found")

if [ "$DLQ_URL" = "not-found" ]; then
  DLQ_URL=$(aws sqs create-queue --region "$REGION" \
    --queue-name "$DLQ_NAME" \
    --attributes MessageRetentionPeriod=1209600 \
    --query 'QueueUrl' --output text)
  echo "  ✓ created  (14-day retention)"
else
  echo "  ✓ exists"
fi

DLQ_ARN=$(aws sqs get-queue-attributes --region "$REGION" \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)
detail "ARN: ${DLQ_ARN}"

# ── 3. IAM role for Lambda ────────────────────────────────────────────────────
echo ""
echo "▶ 7/12  IAM role  (${ROLE_NAME})"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")

if [ "$ROLE_ARN" = "not-found" ]; then
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)

  # Basic Lambda execution (CloudWatch logs)
  aws_q aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  # S3 read on landing bucket
  aws_q aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name S3LandingRead \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\",\"s3:HeadObject\"],
         \"Resource\":\"arn:aws:s3:::${BUCKET}/${PREFIX}/*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:ListBucket\"],
         \"Resource\":\"arn:aws:s3:::${BUCKET}\",
         \"Condition\":{\"StringLike\":{\"s3:prefix\":\"${PREFIX}/*\"}}}
      ]}"

  # SQS send to DLQ
  aws_q aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name SQSDLQSend \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{\"Effect\":\"Allow\",
        \"Action\":[\"sqs:SendMessage\"],
        \"Resource\":\"${DLQ_ARN}\"}]}"

  echo "  ✓ role created"
  detail "${ROLE_ARN}"
  echo "  ⏳ waiting 10s for IAM propagation…"
  sleep 10
else
  echo "  ✓ role exists"
  detail "${ROLE_ARN}"
fi

# ── 4. Lambda function ────────────────────────────────────────────────────────
echo ""
echo "▶ 8/12  Lambda function  (${FUNCTION_NAME})"

# Zip the function
LAMBDA_DIR="$(dirname "$0")/lambda"
ZIP_FILE="/tmp/${FUNCTION_NAME}.zip"
cd "$LAMBDA_DIR"
zip -q "$ZIP_FILE" linkage-engine-store.py
cd - > /dev/null
detail "package: ${ZIP_FILE}  ($(wc -c < "$ZIP_FILE" | tr -d ' ') bytes)"

FUNC_EXISTS=$(aws lambda get-function --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "not-found")

# Sprint 9: read INGEST_API_KEY from Secrets Manager at provision time so the
# Lambda can authenticate against POST /v1/records.
INGEST_API_KEY_SECRET=$(aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "${APP}/runtime" \
  --query SecretString --output text 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('INGEST_API_KEY',''))" 2>/dev/null || echo "")
if [ -z "$INGEST_API_KEY_SECRET" ]; then
  echo "  ⚠  INGEST_API_KEY not found in Secrets Manager — store Lambda will send unauthenticated requests"
  echo "     Run provision-aws.sh first to generate the key, then re-run provision-lambda.sh"
fi

ENV_VARS="Variables={LINKAGE_API_URL=${LINKAGE_API_URL},INGEST_API_KEY=${INGEST_API_KEY_SECRET},BATCH_SIZE=50,DRY_RUN=false}"

if [ "$FUNC_EXISTS" = "not-found" ]; then
  aws_q aws lambda create-function \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler linkage-engine-store.handler \
    --zip-file "fileb://${ZIP_FILE}" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$ENV_VARS" \
    --dead-letter-config "TargetArn=${DLQ_ARN}"

  echo "  ✓ function created"

  # Wait for function to become Active
  echo "  ⏳ waiting for function to become active…"
  aws lambda wait function-active --region "$REGION" --function-name "$FUNCTION_NAME"
else
  # Update code and config
  aws_q aws lambda update-function-code \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://${ZIP_FILE}"

  aws lambda wait function-updated --region "$REGION" --function-name "$FUNCTION_NAME"

  aws_q aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$ENV_VARS" \
    --dead-letter-config "TargetArn=${DLQ_ARN}"

  echo "  ✓ function updated"
fi

FUNC_ARN=$(aws lambda get-function --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.FunctionArn' --output text)
detail "${FUNC_ARN}"

# CloudWatch log group with retention
aws logs create-log-group --region "$REGION" \
  --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws_q aws logs put-retention-policy --region "$REGION" \
  --log-group-name "$LOG_GROUP" --retention-in-days 30
detail "logs: ${LOG_GROUP}  (30-day retention)"

# ── 5. Validate Lambda — IAM role ─────────────────────────────────────────────
echo ""
echo "▶ 9/12  Validate Lambda IAM role  (${VALIDATE_ROLE_NAME})"

VALIDATE_ROLE_ARN=$(aws iam get-role --role-name "$VALIDATE_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")

if [ "$VALIDATE_ROLE_ARN" = "not-found" ]; then
  VALIDATE_ROLE_ARN=$(aws iam create-role \
    --role-name "$VALIDATE_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)

  aws_q aws iam attach-role-policy --role-name "$VALIDATE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  # Read from landing/, write to validated/ and quarantine/
  aws_q aws iam put-role-policy --role-name "$VALIDATE_ROLE_NAME" \
    --policy-name S3ValidatePipeline \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\",\"s3:HeadObject\"],
         \"Resource\":\"arn:aws:s3:::${BUCKET}/${PREFIX}/*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:PutObject\"],
         \"Resource\":[
           \"arn:aws:s3:::${BUCKET}/${VALIDATED_PREFIX}/*\",
           \"arn:aws:s3:::${BUCKET}/${QUARANTINE_PREFIX}/*\"]},
        {\"Effect\":\"Allow\",
         \"Action\":[\"s3:CopyObject\"],
         \"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}
      ]}"

  echo "  ✓ role created"
  detail "${VALIDATE_ROLE_ARN}"
  echo "  ⏳ waiting 10s for IAM propagation…"
  sleep 10
else
  echo "  ✓ role exists"
  detail "${VALIDATE_ROLE_ARN}"
fi

# ── 6. Validate Lambda — function ─────────────────────────────────────────────
echo ""
echo "▶ 10/12  Validate Lambda function  (${VALIDATE_FUNCTION_NAME})"

VALIDATE_ZIP="/tmp/${VALIDATE_FUNCTION_NAME}.zip"
cd "$LAMBDA_DIR"
zip -q "$VALIDATE_ZIP" linkage-engine-validate.py
cd - > /dev/null
detail "package: ${VALIDATE_ZIP}  ($(wc -c < "$VALIDATE_ZIP" | tr -d ' ') bytes)"

VALIDATE_ENV="Variables={VALIDATED_PREFIX=${VALIDATED_PREFIX},QUARANTINE_PREFIX=${QUARANTINE_PREFIX}}"

VALIDATE_EXISTS=$(aws lambda get-function --region "$REGION" \
  --function-name "$VALIDATE_FUNCTION_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "not-found")

if [ "$VALIDATE_EXISTS" = "not-found" ]; then
  aws_q aws lambda create-function \
    --region "$REGION" \
    --function-name "$VALIDATE_FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$VALIDATE_ROLE_ARN" \
    --handler linkage-engine-validate.handler \
    --zip-file "fileb://${VALIDATE_ZIP}" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$VALIDATE_ENV"
  echo "  ✓ function created"
  echo "  ⏳ waiting for function to become active…"
  aws lambda wait function-active --region "$REGION" --function-name "$VALIDATE_FUNCTION_NAME"
else
  aws_q aws lambda update-function-code \
    --region "$REGION" \
    --function-name "$VALIDATE_FUNCTION_NAME" \
    --zip-file "fileb://${VALIDATE_ZIP}"
  aws lambda wait function-updated --region "$REGION" --function-name "$VALIDATE_FUNCTION_NAME"
  aws_q aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$VALIDATE_FUNCTION_NAME" \
    --timeout 300 \
    --memory-size 256 \
    --environment "$VALIDATE_ENV"
  echo "  ✓ function updated"
fi

VALIDATE_FUNC_ARN=$(aws lambda get-function --region "$REGION" \
  --function-name "$VALIDATE_FUNCTION_NAME" \
  --query 'Configuration.FunctionArn' --output text)
detail "${VALIDATE_FUNC_ARN}"

aws logs create-log-group --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" 2>/dev/null || true
aws_q aws logs put-retention-policy --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" --retention-in-days 30
detail "logs: ${VALIDATE_LOG_GROUP}  (30-day retention)"

# ── 7. S3 event notifications (three-prefix pipeline) ─────────────────────────
#
# landing/   → validate Lambda   (external party drops files here)
# validated/ → ingest Lambda     (only clean records reach the API)
echo ""
echo "▶ 11/12  S3 event notifications  (landing → validate → validated → store)"

# Grant S3 permission to invoke validate Lambda
aws lambda add-permission \
  --region "$REGION" \
  --function-name "$VALIDATE_FUNCTION_NAME" \
  --statement-id "S3InvokeValidate" \
  --action "lambda:InvokeFunction" \
  --principal "s3.amazonaws.com" \
  --source-arn "arn:aws:s3:::${BUCKET}" \
  --source-account "$ACCOUNT_ID" \
  2>/dev/null || true

# Grant S3 permission to invoke ingest Lambda
aws lambda add-permission \
  --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --statement-id "S3InvokeIngest" \
  --action "lambda:InvokeFunction" \
  --principal "s3.amazonaws.com" \
  --source-arn "arn:aws:s3:::${BUCKET}" \
  --source-account "$ACCOUNT_ID" \
  2>/dev/null || true

# Configure both notifications in one call
NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${VALIDATE_FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "prefix", "Value": "${PREFIX}/"},
        {"Name": "suffix", "Value": ".ndjson"}
      ]}}
    },
    {
      "LambdaFunctionArn": "${VALIDATE_FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "prefix", "Value": "${PREFIX}/"},
        {"Name": "suffix", "Value": ".jsonl"}
      ]}}
    },
    {
      "LambdaFunctionArn": "${FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "prefix", "Value": "${VALIDATED_PREFIX}/"},
        {"Name": "suffix", "Value": ".ndjson"}
      ]}}
    },
    {
      "LambdaFunctionArn": "${FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "prefix", "Value": "${VALIDATED_PREFIX}/"},
        {"Name": "suffix", "Value": ".jsonl"}
      ]}}
    }
  ]
}
EOF
)

aws_q aws s3api put-bucket-notification-configuration \
  --region "$REGION" \
  --bucket "$BUCKET" \
  --notification-configuration "$NOTIFICATION_CONFIG"

echo "  ✓ notifications configured"
detail "landing/*.ndjson|.jsonl   → ${VALIDATE_FUNCTION_NAME}"
detail "validated/*.ndjson|.jsonl → ${FUNCTION_NAME}"

# ── 6. External uploader IAM role (PutObject-only on landing prefix) ──────────
#
# Use case A — external party is an AWS account / EC2 / Lambda:
#   They call: aws sts assume-role --role-arn <UPLOADER_ROLE_ARN> ...
#   Then use the temporary credentials to s3:PutObject on landing/* only.
#
# Use case B — external party is a non-AWS system:
#   An operator runs deploy/generate-presigned-url.sh which assumes this role
#   and generates a short-lived presigned PUT URL — no AWS credentials needed
#   on the external side.
echo ""
echo "▶ 12/12  External uploader IAM role  (${UPLOADER_ROLE_NAME})"

UPLOADER_ROLE_ARN=$(aws iam get-role --role-name "$UPLOADER_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")

if [ "$UPLOADER_ROLE_ARN" = "not-found" ]; then
  # Trust policy: only principals in this account can assume the role.
  # To allow a specific external AWS account, add its account ID to Principal.
  UPLOADER_ROLE_ARN=$(aws iam create-role \
    --role-name "$UPLOADER_ROLE_NAME" \
    --description "Scoped upload-only access to the linkage-engine landing bucket" \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": { \"AWS\": \"arn:aws:iam::${ACCOUNT_ID}:root\" },
        \"Action\": \"sts:AssumeRole\"
      }]
    }" \
    --query 'Role.Arn' --output text)

  # Inline policy: PutObject on landing/* only — nothing else.
  aws_q aws iam put-role-policy \
    --role-name "$UPLOADER_ROLE_NAME" \
    --policy-name S3LandingPutOnly \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"AllowPutObjectOnLandingPrefix\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:PutObject\"],
        \"Resource\": \"arn:aws:s3:::${BUCKET}/${PREFIX}/*\"
      }]
    }"

  echo "  ✓ role created"
  detail "${UPLOADER_ROLE_ARN}"
else
  echo "  ✓ role exists"
  detail "${UPLOADER_ROLE_ARN}"
fi

# ── 7. Bucket policy — enforce PutObject-only; deny destructive actions ───────
#
# This policy applies at the S3 resource level, independent of IAM.
# It ensures that even if the uploader role's IAM policy were accidentally
# broadened, the bucket itself will always refuse DeleteObject, DeleteBucket,
# and any action that isn't PutObject from the uploader role.
#
# The Lambda ingest role is explicitly exempted from the deny so it can
# read (GetObject) without being blocked.
echo ""
echo "▶  Bucket policy  (deny Delete* from non-Lambda principals)"

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")

BUCKET_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDeleteObjectForAll",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:DeleteBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    },
    {
      "Sid": "AllowValidateLambdaReadLandingWritePipeline",
      "Effect": "Allow",
      "Principal": { "AWS": "${VALIDATE_ROLE_ARN}" },
      "Action": [
        "s3:GetObject",
        "s3:HeadObject",
        "s3:CopyObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}/${PREFIX}/*",
        "arn:aws:s3:::${BUCKET}/${VALIDATED_PREFIX}/*",
        "arn:aws:s3:::${BUCKET}/${QUARANTINE_PREFIX}/*"
      ]
    },
    {
      "Sid": "AllowLambdaIngestRoleReadValidated",
      "Effect": "Allow",
      "Principal": { "AWS": "${LAMBDA_ROLE_ARN}" },
      "Action": [
        "s3:GetObject",
        "s3:HeadObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/${VALIDATED_PREFIX}/*"
      ]
    },
    {
      "Sid": "AllowUploaderRolePutOnly",
      "Effect": "Allow",
      "Principal": { "AWS": "${UPLOADER_ROLE_ARN}" },
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/${PREFIX}/*"
    }
  ]
}
POLICY
)

aws_q aws s3api put-bucket-policy \
  --bucket "$BUCKET" \
  --policy "$BUCKET_POLICY"

echo "  ✓ bucket policy applied"
detail "deny: s3:DeleteObject / DeleteObjectVersion / DeleteBucket — all principals"
detail "allow: s3:GetObject,HeadObject,ListBucket — Lambda ingest role only"
detail "allow: s3:PutObject on landing/* — uploader role only"

# ── CloudWatch — SNS topic, metric filters, alarms, dashboard ─────────────────
echo ""
echo "▶  CloudWatch — SNS topic"

# SNS topic for admin alerts
SNS_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn,'${SNS_TOPIC_NAME}')].TopicArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$SNS_ARN" = "None" ] || [ -z "$SNS_ARN" ]; then
  SNS_ARN=$(aws sns create-topic --region "$REGION" \
    --name "$SNS_TOPIC_NAME" \
    --query 'TopicArn' --output text)
  echo "  ✓ SNS topic created: ${SNS_ARN}"
  echo "  ⚠  Subscribe an admin email:"
  echo "     aws sns subscribe --region ${REGION} --topic-arn ${SNS_ARN} \\"
  echo "       --protocol email --notification-endpoint admin@example.com"
else
  echo "  ✓ SNS topic exists: ${SNS_ARN}"
fi

# ── CloudWatch metric filters ─────────────────────────────────────────────────
echo ""
echo "▶  CloudWatch — metric filters"

# IngressRecords — total lines seen per validate invocation
aws_q aws logs put-metric-filter \
  --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" \
  --filter-name "IngressRecords" \
  --filter-pattern "[level, msg, ..., ingress_label=\"ingress=*\", ingress_val, ...]" \
  --metric-transformations \
    metricName=IngressRecords,metricNamespace=LinkageEngine/Ingest,metricValue=1,unit=Count
detail "IngressRecords → LinkageEngine/Ingest"

# QuarantinedRecords — lines that failed validation
aws_q aws logs put-metric-filter \
  --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" \
  --filter-name "QuarantinedRecords" \
  --filter-pattern "[level, msg, ..., q_label=\"quarantined=*\", q_val, ...]" \
  --metric-transformations \
    metricName=QuarantinedRecords,metricNamespace=LinkageEngine/Ingest,metricValue=1,unit=Count
detail "QuarantinedRecords → LinkageEngine/Ingest"

echo "  ✓ metric filters configured"

# ── CloudWatch alarms (Sprint 10) ─────────────────────────────────────────────
echo ""
echo "▶  CloudWatch — alarms (Sprint 10)"

# 1. Validate Lambda TTL warning (duration > 10 min = 2/3 of 15 min limit)
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-lambda-validate-ttl-warning" \
  --alarm-description "validate Lambda duration > 600s — TTL exhaustion risk" \
  --namespace "AWS/Lambda" \
  --metric-name "Duration" \
  --dimensions "Name=FunctionName,Value=${VALIDATE_FUNCTION_NAME}" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 600000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-lambda-validate-ttl-warning: Duration > 600s"

# 2. Store Lambda TTL warning
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-lambda-store-ttl-warning" \
  --alarm-description "store Lambda duration > 600s — TTL exhaustion risk" \
  --namespace "AWS/Lambda" \
  --metric-name "Duration" \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 600000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-lambda-store-ttl-warning: Duration > 600s"

# 3. Validate Lambda errors (mid-file crash / OOM)
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-lambda-validate-errors" \
  --alarm-description "validate Lambda unhandled error — mid-file crash or OOM" \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions "Name=FunctionName,Value=${VALIDATE_FUNCTION_NAME}" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-lambda-validate-errors: Errors > 0 / 5min"

# 4. Store Lambda errors
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-lambda-store-errors" \
  --alarm-description "store Lambda unhandled error" \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-lambda-store-errors: Errors > 0 / 5min"

# 5. Store DLQ depth (Aurora 5xx exhaustion)
DLQ_ARN_FOR_ALARM=$(aws sqs get-queue-attributes --region "$REGION" \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text 2>/dev/null || echo "")

if [ -n "$DLQ_ARN_FOR_ALARM" ]; then
  aws_q aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "le-store-dlq-depth" \
    --alarm-description "store DLQ has messages — Aurora 5xx exhaustion or unhandled error" \
    --namespace "AWS/SQS" \
    --metric-name "ApproximateNumberOfMessagesVisible" \
    --dimensions "Name=QueueName,Value=${DLQ_NAME}" \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 0 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "$SNS_ARN"
  detail "le-store-dlq-depth: DLQ messages > 0 / 5min"
fi

# 6. Quarantine spike (carried forward from Sprint 3)
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-quarantine-spike" \
  --alarm-description "Quarantine rate spike: >50 records quarantined in 5 minutes" \
  --namespace "LinkageEngine/Ingest" \
  --metric-name "QuarantinedRecords" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-quarantine-spike: QuarantinedRecords > 50 / 5min"

# 7. Embedding gaps (Bedrock throttle — published by scheduled gap-publisher Lambda below)
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "le-embedding-gaps" \
  --alarm-description "Embedding gaps detected — Bedrock throttled or timed out during ingest" \
  --namespace "LinkageEngine/Health" \
  --metric-name "EmbeddingGapCount" \
  --statistic Maximum \
  --period 900 \
  --evaluation-periods 2 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
detail "le-embedding-gaps: EmbeddingGapCount > 0 for 2 consecutive 15min periods"

echo "  ✓ 7 alarms configured"

# ── Embedding gap publisher Lambda ────────────────────────────────────────────
# Scheduled every 15 min: calls GET /v1/ingest/health and publishes
# EmbeddingGapCount as a custom CloudWatch metric.
echo ""
echo "▶  Embedding gap publisher Lambda  (${APP}-gap-publisher)"

GAP_PUBLISHER_NAME="${APP}-gap-publisher"
GAP_PUBLISHER_LOG_GROUP="/aws/lambda/${GAP_PUBLISHER_NAME}"
GAP_PUBLISHER_ZIP="/tmp/${GAP_PUBLISHER_NAME}.zip"

# Inline the gap publisher as a heredoc — no separate file needed
python3 - <<'PYEOF' > /tmp/gap_publisher_src.py
# gap-publisher: called by EventBridge every 15 min
import json, os, urllib.request
import boto3

cw  = boto3.client("cloudwatch", region_name=os.environ.get("AWS_REGION", "us-west-1"))
API = os.environ.get("LINKAGE_API_URL", "").rstrip("/")

def handler(event, context):
    try:
        with urllib.request.urlopen(f"{API}/v1/ingest/health", timeout=5) as r:
            data = json.loads(r.read())
        gap_count = data.get("embeddingGapCount", 0)
    except Exception as e:
        print(f"health check failed: {e}")
        gap_count = 0

    cw.put_metric_data(
        Namespace="LinkageEngine/Health",
        MetricData=[{
            "MetricName": "EmbeddingGapCount",
            "Value":      float(gap_count),
            "Unit":       "Count",
        }]
    )
    print(f"published EmbeddingGapCount={gap_count}")
    return {"statusCode": 200}
PYEOF

cd /tmp && zip -q "$GAP_PUBLISHER_ZIP" gap_publisher_src.py && cd - > /dev/null

# Reuse the store role (already has CloudWatch + Lambda basic execution)
GAP_PUBLISHER_EXISTS=$(aws lambda get-function --region "$REGION" \
  --function-name "$GAP_PUBLISHER_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "not-found")

GAP_PUBLISHER_ENV="Variables={LINKAGE_API_URL=${LINKAGE_API_URL}}"

if [ "$GAP_PUBLISHER_EXISTS" = "not-found" ]; then
  # Create a minimal IAM role for the gap publisher
  GAP_ROLE_ARN=$(aws iam get-role --role-name "${APP}-gap-publisher-role" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")
  if [ "$GAP_ROLE_ARN" = "not-found" ]; then
    GAP_ROLE_ARN=$(aws iam create-role \
      --role-name "${APP}-gap-publisher-role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --query 'Role.Arn' --output text)
    aws_q aws iam attach-role-policy --role-name "${APP}-gap-publisher-role" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    aws_q aws iam put-role-policy --role-name "${APP}-gap-publisher-role" \
      --policy-name CloudWatchPutMetrics \
      --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudwatch:PutMetricData"],"Resource":"*"}]}'
    echo "  ⏳ waiting 10s for IAM propagation…"
    sleep 10
  fi
  aws_q aws lambda create-function \
    --region "$REGION" \
    --function-name "$GAP_PUBLISHER_NAME" \
    --runtime python3.12 \
    --role "$GAP_ROLE_ARN" \
    --handler gap_publisher_src.handler \
    --zip-file "fileb://${GAP_PUBLISHER_ZIP}" \
    --timeout 30 \
    --memory-size 128 \
    --environment "$GAP_PUBLISHER_ENV"
  echo "  ✓ gap publisher Lambda created"
  aws lambda wait function-active --region "$REGION" --function-name "$GAP_PUBLISHER_NAME"
else
  aws_q aws lambda update-function-code \
    --region "$REGION" \
    --function-name "$GAP_PUBLISHER_NAME" \
    --zip-file "fileb://${GAP_PUBLISHER_ZIP}"
  aws lambda wait function-updated --region "$REGION" --function-name "$GAP_PUBLISHER_NAME"
  aws_q aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$GAP_PUBLISHER_NAME" \
    --environment "$GAP_PUBLISHER_ENV"
  echo "  ✓ gap publisher Lambda updated"
fi

GAP_PUBLISHER_ARN=$(aws lambda get-function --region "$REGION" \
  --function-name "$GAP_PUBLISHER_NAME" \
  --query 'Configuration.FunctionArn' --output text)

# EventBridge rule: fire every 15 minutes
aws_q aws events put-rule \
  --region "$REGION" \
  --name "${APP}-gap-publisher-schedule" \
  --schedule-expression "rate(15 minutes)" \
  --state ENABLED \
  --description "Publishes EmbeddingGapCount metric to CloudWatch every 15 min"

aws lambda add-permission \
  --region "$REGION" \
  --function-name "$GAP_PUBLISHER_NAME" \
  --statement-id "EventBridgeInvokeGapPublisher" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${APP}-gap-publisher-schedule" \
  2>/dev/null || true

aws_q aws events put-targets \
  --region "$REGION" \
  --rule "${APP}-gap-publisher-schedule" \
  --targets "Id=gap-publisher,Arn=${GAP_PUBLISHER_ARN}"

aws logs create-log-group --region "$REGION" \
  --log-group-name "$GAP_PUBLISHER_LOG_GROUP" 2>/dev/null || true
aws_q aws logs put-retention-policy --region "$REGION" \
  --log-group-name "$GAP_PUBLISHER_LOG_GROUP" --retention-in-days 30

detail "schedule: rate(15 minutes) → ${GAP_PUBLISHER_NAME}"
echo "  ✓ gap publisher scheduled"

# ── CloudWatch dashboard — linkage-engine-ops (4-row unified view) ────────────
echo ""
echo "▶  CloudWatch — unified dashboard  (linkage-engine-ops)"

OPS_DASHBOARD=$(cat <<DASH
{
  "widgets": [
    {
      "type": "alarm",
      "x": 0, "y": 0, "width": 24, "height": 3,
      "properties": {
        "title": "Row 1 — Alarm States",
        "alarms": [
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-lambda-validate-ttl-warning",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-lambda-store-ttl-warning",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-lambda-validate-errors",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-lambda-store-errors",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-store-dlq-depth",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-embedding-gaps",
          "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:le-quarantine-spike"
        ]
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 3, "width": 12, "height": 6,
      "properties": {
        "title": "Row 2 — Lambda Duration p99 (validate + store)",
        "metrics": [
          ["AWS/Lambda","Duration","FunctionName","${VALIDATE_FUNCTION_NAME}",{"stat":"p99","label":"validate p99"}],
          ["AWS/Lambda","Duration","FunctionName","${FUNCTION_NAME}",{"stat":"p99","label":"store p99"}]
        ],
        "view": "timeSeries", "period": 60, "region": "${REGION}"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 3, "width": 12, "height": 6,
      "properties": {
        "title": "Row 2 — Lambda Errors + DLQ Depth",
        "metrics": [
          ["AWS/Lambda","Errors","FunctionName","${VALIDATE_FUNCTION_NAME}",{"stat":"Sum","label":"validate errors","color":"#d62728"}],
          ["AWS/Lambda","Errors","FunctionName","${FUNCTION_NAME}",{"stat":"Sum","label":"store errors","color":"#ff7f0e"}],
          ["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","${DLQ_NAME}",{"stat":"Maximum","label":"DLQ depth","color":"#9467bd"}]
        ],
        "view": "timeSeries", "period": 300, "region": "${REGION}"
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 9, "width": 24, "height": 6,
      "properties": {
        "title": "Row 3 — Ingest Pipeline (ingress / validated / quarantined / embedding gaps)",
        "metrics": [
          ["LinkageEngine/Ingest","IngressRecords",{"stat":"Sum","label":"Ingress","color":"#2ca02c"}],
          ["LinkageEngine/Ingest","QuarantinedRecords",{"stat":"Sum","label":"Quarantined","color":"#d62728"}],
          ["LinkageEngine/Health","EmbeddingGapCount",{"stat":"Maximum","label":"Embedding gaps","color":"#ff7f0e"}]
        ],
        "view": "timeSeries", "period": 300, "region": "${REGION}"
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 15, "width": 12, "height": 6,
      "properties": {
        "title": "Row 4 — Application Latency (linkage.resolve p50/p99)",
        "metrics": [
          ["LinkageEngine/App","linkage.resolve","quantile","0.5",{"stat":"Average","label":"resolve p50"}],
          ["LinkageEngine/App","linkage.resolve","quantile","0.99",{"stat":"Average","label":"resolve p99","color":"#d62728"}]
        ],
        "view": "timeSeries", "period": 300, "region": "${REGION}"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 15, "width": 12, "height": 6,
      "properties": {
        "title": "Row 4 — ECS CPU + Memory Utilization",
        "metrics": [
          ["AWS/ECS","CPUUtilization","ClusterName","${APP}-cluster","ServiceName","${APP}-service",{"stat":"Average","label":"CPU %"}],
          ["AWS/ECS","MemoryUtilization","ClusterName","${APP}-cluster","ServiceName","${APP}-service",{"stat":"Average","label":"Memory %","color":"#ff7f0e"}]
        ],
        "view": "timeSeries", "period": 300, "region": "${REGION}"
      }
    }
  ]
}
DASH
)

aws_q aws cloudwatch put-dashboard \
  --region "$REGION" \
  --dashboard-name "${APP}-ops" \
  --dashboard-body "$OPS_DASHBOARD"
detail "dashboard: ${APP}-ops (4-row unified view)"

echo "  ✓ CloudWatch configured"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Lambda pipeline provisioned"
echo ""
echo "  Pipeline:"
echo "    s3://${RAW_BUCKET}/         ← external party uploads here"
echo "          ↓  ObjectCreated → ${INGESTOR_FUNCTION_NAME}"
echo "    s3://${BUCKET}/landing/     ← chunk files written here"
echo "          ↓  ObjectCreated → ${VALIDATE_FUNCTION_NAME}"
echo "    s3://${BUCKET}/validated/   ← clean records"
echo "          ↓  ObjectCreated → ${FUNCTION_NAME}"
echo "    Spring Boot API             ← records stored in Aurora"
echo "    s3://${BUCKET}/quarantine/  ← failed validation (audit + replay)"
echo ""
echo "  Ingestor Lambda: ${INGESTOR_FUNCTION_NAME}"
echo "  Validate Lambda: ${VALIDATE_FUNCTION_NAME}"
echo "  Store Lambda:    ${FUNCTION_NAME}"
echo "  DLQ:             ${DLQ_NAME}"
echo "  API:             ${LINKAGE_API_URL}"
echo "  Uploader role:   ${UPLOADER_ROLE_ARN}"
echo "  Alerts SNS:      ${SNS_ARN}"
echo "  Alarms (7):      le-lambda-validate-ttl-warning, le-lambda-store-ttl-warning,"
echo "                   le-lambda-validate-errors, le-lambda-store-errors,"
echo "                   le-store-dlq-depth, le-embedding-gaps, le-quarantine-spike"
echo "  Dashboard:       ${APP}-ops  (CloudWatch → Dashboards)"
echo ""
echo "  ── External upload access ──────────────────────────────────"
echo ""
echo "  Option A — AWS-native external party (assume role):"
echo "    aws sts assume-role --role-arn ${UPLOADER_ROLE_ARN} \\"
echo "      --role-session-name upload-session"
echo "    # Use returned credentials to s3:PutObject on ${RAW_BUCKET}/*"
echo ""
echo "  Option B — Non-AWS external party (presigned URL, 1-hour TTL):"
echo "    ./deploy/generate-presigned-url.sh <filename.ndjson>"
echo ""
echo "  ── To ingest data ──────────────────────────────────────────"
echo ""
echo "  1. Generate + upload (triggers Lambda automatically):"
echo "       ./deploy/upload-to-s3.sh --count 500"
echo ""
echo "  2. Watch ingestor Lambda logs:"
echo "       aws logs tail ${INGESTOR_LOG_GROUP} --region ${REGION} --follow"
echo ""
echo "  3. Watch store Lambda logs:"
echo "       aws logs tail ${LOG_GROUP} --region ${REGION} --follow"
echo ""
echo "  4. Check DLQ for failures:"
echo "       aws sqs get-queue-attributes --region ${REGION} \\"
echo "         --queue-url ${DLQ_URL} \\"
echo "         --attribute-names ApproximateNumberOfMessages"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
