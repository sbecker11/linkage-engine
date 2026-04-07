# Demo Scripts

## Quick start

```bash
# 1. Start the app
set -a && source ../.env && set +a
cd .. && ./mvnw spring-boot:run -Dspring-boot.run.profiles=local &

# 2. Wait for startup, then run the full demo
./demo-calls.sh
```

## What the demo shows

| Step | Scenario | Key assertion |
| :--- | :--- | :--- |
| 1 | John Smith, Philadelphia 1850 → New York 1851 | `plausible=true`, `railroad_eastern`, high confidence |
| 2 | John Smith, Boston → San Francisco (same month) | `plausible=false`, `ocean_ship`, reduced confidence |
| 3 | Direct spatio-temporal endpoint | Raw `SpatioTemporalResponse` with full audit trail |
| 4 | Semantic search | `localProfile=true` on local; real results with Bedrock |
| 5 | Neighbourhood snapshot, Philadelphia 1850 | Aggregated `recordCount`, `commonNames`, `contextSummary` |
| 6 | Delta reindex | `409` on local (no embedding model); success on Bedrock profile |

## Dirty record cleansing (Step 1 / DEMO-005)

Record `DEMO-005` is ingested with `rawContent: "John Smith, Philly, 18S0"`.
The cleansing chain transforms it before embedding:
- `OCRNoiseReducer`: `18S0` → `1850`
- `LocationStandardizer`: `Philly` → `Philadelphia`

Confirm via the app log:
```
[OCRNoiseReducer] '18S0' → '1850'
[LocationStandardizer] 'Philly' → 'Philadelphia'
```

## Bedrock profile

Set in `.env`:
```env
SPRING_AI_MODEL_EMBEDDING=bedrock-titan
BEDROCK_EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0
LINKAGE_SEMANTIC_LLM_ENABLED=true
BEDROCK_MODEL_ID=us.amazon.nova-lite-v1:0
```

Then restart and re-run `demo-calls.sh`. Steps 4 and 6 will return real results.
