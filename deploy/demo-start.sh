#!/usr/bin/env bash
# deploy/demo-start.sh
#
# Commissions linkage-engine for a live demo.
# Scales ECS back to 1 task, waits for health, runs pre-demo checklist.
# Safe to run multiple times (idempotent).
#
# Typical warm-up time: 3-5 minutes
#   ~0s   ECS task scheduled
#   ~15s  Aurora resumes from pause (cold start)
#   ~15s  Spring Boot starts
#   ~30s  ALB health checks pass
#   ~60s  Service stable
#
# Usage:
#   ./deploy/demo-start.sh
#   ./deploy/demo-start.sh --skip-seed    # skip seed data check
#   VERBOSE=1 ./deploy/demo-start.sh

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
REGION="${AWS_REGION:-us-west-1}"
APP=linkage-engine
CLUSTER="${APP}-cluster"
SERVICE="${APP}-service"
DB_CLUSTER_ID="${APP}-aurora"
SKIP_SEED=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-seed) SKIP_SEED=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

aws_q() { [ "$VERBOSE" -ge 1 ] && "$@" || "$@" > /dev/null; }
detail() { echo "    $*"; }

START_TS=$(date +%s)
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SI=0

spinner_wait() {
  # spinner_wait <check_command> <success_pattern> <label> <timeout_secs>
  local CMD="$1" PAT="$2" LABEL="$3" TIMEOUT="${4:-300}"
  local T=0
  while [ $T -lt $TIMEOUT ]; do
    local OUT
    OUT=$(eval "$CMD" 2>/dev/null || echo "")
    if echo "$OUT" | grep -q "$PAT"; then
      printf "\r  ✓ %-50s (%ds)\n" "$LABEL" "$T"
      return 0
    fi
    printf "\r  %s %-50s (%ds)" "${SPIN[$SI]}" "$LABEL" "$T"
    SI=$(( (SI + 1) % ${#SPIN[@]} ))
    sleep 3
    T=$(( T + 3 ))
  done
  printf "\r  ✗ %-50s (timeout after %ds)\n" "$LABEL" "$TIMEOUT"
  return 1
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀  demo-start  |  ${APP}  |  region: ${REGION}"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Ensure Aurora MinCapacity allows startup ───────────────────────────────
echo ""
echo "▶ 1/4  Aurora cluster  (${DB_CLUSTER_ID})"
DB_STATUS=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$DB_CLUSTER_ID" \
  --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "not-found")

if [ "$DB_STATUS" = "not-found" ]; then
  echo "  ✗ Aurora cluster not found — run ./deploy/provision-aws.sh first"
  exit 1
fi

# Ensure MinCapacity >= 0.5 so cluster can resume
aws_q aws rds modify-db-cluster --region "$REGION" \
  --db-cluster-identifier "$DB_CLUSTER_ID" \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2
echo "  ✓ MinCapacity set to 0.5  (status: ${DB_STATUS})"
detail "Aurora will resume on first connection (~15s if paused)"

# ── 2. Scale ECS service to 1 ─────────────────────────────────────────────────
echo ""
echo "▶ 2/4  ECS service  (${SERVICE})"
CURRENT_COUNT=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text 2>/dev/null || echo "0")

if [ "$CURRENT_COUNT" -ge 1 ] 2>/dev/null; then
  echo "  ✓ already running  (desired: ${CURRENT_COUNT})"
else
  aws_q aws ecs update-service --region "$REGION" \
    --cluster "$CLUSTER" --service "$SERVICE" --desired-count 1
  echo "  ✓ scaled to 1"
fi

# ── 3. Wait for service stability ─────────────────────────────────────────────
echo ""
echo "▶ 3/4  Waiting for service to become healthy"

spinner_wait \
  "aws ecs describe-services --region $REGION --cluster $CLUSTER --services $SERVICE --query 'services[0].runningCount' --output text" \
  "^1$" \
  "ECS task running" \
  180

# Get ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${APP}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")

if [ -z "$ALB_DNS" ]; then
  echo "  ✗ ALB not found — run ./deploy/provision-aws.sh first"
  exit 1
fi

spinner_wait \
  "curl -s -o /dev/null -w '%{http_code}' http://${ALB_DNS}/chord-diagram.html" \
  "^200$" \
  "ALB serving chord-diagram.html" \
  180

# ── 4. Pre-demo checklist ─────────────────────────────────────────────────────
echo ""
echo "▶ 4/4  Pre-demo checklist"
CHECKLIST="${DEMO_CHECKLIST:-$(dirname "$0")/demo-checklist.sh}"
"$CHECKLIST" --alb-dns "$ALB_DNS" ${SKIP_SEED:+--skip-seed}

# ── Summary ───────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TS ))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Demo ready  (${ELAPSED}s)"
echo ""
echo "  App:       http://${ALB_DNS}/chord-diagram.html"
echo "  API:       http://${ALB_DNS}/v1/records"
echo "  Logs:      aws logs tail /ecs/${APP} --region ${REGION} --follow"
echo ""
echo "  When done:"
echo "    ./deploy/demo-stop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
