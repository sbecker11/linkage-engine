#!/usr/bin/env bash
# deploy/show-month-to-date-cost.sh
#
# Prints current UTC calendar month-to-date UnblendedCost (USD) for resources
# matching a Cost Explorer tag filter — same idea as GET /v1/cost/month-to-date
# and the chord diagram cost line.
#
# Requires: AWS CLI v2, jq, Cost Explorer enabled, cost allocation tag activated
# for LINKAGE_COST_TAG_KEY (default: App).
#
# Usage:
#   ./deploy/show-month-to-date-cost.sh
#   APP=my-app ./deploy/show-month-to-date-cost.sh
#   LINKAGE_COST_TAG_KEY=App LINKAGE_COST_TAG_VALUE=linkage-engine ./deploy/show-month-to-date-cost.sh
#
# API region for Cost Explorer is always us-east-1 (override with COST_EXPLORER_REGION if needed).

set -euo pipefail

TAG_KEY="${LINKAGE_COST_TAG_KEY:-App}"
TAG_VALUE="${LINKAGE_COST_TAG_VALUE:-${APP:-linkage-engine}}"
CE_REGION="${COST_EXPLORER_REGION:-us-east-1}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found" >&2
  exit 1
fi

read -r START END <<<"$(python3 -c "
from datetime import datetime, timezone
n = datetime.now(timezone.utc)
s = n.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
if n.month == 12:
    e = datetime(n.year + 1, 1, 1, tzinfo=timezone.utc)
else:
    e = datetime(n.year, n.month + 1, 1, tzinfo=timezone.utc)
print(s.strftime('%Y-%m-%d'), e.strftime('%Y-%m-%d'))
")"

FILTER=$(jq -nc --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '{Tags: {Key: $k, Values: [$v]}}')

RESP=$(aws ce get-cost-and-usage \
  --region "$CE_REGION" \
  --time-period "Start=${START},End=${END}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter "$FILTER" \
  --output json)

AMT=$(echo "$RESP" | jq -r '
  [ .ResultsByTime[]?
    | .Total.UnblendedCost.Amount?
    | select(. != null and . != "")
    | tonumber
  ] | add // 0
')

printf '%s\n' "Month-to-date AWS cost (${TAG_KEY}=${TAG_VALUE}), UTC month [${START}, ${END}) UnblendedCost USD: $(printf '%.2f' "${AMT}")"
