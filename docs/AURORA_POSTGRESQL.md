# Aurora PostgreSQL Serverless v2 — Provisioning Guide

This document covers provisioning an Aurora PostgreSQL Serverless v2 cluster with
`pgvector`, wiring it to ECS via Secrets Manager, and verifying Flyway migrations.

---

## 1. Provision the cluster (AWS CLI)

```bash
REGION=us-east-1
CLUSTER_ID=linkage-engine-aurora
DB_NAME=linkage_db
DB_USER=ancestry
DB_PASSWORD=$(openssl rand -base64 24)   # save this — you'll need it below

# Create the cluster
aws rds create-db-cluster \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --engine aurora-postgresql \
  --engine-version 16.13 \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
  --database-name "$DB_NAME" \
  --master-username "$DB_USER" \
  --master-user-password "$DB_PASSWORD" \
  --enable-http-endpoint \
  --no-deletion-protection

# Add a Serverless v2 writer instance
aws rds create-db-instance \
  --region "$REGION" \
  --db-instance-identifier "${CLUSTER_ID}-writer" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --db-instance-class db.serverless \
  --engine aurora-postgresql
```

Wait for the cluster to become available (~5 minutes):

```bash
aws rds wait db-cluster-available \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID"

# Get the writer endpoint
aws rds describe-db-clusters \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text
```

---

## 2. Enable pgvector

Connect to the writer endpoint and run once:

```bash
WRITER_ENDPOINT=$(aws rds describe-db-clusters \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text)

psql "postgresql://${DB_USER}:${DB_PASSWORD}@${WRITER_ENDPOINT}:5432/${DB_NAME}" \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Verify
psql "postgresql://${DB_USER}:${DB_PASSWORD}@${WRITER_ENDPOINT}:5432/${DB_NAME}" \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

Flyway migrations (`V1__init_linkage_schema.sql` through `V3__records_updated_at.sql`)
run automatically on first ECS deploy — they include `CREATE EXTENSION IF NOT EXISTS vector`
so the manual step above is a safety net only.

---

## 3. Store credentials in Secrets Manager

```bash
SECRET_NAME=linkage-engine/runtime

aws secretsmanager create-secret \
  --region "$REGION" \
  --name "$SECRET_NAME" \
  --description "linkage-engine runtime DB credentials (Aurora)" \
  --secret-string "{
    \"DB_URL\": \"jdbc:postgresql://${WRITER_ENDPOINT}:5432/${DB_NAME}\",
    \"DB_USER\": \"${DB_USER}\",
    \"DB_PASSWORD\": \"${DB_PASSWORD}\"
  }"
```

Retrieve the ARN for the ECS task definition:

```bash
aws secretsmanager describe-secret \
  --region "$REGION" \
  --secret-id "$SECRET_NAME" \
  --query 'ARN' --output text
```

---

## 4. Update ECS task definition

In `deploy/ecs/task-definition.json`, replace the `valueFrom` ARNs with the Aurora secret ARN:

```json
{
  "name": "DB_URL",
  "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:linkage-engine/runtime:DB_URL::"
},
{
  "name": "DB_USER",
  "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:linkage-engine/runtime:DB_USER::"
},
{
  "name": "DB_PASSWORD",
  "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:linkage-engine/runtime:DB_PASSWORD::"
}
```

The ECS task execution role must have:

```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:linkage-engine/runtime*"
}
```

See `deploy/iam/ecs-execution-role-secrets-statement.json`.

---

## 5. Verify after first ECS deploy

```bash
# Check Flyway migration status via actuator (if exposed internally)
curl http://<alb-dns>/actuator/flyway

# Or connect directly and check
psql "postgresql://${DB_USER}:${DB_PASSWORD}@${WRITER_ENDPOINT}:5432/${DB_NAME}" \
  -c "SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank;"
```

Expected output:
```
 version | description                        | success
---------+------------------------------------+---------
 1       | init linkage schema                | t
 2       | record embeddings titan v2         | t
 3       | records updated at                 | t
```

---

## 6. Smoke test against Aurora

```bash
ALB=https://your-alb-dns.us-east-1.elb.amazonaws.com

# Ingest a record
curl -X POST "$ALB/v1/records" \
  -H "Content-Type: application/json" \
  -d '{"recordId":"AURORA-001","givenName":"John","familyName":"Smith","eventYear":1850,"location":"Philadelphia"}'

# Resolve
curl -X POST "$ALB/v1/linkage/resolve" \
  -H "Content-Type: application/json" \
  -d '{"givenName":"John","familyName":"Smith","approxYear":1850,"location":"Philadelphia"}' \
  | python3 -m json.tool
```

---

## 7. Cost control

- **Min ACU 0.5, Max ACU 2**: the cluster scales to zero when idle (cluster pause enabled).
- Enable cluster pause:

```bash
aws rds modify-db-cluster \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --serverless-v2-scaling-configuration MinCapacity=0,MaxCapacity=2
```

- At 0 ACU the cluster pauses after ~5 minutes of inactivity; first connection after pause
  takes ~15 seconds to resume. Acceptable for a portfolio/demo workload.

---

## 8. Cluster pause vs always-on

| Mode | Cold start | Monthly cost (est.) | Use case |
| :--- | :--- | :--- | :--- |
| Min 0 ACU (pause) | ~15s | ~$0 idle | Portfolio / demo |
| Min 0.5 ACU | ~0s | ~$25 | Active development |
| Min 2 ACU | ~0s | ~$100 | Production |
