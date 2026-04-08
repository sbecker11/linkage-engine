# ECS/Fargate Deployment

Linkage Engine runs on AWS ECS Fargate with Aurora PostgreSQL Serverless v2 and Bedrock for embeddings.

## Architecture

```
Internet
  │
  ▼
Application Load Balancer  (port 80 → HTTP)
  │
  ▼
ECS Fargate task  (linkage-engine container, port 8080)
  │         │
  │         └─► Amazon Bedrock  (nova-lite + titan-embed, via IAM task role)
  ▼
Aurora PostgreSQL Serverless v2  (linkage_db, pgvector)
  │
  └─► Secrets Manager  (DB_URL / DB_USER / DB_PASSWORD injected at task start)
```

## Files

| File | Purpose |
| :--- | :--- |
| `Dockerfile` | Multi-stage build (Maven → JRE 21) |
| `deploy/provision-aws.sh` | **One-shot** provisioning script — run once before first deploy |
| `deploy/ecs/task-definition.json` | ECS task definition template (updated by provision script) |
| `deploy/ecs/service-definition.md` | ECS service configuration reference |
| `deploy/iam/ecs-execution-role-secrets-statement.json` | IAM policy fragment for execution role |
| `deploy/secrets/runtime-secret.json.example` | Secrets Manager JSON body template |
| `.github/workflows/deploy-ecr-ecs.yml` | GitHub Actions deploy workflow (manual trigger) |
| `docs/SECRETS_MANAGER.md` | Secrets Manager patterns and IAM details |
| `docs/AURORA_POSTGRESQL.md` | Aurora Serverless v2 provisioning and pgvector setup |

---

## Step 1 — Run the provisioning script (once)

```bash
cd /path/to/linkage-engine
./deploy/provision-aws.sh
```

The script provisions (idempotent — safe to re-run):

1. **ECR repository** `linkage-engine`
2. **CloudWatch log group** `/ecs/linkage-engine` (30-day retention)
3. **Security groups** — ALB, ECS task, Aurora (least-privilege ingress rules)
4. **Aurora PostgreSQL Serverless v2** cluster `linkage-engine-aurora` (scales to 0 when idle)
5. **Secrets Manager** secret `linkage-engine/runtime` with `DB_URL`, `DB_USER`, `DB_PASSWORD`
6. **IAM roles**
   - `linkage-engine-execution-role` — ECR pull + CloudWatch logs + Secrets Manager read
   - `linkage-engine-task-role` — Bedrock `InvokeModel` permissions
7. **ECS cluster** `linkage-engine-cluster`
8. **ALB** `linkage-engine-alb` + target group + HTTP listener (port 80)
9. **ECS service** `linkage-engine-service` (1 task, Fargate, wired to ALB)
10. **OIDC deploy role** `linkage-engine-github-deploy-role` for GitHub Actions

At the end the script prints:

```
  Next steps:
  1. Add this GitHub repository secret:
     AWS_DEPLOY_ROLE_ARN = arn:aws:iam::286103606369:role/linkage-engine-github-deploy-role

  2. Run the deploy workflow:
     GitHub → Actions → deploy-ecr-ecs → Run workflow

  3. After first deploy, seed the database:
     BASE_URL=http://<alb-dns> ./demo/seed-data.sh

  4. Open the chord diagram:
     http://<alb-dns>/chord-diagram.html
```

---

## Step 2 — Add GitHub repository secret

In your GitHub repository → **Settings → Secrets and variables → Actions → New repository secret**:

| Name | Value |
| :--- | :--- |
| `AWS_DEPLOY_ROLE_ARN` | ARN printed by the provision script |

---

## Step 3 — Deploy via GitHub Actions

1. Push your branch (or use `main`).
2. Go to **GitHub → Actions → deploy-ecr-ecs → Run workflow**.
3. Accept the defaults (region `us-west-1`, repo `linkage-engine`, cluster `linkage-engine-cluster`, service `linkage-engine-service`) or override per run.

The workflow:
1. Assumes the OIDC role (no long-lived AWS keys in GitHub)
2. Builds the Docker image and pushes to ECR
3. Renders the task definition with the new image tag
4. Registers the task definition and updates the ECS service
5. Waits for service stability

---

## Step 4 — Verify

```bash
ALB=http://$(aws elbv2 describe-load-balancers \
  --region us-west-1 --names linkage-engine-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

# Health check
curl "$ALB/actuator/health"

# Flyway migration status
curl "$ALB/actuator/flyway"

# Ingest a test record
curl -X POST "$ALB/v1/records" \
  -H "Content-Type: application/json" \
  -d '{"recordId":"SMOKE-001","givenName":"John","familyName":"Smith","eventYear":1850,"location":"Philadelphia"}'

# Open the chord diagram
open "$ALB/chord-diagram.html"
```

---

## Subsequent deploys

Just push to `main` and re-run the **deploy-ecr-ecs** workflow. No re-provisioning needed.

To force a re-deploy without a code change (e.g. to pick up a new secret value):

```bash
aws ecs update-service \
  --region us-west-1 \
  --cluster linkage-engine-cluster \
  --service linkage-engine-service \
  --force-new-deployment
```

---

## Tear down

```bash
# Stop the service
aws ecs update-service --region us-west-1 \
  --cluster linkage-engine-cluster --service linkage-engine-service --desired-count 0

# Delete in reverse order of creation
aws ecs delete-service --region us-west-1 \
  --cluster linkage-engine-cluster --service linkage-engine-service --force
aws ecs delete-cluster --region us-west-1 --cluster linkage-engine-cluster
aws elbv2 delete-load-balancer --region us-west-1 \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --region us-west-1 --names linkage-engine-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws rds delete-db-instance --region us-west-1 \
  --db-instance-identifier linkage-engine-aurora-writer --skip-final-snapshot
aws rds delete-db-cluster --region us-west-1 \
  --db-cluster-identifier linkage-engine-aurora --skip-final-snapshot
aws secretsmanager delete-secret --region us-west-1 \
  --secret-id linkage-engine/runtime --force-delete-without-recovery
```

---

## Notes

- **Bedrock** is called via the IAM task role (default credential chain) — no API keys needed.
- **Flyway** migrations run automatically on first ECS task start.
- **ALB health check** hits `/actuator/health` — a lightweight Spring Boot endpoint that does not invoke Bedrock.
- **Aurora cold start**: with `MinCapacity=0` the cluster pauses after ~5 min of inactivity; first connection after pause takes ~15 s. Acceptable for a portfolio/demo workload.
- **HTTPS**: the ALB is HTTP-only. To add HTTPS, provision an ACM certificate and add an HTTPS listener (port 443) pointing to the same target group.
- See `docs/AURORA_POSTGRESQL.md` for Aurora-specific details (pgvector, cost control, cluster pause).
- See `docs/SECRETS_MANAGER.md` for Secrets Manager patterns and rotation.
