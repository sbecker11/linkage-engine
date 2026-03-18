# The Linkage-Engine

### The Problem
"Genealogical data is messy. Traditional exact-match logic fails when names change, dates are approximate, or records are sparse—so you need a way to reason under uncertainty, not just return ranked results."

### The Solution
`linkage-engine` is a Spring Boot service that combines LLM-based interpretation with vector embeddings to connect related records (names, dates, locations, and documents). The goal is to produce a **confidence-oriented** narrative and supporting context for suggested matches.

### In Progress
- LLM-backed query handling for interpreting user inputs and generating time/location-aware context.
- Application scaffolding: startup configuration (including `.env` loading) and basic OpenAI integration.
- Vector-store/RAG pipeline is being prepared; current configuration can keep PGVector disabled until the database is set up.

### Next Steps
- Enable PGVector-backed retrieval (embeddings + search) to ground answers in your stored records.
- Implement hybrid search: start with deterministic, SQL-driven queries to minimize the candidate set, then run a probabilistic semantic search over those candidates for fine-tuning.
- Implement the core “linkage engine” workflows: entity resolution and spatio-temporal plausibility validation.
- Add ingestion/updating flows and improve tests/docs as functionality expands.
