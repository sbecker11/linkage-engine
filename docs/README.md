A Java-based engine for **Spatio-Temporal Data Linkage** and **Semantic Record Resolution**.

## Overview
Traditional databases struggle with the "fuzzy" nature of historical records. `linkage-engine` uses Hybrid Search (deterministic SQL filtering first, then probabilistic semantic/vector search) plus RAG to link disparate data points—like names, dates, and locations—into a cohesive individual profile.

See ARCHITECTURE.md for a detailed breakdown of the Semantic and Spatio-Temporal endpoints.

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

Notes:
* `BEDROCK_MODEL_ID` should be an **inference profile ID** for your account/region (for example `us.amazon.nova-lite-v1:0`), not a base model ID.
* The app uses the AWS SDK default credential provider chain, so credentials should come from your AWS profile/session or IAM role.

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