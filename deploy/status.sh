#!/usr/bin/env bash
# status.sh — show run status of all linkage-engine components
# Usage: ./deploy/status.sh [--watch]

set -euo pipefail

REGION="${AWS_REGION:-us-west-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names linkage-engine-alb \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
LANDING_BUCKET="linkage-engine-landing-${ACCOUNT}"
RAW_BUCKET="linkage-engine-raw-${ACCOUNT}"
WATCH=false

for arg in "$@"; do
  [[ "$arg" == "--watch" ]] && WATCH=true
done

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; RESET="\033[0m"
ok()   { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
fail() { echo -e "  ${RED}✗${RESET}  $*"; }

icon() {
  local val="$1" want="$2"
  [[ "$val" == "$want" ]] && echo -e "${GREEN}✓${RESET}" || echo -e "${RED}✗${RESET}"
}

# ── single pass ───────────────────────────────────────────────────────────────
run_check() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  linkage-engine status  —  $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ── ECS ──────────────────────────────────────────────────────────────────────
  echo ""
  echo "▶  ECS Fargate"
  ECS=$(aws ecs describe-services --region "$REGION" \
    --cluster linkage-engine-cluster \
    --services linkage-engine-service \
    --query 'services[0].{running:runningCount,desired:desiredCount,pending:pendingCount,taskDef:taskDefinition,status:status}' \
    --output json 2>/dev/null || echo "{}")
  RUNNING=$(echo "$ECS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('running','?'))" 2>/dev/null)
  DESIRED=$(echo "$ECS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('desired','?'))" 2>/dev/null)
  TASKDEF=$(echo "$ECS" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('taskDef','?'); print(t.split('/')[-1] if t else '?')" 2>/dev/null)
  ECS_STATUS=$(echo "$ECS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
  if [[ "$RUNNING" == "$DESIRED" && "$RUNNING" != "0" ]]; then
    ok "running=${RUNNING}/${DESIRED}  task-def=${TASKDEF}  status=${ECS_STATUS}"
  else
    fail "running=${RUNNING}/${DESIRED}  task-def=${TASKDEF}  status=${ECS_STATUS}"
  fi

  # ── Aurora ───────────────────────────────────────────────────────────────────
  echo ""
  echo "▶  Aurora PostgreSQL"
  DB=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier linkage-engine-aurora \
    --query 'DBClusters[0].{status:Status,engine:EngineVersion,minACU:ServerlessV2ScalingConfiguration.MinCapacity,maxACU:ServerlessV2ScalingConfiguration.MaxCapacity}' \
    --output json 2>/dev/null || echo "{}")
  DB_STATUS=$(echo "$DB" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
  DB_ENGINE=$(echo "$DB" | python3 -c "import sys,json; print(json.load(sys.stdin).get('engine','?'))" 2>/dev/null)
  DB_MIN=$(echo "$DB"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('minACU','?'))" 2>/dev/null)
  DB_MAX=$(echo "$DB"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('maxACU','?'))" 2>/dev/null)
  if [[ "$DB_STATUS" == "available" ]]; then
    ok "status=${DB_STATUS}  engine=${DB_ENGINE}  ACU=${DB_MIN}–${DB_MAX}"
  else
    warn "status=${DB_STATUS}  engine=${DB_ENGINE}  ACU=${DB_MIN}–${DB_MAX}"
  fi

  # ── ALB ──────────────────────────────────────────────────────────────────────
  echo ""
  echo "▶  ALB"
  ALB_STATE=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --names linkage-engine-alb \
    --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "unknown")
  if [[ "$ALB_STATE" == "active" ]]; then
    ok "state=${ALB_STATE}  dns=${ALB_DNS}"
  else
    fail "state=${ALB_STATE}"
  fi

  # ── Spring Boot health ───────────────────────────────────────────────────────
  echo ""
  echo "▶  Spring Boot  (http://${ALB_DNS})"
  if [[ -n "$ALB_DNS" ]]; then
    HEALTH_JSON=$(curl -s --max-time 6 "http://${ALB_DNS}/actuator/health" 2>/dev/null || echo "{}")
    APP_STATUS=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unreachable'))" 2>/dev/null || echo "unreachable")
    DB_COMP=$(echo "$HEALTH_JSON"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('components',{}).get('db',{}).get('status','?'))" 2>/dev/null || echo "?")
    if [[ "$APP_STATUS" == "UP" ]]; then
      ok "/actuator/health → ${APP_STATUS}  (db=${DB_COMP})"
    else
      fail "/actuator/health → ${APP_STATUS}"
    fi

    INGEST_JSON=$(curl -s --max-time 6 "http://${ALB_DNS}/v1/ingest/health" 2>/dev/null || echo "{}")
    INGEST_STATUS=$(echo "$INGEST_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unreachable'))" 2>/dev/null || echo "unreachable")
    GAPS=$(echo "$INGEST_JSON"          | python3 -c "import sys,json; print(json.load(sys.stdin).get('embeddingGapCount','?'))" 2>/dev/null || echo "?")
    FLYWAY=$(echo "$INGEST_JSON"        | python3 -c "import sys,json; print(json.load(sys.stdin).get('flywayStatus','?'))" 2>/dev/null || echo "?")
    BATCH=$(echo "$INGEST_JSON"         | python3 -c "import sys,json; print(json.load(sys.stdin).get('lastBatchSize','?'))" 2>/dev/null || echo "?")
    RATE=$(echo "$INGEST_JSON"          | python3 -c "import sys,json; print(json.load(sys.stdin).get('ingestRatePerMin','?'))" 2>/dev/null || echo "?")
    if [[ "$INGEST_STATUS" == "ok" ]]; then
      ok "/v1/ingest/health → ${INGEST_STATUS}  flyway=${FLYWAY}  gaps=${GAPS}  lastBatch=${BATCH}  rate=${RATE}/min"
    else
      warn "/v1/ingest/health → ${INGEST_STATUS}  flyway=${FLYWAY}  gaps=${GAPS}"
    fi
  else
    warn "ALB DNS not found — skipping HTTP checks"
  fi

  # ── Lambdas ──────────────────────────────────────────────────────────────────
  echo ""
  echo "▶  Lambda functions  (invocations / errors — last 24h)"
  SINCE=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for fn in linkage-engine-ingestor linkage-engine-validate linkage-engine-store; do
    INV=$(aws cloudwatch get-metric-statistics --region "$REGION" \
      --namespace AWS/Lambda --metric-name Invocations \
      --dimensions Name=FunctionName,Value="$fn" \
      --start-time "$SINCE" --end-time "$NOW" \
      --period 86400 --statistics Sum \
      --query 'Datapoints[0].Sum' --output text 2>/dev/null)
    ERR=$(aws cloudwatch get-metric-statistics --region "$REGION" \
      --namespace AWS/Lambda --metric-name Errors \
      --dimensions Name=FunctionName,Value="$fn" \
      --start-time "$SINCE" --end-time "$NOW" \
      --period 86400 --statistics Sum \
      --query 'Datapoints[0].Sum' --output text 2>/dev/null)
    INV="${INV:-0}"; INV="${INV/None/0}"
    ERR="${ERR:-0}"; ERR="${ERR/None/0}"
    ERR_INT=$(python3 -c "print(int(float('${ERR}')))" 2>/dev/null || echo 0)
    LABEL=$(printf '%-35s' "$fn")
    if [[ "$ERR_INT" -gt 0 ]]; then
      fail "${LABEL}  invocations=${INV}  errors=${ERR}"
    else
      ok  "${LABEL}  invocations=${INV}  errors=${ERR}"
    fi
  done

  # ── S3 buckets ───────────────────────────────────────────────────────────────
  echo ""
  echo "▶  S3 buckets"
  for bucket in "$LANDING_BUCKET" "$RAW_BUCKET"; do
    COUNT=$(aws s3 ls "s3://${bucket}/" --region "$REGION" --recursive 2>/dev/null | wc -l | tr -d ' ')
    PREFIXES=$(aws s3 ls "s3://${bucket}/" --region "$REGION" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')
    ok "${bucket}  objects=${COUNT}  prefixes=${PREFIXES:-none}"
  done

  # ── CloudWatch alarms ────────────────────────────────────────────────────────
  echo ""
  echo "▶  CloudWatch alarms"
  ALARMS=$(aws cloudwatch describe-alarms --region "$REGION" \
    --alarm-name-prefix "le-" \
    --query 'MetricAlarms[*].{name:AlarmName,state:StateValue}' \
    --output json 2>/dev/null || echo "[]")
  echo "$ALARMS" | python3 -c "
import sys, json
alarms = json.load(sys.stdin)
for a in alarms:
    state = a['state']
    icon  = '\033[0;32m✓\033[0m' if state == 'OK' else '\033[0;31m✗\033[0m'
    print(f'  {icon}  {a[\"name\"]:<40} {state}')
" 2>/dev/null || warn "could not fetch alarms"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Dashboard: https://us-west-1.console.aws.amazon.com/cloudwatch/home?region=us-west-1#dashboards/dashboard/linkage-engine-ops"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
if $WATCH; then
  while true; do
    clear
    run_check
    echo "  (refreshing every 30s — Ctrl-C to stop)"
    sleep 30
  done
else
  run_check
fi
