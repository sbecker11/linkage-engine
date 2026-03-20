# ECS/Fargate Deployment (Phase 1)

This project now includes starter assets for ECS/Fargate deployment:

- `Dockerfile`
- `.github/workflows/deploy-ecr-ecs.yml` (manual trigger; region/ECR/ECS via inputs with defaults; OIDC role from repository secret `AWS_DEPLOY_ROLE_ARN` only)
- `deploy/ecs/task-definition.json` (runtime **DB_* from AWS Secrets Manager** — not from GitHub)
- `deploy/ecs/service-definition.md`
- **`docs/SECRETS_MANAGER.md`** — how to create secrets, IAM, and ECS `valueFrom` format
- `deploy/secrets/runtime-secret.json.example` — JSON body for the recommended single runtime secret
- `deploy/iam/ecs-execution-role-secrets-statement.json` — attach to **ECS task execution role**

## 1) AWS prerequisites

- Existing VPC with private subnets for ECS tasks
- Application Load Balancer and target group
- RDS PostgreSQL (or Aurora PostgreSQL) reachable from ECS subnets
- ECR repository (for example `linkage-engine`)
- CloudWatch log group `/ecs/linkage-engine`
- IAM roles:
  - ECS task execution role (ECR pull + logs)
  - ECS task role (Bedrock invoke + **S3 read** on landing prefix if batch ingest runs in ECS; runtime DB secrets are injected by the execution role, not read by the app from SM at runtime)
- **S3 landing bucket** (optional but standard for raw data): create a bucket and prefix per `docs/DATA_PIPELINE_S3.md`; grant the task role `s3:ListBucket` / `s3:GetObject` on that prefix.

## 2) Configure GitHub repository settings

Optional **Repository Variables** (for documentation or other workflows only — the deploy workflow uses **workflow_dispatch defaults**; override per run in the Actions UI if needed):

- `AWS_REGION` (example: `us-west-1`)
- `ECR_REPOSITORY` (example: `linkage-engine`)
- `ECS_CLUSTER` (example: `linkage-engine-cluster`)
- `ECS_SERVICE` (example: `linkage-engine-service`)

Set this **Repository Secret**:

- `AWS_DEPLOY_ROLE_ARN` (OIDC assumable role used by GitHub Actions)

## 3) Create runtime secrets (AWS Secrets Manager)

**Do not** put `DB_URL`, `DB_USER`, or `DB_PASSWORD` in GitHub Secrets for the running service — store them in **Secrets Manager** and let ECS inject them at task start.

1. Follow **`docs/SECRETS_MANAGER.md`** and `deploy/ecs/README.md`.
2. Create the JSON secret (example: `linkage-engine/runtime`) using `deploy/secrets/runtime-secret.json.example` as a template.
3. Grant the **ECS task execution role** permission to read that secret (`deploy/iam/ecs-execution-role-secrets-statement.json`).

## 4) Verify ECS task definition

Edit `deploy/ecs/task-definition.json` as needed:

- Confirm `executionRoleArn` and `taskRoleArn` match your account.
- Replace Secrets Manager `valueFrom` ARNs for `DB_URL`, `DB_USER`, `DB_PASSWORD` with your real ARNs + JSON keys (see `deploy/ecs/README.md`).
- Adjust Bedrock `environment` entries as needed (non-secret model IDs / flags).
- Optional: add plain `environment` entries for `LINKAGE_S3_BUCKET` and `LINKAGE_S3_PREFIX` when ingest runs in ECS (see `docs/DATA_PIPELINE_S3.md`).

## 5) Deploy

- Push changes to your branch.
- In GitHub Actions, run `deploy-ecr-ecs` via **Run workflow**.
- The deploy job assumes **only** the IAM role in the **`AWS_DEPLOY_ROLE_ARN` repository secret**. It is **not** a workflow input (prevents privilege escalation).
- The workflow will:
  1. Build Docker image
  2. Push image to ECR
  3. Render task definition with pushed image tag
  4. Update ECS service and wait for stability

## 6) Notes

- SQL retrieval remains in PostgreSQL (wherever `DB_URL` points).
- Bedrock is used by the application for semantic summarization/embeddings, not as a database.
- For ALB health checks, add a lightweight non-LLM endpoint (for example `/health`) to avoid calling Bedrock on every probe.
- Raw data standard: `docs/DATA_PIPELINE_S3.md` (S3 landing → PostgreSQL; Bedrock does not replace the database).
