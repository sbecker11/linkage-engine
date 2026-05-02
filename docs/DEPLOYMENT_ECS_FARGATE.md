# ECS/Fargate Deployment

Linkage Engine runs on AWS ECS Fargate with Aurora PostgreSQL Serverless v2 and Bedrock for embeddings.

> **Infrastructure is now managed by Terraform.** See [`infra/README.md`](../infra/README.md)
> for the current provisioning workflow. The steps below describe the architecture;
> the old `deploy/provision-aws.sh` script has been superseded.

## Architecture

```
Internet
  │
  ▼
WAF WebACL  (rate-limit: 500 req/5min per IP)
  │
  ▼
Application Load Balancer  (port 80 HTTP / 443 HTTPS when domain configured)
  │
  ▼
ECS Fargate task  (linkage-engine container, port 8080)
  │         │
  │         └─► Amazon Bedrock  (nova-lite + titan-embed, via IAM task role)
  ▼
Aurora PostgreSQL Serverless v2  (linkage_db, pgvector)
  │
  └─► Secrets Manager  (DB_URL / DB_USER / DB_PASSWORD / INGEST_API_KEY injected at task start)
```

## Terraform Quick Start (replaces provision-aws.sh)

```bash
# Step 1 — Bootstrap remote state (once per AWS account)
cd infra/bootstrap
terraform init && terraform apply

# Step 2 — Copy backend_config output into infra/envs/prod/versions.tf
# (already done — bucket linkage-engine-tfstate)

# Step 3 — Configure variables
cd infra/envs/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set aws_account_id at minimum

# Step 4 — Import existing resources (first time only)
terraform init
bash ../../import.sh

# Step 5 — Apply
terraform plan    # verify no unintended changes
terraform apply   # creates/updates all resources

# Step 6 — Set GitHub secret
# Name:  AWS_DEPLOY_ROLE_ARN
# Value: (printed as deploy_role_arn output from terraform apply)

# Step 7 — Deploy via GitHub Actions
# GitHub → Actions → deploy-ecr-ecs → Run workflow
```

## Key Files

| File                                                   | Purpose                                                         |
| ------------------------------------------------------ | --------------------------------------------------------------- |
| `Dockerfile`                                           | Multi-stage build (Maven → JRE 21)                              |
| `infra/bootstrap/`                                     | Terraform — S3 state bucket + DynamoDB lock (run once)          |
| `infra/envs/prod/`                                     | Terraform — production root module (all resources)              |
| `infra/modules/`                                       | Terraform — reusable resource modules                           |
| `infra/import.sh`                                      | Import existing AWS resources into Terraform state              |
| `deploy/provision-aws.sh`                              | **ARCHIVED** — superseded by Terraform; kept for reference      |
| `deploy/ecs/task-definition.json`                      | **ARCHIVED** — task definition now owned by Terraform           |
| `deploy/ecs/service-definition.md`                     | ECS service configuration reference                             |
| `deploy/iam/ecs-execution-role-secrets-statement.json` | IAM policy fragment for execution role                          |
| `deploy/secrets/runtime-secret.json.example`           | Secrets Manager JSON body template                              |
| `.github/workflows/deploy-ecr-ecs.yml`                 | GitHub Actions deploy workflow (manual trigger)                 |
| `docs/SECRETS_MANAGER.md`                              | Secrets Manager patterns and IAM details                        |
| `docs/AURORA_POSTGRESQL.md`                            | Aurora Serverless v2 provisioning and pgvector setup            |


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


| Name                  | Value                               |
| --------------------- | ----------------------------------- |
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

## Every-change release checklist

Use this **three-step** path whenever you want production to match your repo with
minimal guesswork (you accept the extra time for `terraform plan` / `apply` and
for the GitHub Actions Docker build + ECS rollout).

**Order matters:** the workflow builds from **GitHub `main`**, not your
uncommitted local tree — **commit and push before** triggering the deploy.

### Step 1 — Terraform (production)

From the repo root:

```bash
cd infra/envs/prod
terraform init    # if providers/lockfile changed, or fresh clone
terraform plan
terraform apply   # when the plan is acceptable
```

Run this on **every** release while you prefer the discipline; `plan` on unchanged
infra is usually fast. Once you are comfortable skipping, you can run Terraform
only when `infra/` or `terraform.tfvars` actually changed (still run `plan`
occasionally to catch drift).

### Step 2 — Git (`main` on GitHub)

```bash
git status
git add … && git commit -m "…"   # when you have commits to make
git push origin main
```

### Step 3 — Deploy workflow and wait

**CLI** (same defaults as the workflow form in the Actions UI):

```bash
gh workflow run deploy-ecr-ecs.yml --ref main \
  -f aws_region=us-west-1 \
  -f ecr_repository=linkage-engine \
  -f ecs_cluster=linkage-engine-cluster \
  -f ecs_service=linkage-engine-service \
  -f task_family=linkage-engine

RUN_ID=$(gh run list --workflow=deploy-ecr-ecs.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status
```

**UI:** GitHub → **Actions** → **deploy-ecr-ecs** → **Run workflow** → keep the
default inputs (or match the `-f` flags above).

Most wall-clock time is usually **image build + push + ECS service stability**,
not Terraform.

### Step 4 — Verify (optional, quick)

```bash
ALB_DNS=$(terraform -chdir=infra/envs/prod output -raw alb_dns_name)
curl -sf "http://${ALB_DNS}/actuator/health" | head -c 300; echo
# Optional — month-to-date AWS cost (needs task env + IAM + Billing; see README)
curl -sf "http://${ALB_DNS}/v1/cost/month-to-date" | head -c 500; echo
curl -sf "http://${ALB_DNS}/v1/cost/month-to-date/page" | head -c 200; echo
```

**ALB DNS via AWS CLI** (when you have credentials but are not using Terraform
outputs — same load balancer as `terraform output -raw alb_dns_name`):

```bash
aws elbv2 describe-load-balancers --region us-west-1 --names linkage-engine-alb \
  --query 'LoadBalancers[0].DNSName' --output text
```

### One-time AWS Billing (not part of every deploy)

For **Cost Explorer** and the in-app / API month-to-date cost line: enable Cost
Explorer in the Billing console and activate your cost allocation tag (e.g.
**`App`**) once per account. Re-doing this on every deploy does not change
anything.

---

## Subsequent deploys

After the [Every-change release checklist](#every-change-release-checklist) is
routine, the **minimum** path for an **app-only** change is: **push `main` → run
`deploy-ecr-ecs`** (Terraform unchanged). When `infra/` changes, include **Step
1** again.

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

## Demo Lifecycle — Start / Stop

Use these scripts to bring cost to near-zero between demos and commission the
stack quickly before a live session.

```bash
# Shut down all billable compute (~$0 within 5 minutes)
./deploy/demo-stop.sh

# Commission for a demo (typically ready in 3–5 minutes)
./deploy/demo-start.sh

# Verify health before going live (runs automatically inside demo-start.sh)
./deploy/demo-checklist.sh
```

### Estimated warm-up time


| Step                               | Duration     | Notes                                                         |
| ---------------------------------- | ------------ | ------------------------------------------------------------- |
| ECS task scheduled                 | 0 s          | Fargate picks up the desired-count change immediately         |
| Container image pulled             | ~10–20 s     | Cached in ECR; faster on subsequent starts                    |
| Aurora resumes from pause          | ~15 s        | Only if `MinCapacity=0` and cluster was idle >5 min           |
| Spring Boot starts                 | ~15 s        | Flyway migration check runs here                              |
| ALB health check passes            | ~30 s        | `/actuator/health` polled every 10 s with 2 healthy threshold |
| **Total (cold start)**             | **~3–5 min** | From `demo-start.sh` invocation to first HTTP 200             |
| **Total (warm — ECS was running)** | **~30 s**    | Aurora already active, container already running              |


### What stays running (and costs money) while stopped


| Resource                | Monthly cost (approx)                           |
| ----------------------- | ----------------------------------------------- |
| ALB                     | ~$0.19/day — kept running to avoid DNS TTL wait |
| ECR image storage       | ~$0.10/GB/month                                 |
| Secrets Manager         | $0.40/secret/month                              |
| S3, CloudWatch logs     | Storage cost only                               |
| **Total while stopped** | **< $10/month**                                 |


---

## Notes

- **Bedrock** is called via the IAM task role (default credential chain) — no API keys needed.
- **Flyway** migrations run automatically on first ECS task start.
- **ALB health check** hits `/actuator/health` — a lightweight Spring Boot endpoint that does not invoke Bedrock.
- **Aurora cold start**: with `MinCapacity=0` the cluster pauses after ~5 min of inactivity; first connection after pause takes ~15 s. Acceptable for a portfolio/demo workload.
- **HTTPS**: the ALB is HTTP-only. To add HTTPS, provision an ACM certificate and add an HTTPS listener (port 443) pointing to the same target group.
- See `docs/AURORA_POSTGRESQL.md` for Aurora-specific details (pgvector, cost control, cluster pause).
- See `docs/SECRETS_MANAGER.md` for Secrets Manager patterns and rotation.

