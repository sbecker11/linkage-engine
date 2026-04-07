#!/usr/bin/env bash
# demo/seed-data.sh
# Ingests 10 records designed to exercise every ConflictRule and chord colour.
#
# Colour map:
#   Green  — plausible, comfortable margin          (DEMO-A ↔ DEMO-B)
#   Blue   — plausible, moderate margin             (DEMO-C ↔ DEMO-D)
#   Amber  — plausible, narrow margin               (DEMO-E ↔ DEMO-F)
#   Red    — PhysicalImpossibilityRule               (DEMO-G ↔ DEMO-H)
#   Cherry — AgeConsistencyRule (birth-year clash)  (DEMO-I ↔ DEMO-J)
#   Magenta— GenderPlausibilityRule (M vs F name)   (DEMO-K ↔ DEMO-L)
#
# Run with the app already started:
#   ./mvnw spring-boot:run -Dspring-boot.run.profiles=local

set -euo pipefail

BASE="${LINKAGE_BASE_URL:-http://localhost:8080}"
POST() {
  curl -sf -X POST "$BASE/v1/records" \
    -H "Content-Type: application/json" \
    -d "$1" \
  && echo " ✓ $2" \
  || echo " ✗ $2 (failed)"
}

echo "=== Seeding demo records ==="

# ── DEMO-A / DEMO-B : Plausible, comfortable margin (→ green chord) ──────────
# Philadelphia → New York, 1 year apart; same birth year → age consistent
POST '{"recordId":"DEMO-A","givenName":"John","familyName":"Smith","eventYear":1850,"birthYear":1820,"location":"Philadelphia","rawContent":"John Smith, Philadelphia, 1850 — city directory"}' \
     "DEMO-A  John Smith  Philadelphia 1850  born 1820"
POST '{"recordId":"DEMO-B","givenName":"John","familyName":"Smith","eventYear":1851,"birthYear":1820,"location":"New York","rawContent":"John Smith, New York, 1851 — census record"}' \
     "DEMO-B  John Smith  New York     1851  born 1820"

# ── DEMO-C / DEMO-D : Plausible, moderate margin (→ blue chord) ──────────────
# Philadelphia → Boston, 2 years apart; same birth year
POST '{"recordId":"DEMO-C","givenName":"James","familyName":"Brown","eventYear":1848,"birthYear":1815,"location":"Philadelphia","rawContent":"James Brown, Philadelphia, 1848 — tax record"}' \
     "DEMO-C  James Brown Philadelphia 1848  born 1815"
POST '{"recordId":"DEMO-D","givenName":"James","familyName":"Brown","eventYear":1850,"birthYear":1815,"location":"Boston","rawContent":"James Brown, Boston, 1850 — ship manifest"}' \
     "DEMO-D  James Brown Boston       1850  born 1815"

# ── DEMO-E / DEMO-F : Plausible, narrow margin (→ amber chord) ───────────────
# Boston → New York, 1 month apart; same birth year
POST '{"recordId":"DEMO-E","givenName":"William","familyName":"Davis","eventYear":1852,"birthYear":1822,"location":"Boston","rawContent":"William Davis, Boston, March 1852 — church register"}' \
     "DEMO-E  William Davis  Boston    1852  born 1822"
POST '{"recordId":"DEMO-F","givenName":"William","familyName":"Davis","eventYear":1852,"birthYear":1822,"location":"New York","rawContent":"William Davis, New York, April 1852 — hotel register"}' \
     "DEMO-F  William Davis  New York  1852  born 1822"

# ── DEMO-G / DEMO-H : Physical impossibility (→ red chord) ───────────────────
# Boston → San Francisco, 1 month apart — Cape Horn takes ~150 days
POST '{"recordId":"DEMO-G","givenName":"John","familyName":"Smith","eventYear":1850,"birthYear":1820,"location":"Boston","rawContent":"John Smith, Boston, January 1850 — ship manifest"}' \
     "DEMO-G  John Smith  Boston        Jan 1850  born 1820"
POST '{"recordId":"DEMO-H","givenName":"John","familyName":"Smith","eventYear":1850,"birthYear":1820,"location":"San Francisco","rawContent":"John Smith, San Francisco, February 1850 — land deed"}' \
     "DEMO-H  John Smith  San Francisco Feb 1850  born 1820"

# ── DEMO-I / DEMO-J : Age contradiction (→ cherry chord) ─────────────────────
# Same given+family name, same location, consecutive years —
# but birth years are 40 years apart → |ageA − ageB| >> |yearDelta| + 5
POST '{"recordId":"DEMO-I","givenName":"Thomas","familyName":"Wilson","eventYear":1850,"birthYear":1820,"location":"Philadelphia","rawContent":"Thomas Wilson, Philadelphia, 1850 — voter registration"}' \
     "DEMO-I  Thomas Wilson  Philadelphia 1850  born 1820  (age 30)"
POST '{"recordId":"DEMO-J","givenName":"Thomas","familyName":"Wilson","eventYear":1851,"birthYear":1780,"location":"Philadelphia","rawContent":"Thomas Wilson, Philadelphia, 1851 — probate record"}' \
     "DEMO-J  Thomas Wilson  Philadelphia 1851  born 1780  (age 71)"

# ── DEMO-K / DEMO-L : Gender conflict, same city (→ magenta chord) ───────────
# "Mary" (female) vs "Robert" (male) — same family name, same city, same year
POST '{"recordId":"DEMO-K","givenName":"Mary","familyName":"Taylor","eventYear":1850,"birthYear":1825,"location":"Philadelphia","rawContent":"Mary Taylor, Philadelphia, 1850 — marriage record"}' \
     "DEMO-K  Mary Taylor    Philadelphia 1850  born 1825  (female)"
POST '{"recordId":"DEMO-L","givenName":"Robert","familyName":"Taylor","eventYear":1851,"birthYear":1825,"location":"Philadelphia","rawContent":"Robert Taylor, Philadelphia, 1851 — city directory"}' \
     "DEMO-L  Robert Taylor  Philadelphia 1851  born 1825  (male)"

# ── DEMO-M / DEMO-N : Travel + gender conflict (→ travel + magenta layers) ───
# Elizabeth Harris departs Boston 1850; William Harris arrives New York 1851.
# Plausible travel (Boston→NY, 1 year) but female→male name at journey endpoints
# → travel colour layer + magenta gender-conflict layer stacked on the chord.
POST '{"recordId":"DEMO-M","givenName":"Elizabeth","familyName":"Harris","eventYear":1850,"birthYear":1828,"location":"Boston","rawContent":"Elizabeth Harris, Boston, 1850 — passenger list"}' \
     "DEMO-M  Elizabeth Harris  Boston    1850  born 1828  (female, departure)"
POST '{"recordId":"DEMO-N","givenName":"William","familyName":"Harris","eventYear":1851,"birthYear":1828,"location":"New York","rawContent":"William Harris, New York, 1851 — census record"}' \
     "DEMO-N  William Harris    New York  1851  born 1828  (male, arrival)"

echo ""
echo "=== Seed complete: 14 records ingested ==="
echo ""
echo "Expected chord colours:"
echo "  Green        — DEMO-A ↔ DEMO-B  (plausible, comfortable)"
echo "  Blue         — DEMO-C ↔ DEMO-D  (plausible, moderate)"
echo "  Amber        — DEMO-E ↔ DEMO-F  (plausible, narrow margin)"
echo "  Red          — DEMO-G ↔ DEMO-H  (physical impossibility)"
echo "  Cherry       — DEMO-I ↔ DEMO-J  (age contradiction)"
echo "  Magenta      — DEMO-K ↔ DEMO-L  (gender conflict, same city)"
echo "  Green+Magenta— DEMO-M ↔ DEMO-N  (plausible travel + gender conflict)"
