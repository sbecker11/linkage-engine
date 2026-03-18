A Java-based engine for **Spatio-Temporal Data Linkage** and **Semantic Record Resolution**.

## Overview
Traditional databases struggle with the "fuzzy" nature of historical records. `linkage-engine` uses Hybrid Search (deterministic SQL filtering first, then probabilistic semantic/vector search) plus RAG to link disparate data points—like names, dates, and locations—into a cohesive individual profile.

See ARCHITECTURE.md for a detailed breakdown of the Semantic and Spatio-Temporal endpoints.

## Quick Start

### 1. Prerequisites
* **Java 21** (Required for Virtual Threads)
* **Docker** (For running PGVector locally)
* **OpenAI API Key** (Set as environment variable `OPENAI_API_KEY`)

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

### 4. Testing & Coverage
```bash
./mvnw test
./mvnw verify && open target/site/jacoco/index.html
```