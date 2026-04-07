#!/usr/bin/env bash
# demo/seed-data.sh
# Ingests 8 pre-crafted records that cover all demo scenarios.
# Run with the app already started: ./mvnw spring-boot:run -Dspring-boot.run.profiles=local

set -euo pipefail

BASE="${LINKAGE_BASE_URL:-http://localhost:8080}"
POST() { curl -sf -X POST "$BASE/v1/records" -H "Content-Type: application/json" -d "$1" && echo " ✓ $2" || echo " ✗ $2 (failed)"; }

echo "=== Seeding demo records ==="

# ── Plausible match pair: Philadelphia → New York, 1850 → 1851 ────────────────
POST '{"recordId":"DEMO-001","givenName":"John","familyName":"Smith","eventYear":1850,"location":"Philadelphia","rawContent":"John Smith, Philadelphia, 1850 — city directory"}' "DEMO-001 John Smith Philadelphia 1850"
POST '{"recordId":"DEMO-002","givenName":"John","familyName":"Smith","eventYear":1851,"location":"New York","rawContent":"John Smith, New York, 1851 — census record"}' "DEMO-002 John Smith New York 1851"

# ── Impossible match: Boston → San Francisco, same month ─────────────────────
POST '{"recordId":"DEMO-003","givenName":"John","familyName":"Smith","eventYear":1850,"location":"Boston","rawContent":"John Smith, Boston, January 1850 — ship manifest"}' "DEMO-003 John Smith Boston Jan 1850"
POST '{"recordId":"DEMO-004","givenName":"John","familyName":"Smith","eventYear":1850,"location":"San Francisco","rawContent":"John Smith, San Francisco, February 1850 — land deed"}' "DEMO-004 John Smith San Francisco Feb 1850"

# ── Dirty record: OCR noise + city abbreviation ───────────────────────────────
POST '{"recordId":"DEMO-005","givenName":"John","familyName":"Smith","eventYear":1850,"location":"Philadelphia","rawContent":"John Smith, Philly, 18S0 — baptism register (OCR scan)"}' "DEMO-005 John Smith dirty record (18S0, Philly)"

# ── Neighbourhood snapshot records: Philadelphia cluster ─────────────────────
POST '{"recordId":"DEMO-006","givenName":"Mary","familyName":"Jones","eventYear":1849,"location":"Philadelphia","rawContent":"Mary Jones, Philadelphia, 1849 — marriage record"}' "DEMO-006 Mary Jones Philadelphia 1849"
POST '{"recordId":"DEMO-007","givenName":"William","familyName":"Brown","eventYear":1850,"location":"Philadelphia","rawContent":"William Brown, Philadelphia, 1850 — tax record"}' "DEMO-007 William Brown Philadelphia 1850"
POST '{"recordId":"DEMO-008","givenName":"Sarah","familyName":"Smith","eventYear":1851,"location":"Philadelphia","rawContent":"Sarah Smith, Philadelphia, 1851 — death record"}' "DEMO-008 Sarah Smith Philadelphia 1851"

echo ""
echo "=== Seed complete: 8 records ingested ==="
