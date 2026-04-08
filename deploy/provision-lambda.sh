#!/usr/bin/env bash
# deploy/provision-lambda.sh
#
# Provisions the S3-triggered Lambda ingest function for linkage-engine.
# Run once after deploy/provision-aws.sh. Safe to re-run (idempotent).
#
# What it creates:
#   1. S3 landing bucket  (linkage-engine-landing-<account>)
#   2. SQS dead-letter queue  (linkage-engine-ingest-dlq)
#   3. IAM role for Lambda  (linkage-engine-ingest-role)
#   4. Lambda function  (linkage-engine-ingest)  from deploy/lambda/ingest-from-s3.py
#   5. S3 event notification  (ObjectCreated → Lambda on landing/ prefix)
#
# Usage:
#   ./deploy/provision-lambda.sh
#   VERBOSE=1 ./deploy/provision-lambda.sh

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
APP=linkage-engine
BUCKET="${LINKAGE_S3_BUCKET:-${APP}-landing-${ACCOUNT_ID}}"
PREFIX="${LINKAGE_S3_PREFIX:-landing}"
FUNCTION_NAME="${APP}-ingest"
ROLE_NAME="${APP}-ingest-role"
DLQ_NAME="${APP}-ingest-dlq"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ALB URL — read from AWS if not set
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${APP}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
LINKAGE_API_URL="${LINKAGE_API_URL:-http://${ALB_DNS}}"

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null; }
detail() { echo "    $*"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Provisioning Lambda ingest  |  region: ${REGION}  |  account: ${ACCOUNT_ID}"
echo "  Bucket:  ${BUCKET}"
echo "  API URL: ${LINKAGE_API_URL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. S3 landing bucket ──────────────────────────────────────────────────────
echo ""
echo "▶ 1/5  S3 landing bucket  (${BUCKET})"
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
echo "▶ 2/5  SQS dead-letter queue  (${DLQ_NAME})"
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
echo "▶ 3/5  IAM role  (${ROLE_NAME})"
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
echo "▶ 4/5  Lambda function  (${FUNCTION_NAME})"

# Zip the function
LAMBDA_DIR="$(dirname "$0")/lambda"
ZIP_FILE="/tmp/${FUNCTION_NAME}.zip"
cd "$LAMBDA_DIR"
zip -q "$ZIP_FILE" ingest-from-s3.py
cd - > /dev/null
detail "package: ${ZIP_FILE}  ($(wc -c < "$ZIP_FILE" | tr -d ' ') bytes)"

FUNC_EXISTS=$(aws lambda get-function --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "not-found")

ENV_VARS="Variables={LINKAGE_API_URL=${LINKAGE_API_URL},BATCH_SIZE=50,DRY_RUN=false}"

if [ "$FUNC_EXISTS" = "not-found" ]; then
  aws_q aws lambda create-function \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler ingest-from-s3.handler \
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

# ── 5. S3 event notification ──────────────────────────────────────────────────
echo ""
echo "▶ 5/5  S3 event notification  (ObjectCreated → Lambda)"

# Grant S3 permission to invoke Lambda
aws lambda add-permission \
  --region "$REGION" \
  --function-name "$FUNCTION_NAME" \
  --statement-id "S3InvokeIngest" \
  --action "lambda:InvokeFunction" \
  --principal "s3.amazonaws.com" \
  --source-arn "arn:aws:s3:::${BUCKET}" \
  --source-account "$ACCOUNT_ID" \
  2>/dev/null || true  # ignore if permission already exists

# Configure S3 notification
NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "${PREFIX}/"},
            {"Name": "suffix", "Value": ".ndjson"}
          ]
        }
      }
    },
    {
      "LambdaFunctionArn": "${FUNC_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "${PREFIX}/"},
            {"Name": "suffix", "Value": ".jsonl"}
          ]
        }
      }
    }
  ]
}
EOF
)

aws_q aws s3api put-bucket-notification-configuration \
  --region "$REGION" \
  --bucket "$BUCKET" \
  --notification-configuration "$NOTIFICATION_CONFIG"

echo "  ✓ notification configured"
detail "trigger: s3:ObjectCreated on s3://${BUCKET}/${PREFIX}/*.ndjson"
detail "trigger: s3:ObjectCreated on s3://${BUCKET}/${PREFIX}/*.jsonl"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Lambda ingest provisioned"
echo ""
echo "  Bucket:    s3://${BUCKET}/${PREFIX}/"
echo "  Lambda:    ${FUNCTION_NAME}"
echo "  DLQ:       ${DLQ_NAME}"
echo "  API:       ${LINKAGE_API_URL}"
echo ""
echo "  ── To ingest data ──────────────────────────────────────────"
echo ""
echo "  1. Generate + upload (triggers Lambda automatically):"
echo "       ./deploy/upload-to-s3.sh --count 500"
echo ""
echo "  2. Watch Lambda logs:"
echo "       aws logs tail ${LOG_GROUP} --region ${REGION} --follow"
echo ""
echo "  3. Check DLQ for failures:"
echo "       aws sqs get-queue-attributes --region ${REGION} \\"
echo "         --queue-url ${DLQ_URL} \\"
echo "         --attribute-names ApproximateNumberOfMessages"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
