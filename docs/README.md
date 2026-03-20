A Java-based engine for **Spatio-Temporal Data Linkage** and **Semantic Record Resolution**.

## Overview
Traditional databases struggle with the "fuzzy" nature of historical records. `linkage-engine` uses Hybrid Search (deterministic SQL filtering first, then probabilistic semantic/vector search) plus RAG to link disparate data points—like names, dates, and locations—into a cohesive individual profile.

See ARCHITECTURE.md for a detailed breakdown of the Semantic and Spatio-Temporal endpoints.
For deployment bootstrap on AWS, see `DEPLOYMENT_ECS_FARGATE.md`.

**Data pipeline standard:** raw bulk source files live in **S3**; linkage and search use **PostgreSQL** after ingest. Conventions, IAM, and local vs AWS access are documented in **`DATA_PIPELINE_S3.md`**.

## Quick Start

### 1. Prerequisites
* **Java 21** (Required for Virtual Threads)
* **Docker** (For running PGVector locally)
* **AWS credentials** (default profile, SSO session, or IAM role)
* **Amazon Bedrock model access** in your target region

### 2. Infrastructure Setup
Run the following to start a PostgreSQL instance with the `pgvector` extension:
```bash
docker run -d \
  --name pgvector-db \
  -e POSTGRES_USER=ancestry \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=linkage_db \
  -p 5432:5432 \
  ankane/pgvector
```

### 3. Installation
```bash
./mvnw clean install
./mvnw spring-boot:run
```

### 4. Bedrock Configuration
Set runtime values in your project `.env`:
```env
AWS_REGION=us-west-1
BEDROCK_MODEL_ID=us.amazon.nova-lite-v1:0
```

Optional **hybrid vector rerank + ingest embeddings** (Amazon Titan Embed Text v2, 1024-dim; matches Flyway `V2`):
```env
SPRING_AI_MODEL_EMBEDDING=bedrock-titan
BEDROCK_EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0
```

Database (defaults match Docker example below):
```env
DB_URL=jdbc:postgresql://localhost:5432/linkage_db
DB_USER=ancestry
DB_PASSWORD=password
```

S3 landing zone (standard for raw exports; used by ingest tooling — see `DATA_PIPELINE_S3.md`):
```env
LINKAGE_S3_BUCKET=your-org-linkage-landing
LINKAGE_S3_PREFIX=landing/
```

Run without AWS (Postgres still required for `/v1/linkage` + `/v1/records` when JDBC is enabled):
```bash
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
```

Notes:
* `BEDROCK_MODEL_ID` should be an **inference profile ID** for your account/region (for example `us.amazon.nova-lite-v1:0`), not a base model ID.
* The app uses the AWS SDK default credential provider chain, so credentials should come from your AWS profile/session or IAM role.
* **Ingest:** `POST /v1/records` upserts into `records` and, when embeddings are enabled, writes Titan vectors to `record_embeddings`. Bulk raw files should follow the **S3 landing → ingest** standard in `DATA_PIPELINE_S3.md`.
* **Resolve:** `POST /v1/linkage/resolve` narrows with SQL, then (if embeddings exist for those rows) reranks by cosine similarity; response includes `candidateScores[].vectorSimilarity`.

Verify your AWS setup before starting the app:
```bash
aws sts get-caller-identity
aws bedrock list-inference-profiles --region us-west-1 --output table
```

### 5. Testing & Coverage
```bash
./mvnw test
./mvnw verify && open target/site/jacoco/index.html
```