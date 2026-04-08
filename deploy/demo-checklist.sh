#!/usr/bin/env bash
# deploy/demo-checklist.sh
#
# Pre-demo health verification. Checks:
#   1. ALB is serving chord-diagram.html (HTTP 200)
#   2. /v1/records returns at least one record
#   3. /v1/linkage/resolve returns a valid response
#   4. Bedrock is reachable (semantic summary present in resolve response)
#   5. Seed data is present (DEMO-A through DEMO-L exist)
#
# Usage:
#   ./deploy/demo-checklist.sh                              # auto-detect ALB
#   ./deploy/demo-checklist.sh --alb-dns <dns>             # explicit ALB DNS
#   ./deploy/demo-checklist.sh --skip-seed                 # skip seed data check

set -euo pipefail

REGION="${AWS_REGION:-us-west-1}"
APP=linkage-engine
ALB_DNS=""
SKIP_SEED=false
PASS=0
FAIL=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --alb-dns)   ALB_DNS="$2"; shift 2 ;;
    --skip-seed) SKIP_SEED=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Auto-detect ALB DNS if not provided
if [ -z "$ALB_DNS" ]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --names "${APP}-alb" \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
  if [ -z "$ALB_DNS" ]; then
    echo "  ✗ ALB not found — run ./deploy/provision-aws.sh first"
    exit 1
  fi
fi

BASE="http://${ALB_DNS}"

check() {
  local LABEL="$1" RESULT="$2" DETAIL="${3:-}"
  if [ "$RESULT" = "pass" ]; then
    echo "  ✓ ${LABEL}"
    [ -n "$DETAIL" ] && echo "    ${DETAIL}"
    PASS=$(( PASS + 1 ))
  else
    echo "  ✗ ${LABEL}"
    [ -n "$DETAIL" ] && echo "    ${DETAIL}"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo ""
echo "  Pre-demo checklist  →  ${BASE}"
echo ""

# 1. chord-diagram.html
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/chord-diagram.html" 2>/dev/null || echo "000")
[ "$STATUS" = "200" ] && check "chord-diagram.html" "pass" "HTTP ${STATUS}" \
                       || check "chord-diagram.html" "fail" "HTTP ${STATUS} (expected 200)"

# 2. /v1/records returns records
RECORDS=$(curl -s "${BASE}/v1/records" 2>/dev/null || echo "[]")
COUNT=$(echo "$RECORDS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
[ "$COUNT" -gt 0 ] && check "/v1/records has data" "pass" "${COUNT} records" \
                    || check "/v1/records has data" "fail" "0 records — run demo/seed-data.sh"

# 3. /v1/linkage/resolve returns a response
RESOLVE=$(curl -s -X POST "${BASE}/v1/linkage/resolve" \
  -H "Content-Type: application/json" \
  -d '{"givenName":"John","familyName":"Smith","approxYear":1850,"location":"Boston"}' \
  2>/dev/null || echo "{}")
HAS_STRATEGY=$(echo "$RESOLVE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('strategy') else 'no')" 2>/dev/null || echo "no")
[ "$HAS_STRATEGY" = "yes" ] && check "/v1/linkage/resolve responds" "pass" \
                              || check "/v1/linkage/resolve responds" "fail" "no 'strategy' field in response"

# 4. Bedrock semantic summary present
HAS_SUMMARY=$(echo "$RESOLVE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('semanticSummary') else 'no')" 2>/dev/null || echo "no")
[ "$HAS_SUMMARY" = "yes" ] && check "Bedrock semantic summary" "pass" \
                             || check "Bedrock semantic summary" "fail" "semanticSummary missing — check Bedrock IAM permissions"

# 5. Seed data present (DEMO-A and DEMO-B)
if [ "$SKIP_SEED" = "false" ]; then
  ALL_IDS=$(echo "$RECORDS" | python3 -c "import sys,json; [print(r['recordId']) for r in json.load(sys.stdin)]" 2>/dev/null || echo "")
  HAS_DEMO_A=$(echo "$ALL_IDS" | grep -c "^DEMO-A$" || echo "0")
  HAS_DEMO_B=$(echo "$ALL_IDS" | grep -c "^DEMO-B$" || echo "0")
  if [ "$HAS_DEMO_A" -ge 1 ] && [ "$HAS_DEMO_B" -ge 1 ]; then
    check "Seed data present (DEMO-A/B)" "pass"
  else
    check "Seed data present (DEMO-A/B)" "fail" \
      "Run: BASE_URL=${BASE} ./demo/seed-data.sh"
  fi
else
  echo "  — seed data check skipped"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
TOTAL=$(( PASS + FAIL ))
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅  All ${TOTAL} checks passed — ready for demo"
  exit 0
else
  echo "  ⚠️   ${FAIL}/${TOTAL} checks failed — address issues above before demo"
  exit 1
fi
