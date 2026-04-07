# The Linkage Engine — Elevator Pitch

### The Problem
Genealogical data is messy. Traditional exact-match logic fails when names change
spelling across records, dates are approximate, locations are abbreviated, and OCR
introduces digit/letter swaps. You need a system that reasons under uncertainty —
not just returns ranked results.

### The Solution
`linkage-engine` is a Java 21 / Spring Boot service that combines deterministic SQL
narrowing, pgvector cosine reranking, LLM semantic summarisation, and historical
spatio-temporal plausibility validation into a single four-stage hybrid RAG pipeline.
Every stage degrades gracefully — the full pipeline runs locally with no AWS
credentials.

### What Was Built

| Stage | Component | What it does |
| :--- | :--- | :--- |
| 1 | `LinkageRecordRepository` | SQL narrowing — name LIKE, ±5-year window, location filter |
| 2 | `VectorRerankService` | Cosine rerank via Bedrock Titan embeddings (skipped locally) |
| 3 | `SemanticSummaryService` | LLM narrative via Bedrock Converse (echo response locally) |
| 4 | `ConflictResolver` | Historical transit plausibility — `ConflictRule` chain |

**Ingestion pipeline** — `POST /v1/records` runs raw text through a `CleansingProvider`
chain (`OCRNoiseReducer`, `LocationStandardizer`), upserts into PostgreSQL, and
optionally embeds chunks into `record_embeddings` via Titan.

**Spatio-temporal validation** — `HistoricalTransitService` selects the fastest
era-appropriate travel mode (horse/coach, eastern railroad, transcontinental rail,
ocean ship) and computes minimum travel days via haversine distance. Three
`ConflictRule` implementations fire penalties: `PhysicalImpossibilityRule`,
`BiologicalPlausibilityRule`, `NarrowMarginRule`. A fourth —
`GenderPlausibilityRule` — is planned, using SSA name-frequency data from 1880
onward to infer gender and penalise cross-gender candidate pairs.

**Chord diagram UI** — `chord-diagram.html` (served as a Spring Boot static resource
at `/chord-diagram.html`) visualises all seeded records as a D3.js directed chord
diagram. Chord width reflects similarity score; chord colour reflects the
travel-time margin ratio across a 5-tier scale (green → blue → purple → amber → red).

### Design Patterns
- **`ObjectProvider` over `@ConditionalOnBean`** — runtime null-checks are
  predictable regardless of Spring context assembly order
- **Chain of Responsibility** — both `CleansingProvider` and `ConflictRule` chains
  accept new steps as single-file additions with zero orchestrator changes
- **Profile-gated graceful degradation** — local profile runs all four stages
  end-to-end without AWS credentials; each stage has a defined fallback

### Infrastructure
- **Local** — Docker PostgreSQL + pgvector on port 5434, `local` Spring profile
- **Production** — ECS Fargate, Aurora PostgreSQL Serverless v2 (min 0.5 ACU,
  cluster pause), Bedrock Titan + Converse, Secrets Manager for DB credentials,
  S3 landing zone for raw bulk ingest
