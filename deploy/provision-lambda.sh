#!/usr/bin/env bash
# deploy/provision-lambda.sh
#
# Provisions the S3-triggered Lambda functions for linkage-engine.
# Run once after deploy/provision-aws.sh. Safe to re-run (idempotent).
#
# What it creates:
#   1. S3 landing bucket  (linkage-engine-landing-<account>)
#   2. SQS dead-letter queue  (linkage-engine-store-dlq)
#   3. IAM role for store Lambda  (linkage-engine-store-role)
#   4. Lambda function  (linkage-engine-store)   from deploy/lambda/linkage-engine-store.py
#   5. Lambda function  (linkage-engine-validate) from deploy/lambda/linkage-engine-validate.py
#   6. S3 event notifications  (landing/ → validate, validated/ → store)
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
zip -q "$ZIP_FILE" linkage-engine-store.py
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
echo "▶ 5/10  Validate Lambda IAM role  (${VALIDATE_ROLE_NAME})"

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
echo "▶ 6/10  Validate Lambda function  (${VALIDATE_FUNCTION_NAME})"

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
echo "▶ 7/10  S3 event notifications  (landing → validate → validated → ingest)"

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
echo "▶ 8/10  External uploader IAM role  (${UPLOADER_ROLE_NAME})"

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
echo "▶ 9/10  Bucket policy  (deny Delete* from non-Lambda principals)"

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

# ── 10. CloudWatch — metric filters, quarantine alarm, dashboard ──────────────
echo ""
echo "▶ 10/10  CloudWatch metrics, alarm, and dashboard"

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

# Metric filter — IngressRecords (total lines seen per invocation)
aws_q aws logs put-metric-filter \
  --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" \
  --filter-name "IngressRecords" \
  --filter-pattern "[level, msg, ..., ingress_label=\"ingress=*\", ingress_val, ...]" \
  --metric-transformations \
    metricName=IngressRecords,metricNamespace=LinkageEngine/Ingest,metricValue=1,unit=Count
detail "metric filter: IngressRecords → LinkageEngine/Ingest"

# Metric filter — QuarantinedRecords (lines that failed validation)
aws_q aws logs put-metric-filter \
  --region "$REGION" \
  --log-group-name "$VALIDATE_LOG_GROUP" \
  --filter-name "QuarantinedRecords" \
  --filter-pattern "[level, msg, ..., q_label=\"quarantined=*\", q_val, ...]" \
  --metric-transformations \
    metricName=QuarantinedRecords,metricNamespace=LinkageEngine/Ingest,metricValue=1,unit=Count
detail "metric filter: QuarantinedRecords → LinkageEngine/Ingest"

# CloudWatch alarm — quarantine spike
aws_q aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "${APP}-quarantine-spike" \
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
detail "alarm: QuarantinedRecords > 50 / 5min → ${SNS_TOPIC_NAME}"

# CloudWatch dashboard — ingress volume vs quarantine rate
DASHBOARD_BODY=$(cat <<DASH
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "title": "Ingest Pipeline — Ingress vs Quarantine",
        "metrics": [
          ["LinkageEngine/Ingest", "IngressRecords",   {"label":"Ingress",    "color":"#2ca02c"}],
          ["LinkageEngine/Ingest", "QuarantinedRecords",{"label":"Quarantined","color":"#d62728"}]
        ],
        "view": "timeSeries",
        "stacked": false,
        "period": 300,
        "stat": "Sum",
        "region": "${REGION}"
      }
    }
  ]
}
DASH
)

aws_q aws cloudwatch put-dashboard \
  --region "$REGION" \
  --dashboard-name "${APP}-ingest" \
  --dashboard-body "$DASHBOARD_BODY"
detail "dashboard: ${APP}-ingest (ingress vs quarantine rate)"

echo "  ✓ CloudWatch configured"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Lambda pipeline provisioned"
echo ""
echo "  Bucket:          s3://${BUCKET}/"
echo "    landing/       ← external party uploads here"
echo "    validated/     ← clean records (triggers ingest Lambda)"
echo "    quarantine/    ← failed validation (audit + replay)"
echo "  Validate Lambda: ${VALIDATE_FUNCTION_NAME}"
echo "  Ingest Lambda:   ${FUNCTION_NAME}"
echo "  DLQ:             ${DLQ_NAME}"
echo "  API:             ${LINKAGE_API_URL}"
echo "  Uploader role:   ${UPLOADER_ROLE_ARN}"
echo "  Alerts SNS:      ${SNS_ARN}"
echo ""
echo "  ── External upload access ──────────────────────────────────"
echo ""
echo "  Option A — AWS-native external party (assume role):"
echo "    aws sts assume-role --role-arn ${UPLOADER_ROLE_ARN} \\"
echo "      --role-session-name upload-session"
echo "    # Use returned credentials to s3:PutObject on landing/*"
echo ""
echo "  Option B — Non-AWS external party (presigned URL, 1-hour TTL):"
echo "    ./deploy/generate-presigned-url.sh <filename.ndjson>"
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
