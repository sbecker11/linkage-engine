#!/usr/bin/env bash
# deploy/demo-stop.sh
#
# Shuts down all billable compute for linkage-engine, bringing AWS cost to ~$0.
# Safe to run multiple times (idempotent).
#
# What stops:       ECS tasks (Fargate billing ends immediately)
#                   Aurora cluster (pauses after ~5 min idle, billing ends)
# What stays:       ALB (~$0.008/hr), ECR, S3, Secrets Manager, Lambda, CloudWatch
#
# Usage:
#   ./deploy/demo-stop.sh
#   VERBOSE=1 ./deploy/demo-stop.sh

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
APP=linkage-engine
CLUSTER="${APP}-cluster"
SERVICE="${APP}-service"
DB_CLUSTER_ID="${APP}-aurora"

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null; }

START_TS=$(date +%s)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🛑  demo-stop  |  ${APP}  |  region: ${REGION}"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Scale ECS service to 0 ─────────────────────────────────────────────────
echo ""
echo "▶ 1/3  ECS service  (${SERVICE})"
CURRENT_COUNT=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text 2>/dev/null || echo "0")

if [ "$CURRENT_COUNT" = "0" ]; then
  echo "  ✓ already at 0 tasks"
else
  aws_q aws ecs update-service --region "$REGION" \
    --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0
  echo "  ✓ scaled to 0  (was ${CURRENT_COUNT})  — Fargate billing stops now"
fi

# ── 2. Pause Aurora cluster ───────────────────────────────────────────────────
echo ""
echo "▶ 2/3  Aurora cluster  (${DB_CLUSTER_ID})"
DB_STATUS=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$DB_CLUSTER_ID" \
  --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "not-found")

if [ "$DB_STATUS" = "not-found" ]; then
  echo "  ✓ cluster not found — nothing to do"
elif [ "$DB_STATUS" = "stopped" ] || [ "$DB_STATUS" = "paused" ]; then
  echo "  ✓ already stopped/paused  (status: ${DB_STATUS})"
else
  # Set MinCapacity=0 to enable auto-pause; cluster pauses after ~5 min idle
  aws_q aws rds modify-db-cluster --region "$REGION" \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --serverless-v2-scaling-configuration MinCapacity=0,MaxCapacity=2
  echo "  ✓ MinCapacity set to 0  — cluster will pause after ~5 min idle"
  echo "    (status: ${DB_STATUS} → will become 'paused' automatically)"
fi

# ── 3. Verify Lambda is idle (no cost when not invoked) ───────────────────────
echo ""
echo "▶ 3/3  Lambda  (${APP}-ingest)"
FUNC_STATE=$(aws lambda get-function --region "$REGION" \
  --function-name "${APP}-ingest" \
  --query 'Configuration.State' --output text 2>/dev/null || echo "not-found")
if [ "$FUNC_STATE" = "not-found" ]; then
  echo "  ✓ not provisioned — no cost"
else
  echo "  ✓ idle  (state: ${FUNC_STATE})  — Lambda has no idle cost"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TS ))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Shutdown complete  (${ELAPSED}s)"
echo ""
echo "  Stopped:   ECS tasks (Fargate billing ended)"
echo "  Pausing:   Aurora cluster (billing ends in ~5 min)"
echo "  Running:   ALB (~\$0.008/hr = ~\$0.19/day — negligible)"
echo ""
echo "  Estimated cost while stopped: < \$0.25/day"
echo ""
echo "  To restart for a demo:"
echo "    ./deploy/demo-start.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
