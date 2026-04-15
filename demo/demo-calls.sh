#!/usr/bin/env bash
# demo/demo-calls.sh
# Runs the full linkage-engine demo story end-to-end.
# Requires: app running (./mvnw spring-boot:run -Dspring-boot.run.profiles=local)
#           jq installed (brew install jq) — falls back to python3 -m json.tool

set -euo pipefail

BASE="${BASE_URL:-${LINKAGE_BASE_URL:-http://localhost:8080}}"
PRETTY() {
    if command -v jq &>/dev/null; then jq '.'; else python3 -m json.tool; fi
}
SECTION() { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ── 0. Seed records ────────────────────────────────────────────────────────────
SECTION "0. Seeding demo records"
"$(dirname "$0")/seed-data.sh"

# ── 1. Plausible match: Philadelphia → New York ────────────────────────────────
SECTION "1. Resolve plausible match — John Smith, Philadelphia 1850 → New York 1851"
echo "   Expected: high confidenceScore, spatioTemporalResult.plausible=true, railroad_eastern"
curl -sf -X POST "$BASE/v1/linkage/resolve" \
  -H "Content-Type: application/json" \
  -d '{"givenName":"John","familyName":"Smith","approxYear":1850,"location":"Philadelphia"}' \
  | PRETTY

# ── 2. Impossible match: Boston → San Francisco, same month ───────────────────
SECTION "2. Resolve impossible match — John Smith, Boston → San Francisco (1-month window)"
echo "   Expected: reduced confidenceScore, spatioTemporalResult.plausible=false, ocean_ship"
curl -sf -X POST "$BASE/v1/linkage/resolve" \
  -H "Content-Type: application/json" \
  -d '{"givenName":"John","familyName":"Smith","approxYear":1850,"location":"Boston"}' \
  | PRETTY

# ── 3. Direct spatio-temporal check ───────────────────────────────────────────
SECTION "3. Direct spatio-temporal — Boston → San Francisco, Jan → Feb 1850 (30 days)"
echo "   Expected: plausible=false, ocean_ship, travelDays≈120, confidenceAdjustment=50"
curl -sf -X POST "$BASE/v1/spatial/temporal-overlap" \
  -H "Content-Type: application/json" \
  -d '{
    "from": {"recordId":"DEMO-003","location":"Boston","year":1850,"month":1},
    "to":   {"recordId":"DEMO-004","location":"San Francisco","year":1850,"month":2}
  }' | PRETTY

SECTION "3b. Direct spatio-temporal — Philadelphia → New York, 1850 → 1851"
echo "   Expected: plausible=true, railroad_eastern, travelDays<1, margin≈364"
curl -sf -X POST "$BASE/v1/spatial/temporal-overlap" \
  -H "Content-Type: application/json" \
  -d '{
    "from": {"recordId":"DEMO-001","location":"Philadelphia","year":1850},
    "to":   {"recordId":"DEMO-002","location":"New York","year":1851}
  }' | PRETTY

# ── 4. Semantic search ─────────────────────────────────────────────────────────
SECTION "4. Semantic search — 'smith philadelphia census'"
echo "   Expected: localProfile=true on local profile (no embeddings); results when Bedrock active"
curl -sf "$BASE/v1/search/semantic?q=smith+philadelphia+census&maxResults=5&minScore=0.5" \
  | PRETTY

# ── 5. Neighbourhood snapshot ─────────────────────────────────────────────────
SECTION "5. Neighbourhood snapshot — Philadelphia, 1850"
echo "   Expected: recordCount≥3, commonNames includes 'John Smith', yearRangeMin≤1849"
curl -sf "$BASE/v1/context/neighborhood-snapshot?location=Philadelphia&year=1850" \
  | PRETTY

# ── 6. Delta reindex (Bedrock profile only) ───────────────────────────────────
SECTION "6. Delta reindex (expects 409 on local profile — embedding model not configured)"
echo "   Expected: 409 Conflict with error message on local profile"
curl -sf -o /dev/null -w "HTTP %{http_code}\n" -X PUT "$BASE/v1/vectors/reindex" || true
curl -s -X PUT "$BASE/v1/vectors/reindex" | PRETTY || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Demo complete."
echo "  To run with Bedrock: set SPRING_AI_MODEL_EMBEDDING=bedrock-titan"
echo "  and LINKAGE_SEMANTIC_LLM_ENABLED=true in .env, then restart."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
