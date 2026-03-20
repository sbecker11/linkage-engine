# linkage-engine

A Java/Spring Boot service for **spatio-temporal data linkage** and **semantic record resolution** using Spring AI + PostgreSQL/pgvector.

Hybrid retrieval is implemented as:

1. **Deterministic SQL narrowing** on `records`
2. **Optional pgvector rerank** using Titan embeddings stored in `record_embeddings`
3. **Bedrock Converse** to produce the final `semanticSummary`

## Endpoints

1. `POST /v1/linkage/resolve`
2. `POST /v1/records` (upsert + optional embedding write)
3. `GET /api/ask` / `POST /api/dateTimeAtLocation` (chat-style endpoints)

See `docs/ARCHITECTURE.md` and `docs/README.md` for details.

## Local setup

### 1) Start Postgres + pgvector
```bash
docker run -d \
  --name pgvector-db \
  -e POSTGRES_USER=ancestry \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=linkage_db \
  -p 5432:5432 \
  ankane/pgvector
```

### 2) Environment variables
Create/adjust `.env` (repo root). The app supports:

Bedrock Converse chat:
```env
AWS_REGION=us-west-1
BEDROCK_MODEL_ID=us.amazon.nova-lite-v1:0
LINKAGE_SEMANTIC_LLM_ENABLED=true
```

Optional Titan embeddings + hybrid rerank/ingest:
```env
SPRING_AI_MODEL_EMBEDDING=bedrock-titan
BEDROCK_EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0
```

Postgres:
```env
DB_URL=jdbc:postgresql://localhost:5432/linkage_db
DB_USER=ancestry
DB_PASSWORD=password
```

### 3) Run
```bash
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
```

## Testing

```bash
./mvnw verify
```

## More documentation

- `docs/README.md`
- `docs/ARCHITECTURE.md`
- `docs/DEPLOYMENT_ECS_FARGATE.md`

