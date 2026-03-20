# ECS/Fargate Deployment (Phase 1)

This project now includes starter assets for ECS/Fargate deployment:

- `Dockerfile`
- `.github/workflows/deploy-ecr-ecs.yml`
- `deploy/ecs/task-definition.json`
- `deploy/ecs/service-definition.md`

## 1) AWS prerequisites

- Existing VPC with private subnets for ECS tasks
- Application Load Balancer and target group
- RDS PostgreSQL (or Aurora PostgreSQL) reachable from ECS subnets
- ECR repository (for example `linkage-engine`)
- CloudWatch log group `/ecs/linkage-engine`
- IAM roles:
  - ECS task execution role (ECR pull + logs)
  - ECS task role (Bedrock invoke + Secrets Manager read + **S3 read** on landing prefix if batch ingest runs in ECS)
- **S3 landing bucket** (optional but standard for raw data): create a bucket and prefix per `docs/DATA_PIPELINE_S3.md`; grant the task role `s3:ListBucket` / `s3:GetObject` on that prefix.

## 2) Configure GitHub repository settings

Set these **Repository Variables**:

- `AWS_REGION` (example: `us-west-1`)
- `ECR_REPOSITORY` (example: `linkage-engine`)
- `ECS_CLUSTER` (example: `linkage-engine-cluster`)
- `ECS_SERVICE` (example: `linkage-engine-service`)

Set this **Repository Secret**:

- `AWS_DEPLOY_ROLE_ARN` (OIDC assumable role used by GitHub Actions)

## 3) Verify ECS task definition

Edit `deploy/ecs/task-definition.json` as needed:

- Confirm `executionRoleArn` and `taskRoleArn` match your account.
- Confirm Secrets Manager ARNs for `DB_URL`, `DB_USER`, `DB_PASSWORD`.
- Adjust Bedrock/env values as needed.
- Optional: add plain `environment` entries for `LINKAGE_S3_BUCKET` and `LINKAGE_S3_PREFIX` when ingest runs in ECS (see `docs/DATA_PIPELINE_S3.md`).

## 4) Deploy

- Push changes to your branch.
- In GitHub Actions, run `deploy-ecr-ecs` via **Run workflow**.
- The workflow assumes **only** the IAM role in the **`AWS_DEPLOY_ROLE_ARN` repository secret** — it does not accept a role ARN from the UI (prevents privilege escalation via arbitrary roles).
- The workflow will:
  1. Build Docker image
  2. Push image to ECR
  3. Render task definition with pushed image tag
  4. Update ECS service and wait for stability

## 5) Notes

- SQL retrieval remains in PostgreSQL (wherever `DB_URL` points).
- Bedrock is used by the application for semantic summarization/embeddings, not as a database.
- For ALB health checks, add a lightweight non-LLM endpoint (for example `/health`) to avoid calling Bedrock on every probe.
- Raw data standard: `docs/DATA_PIPELINE_S3.md` (S3 landing → PostgreSQL; Bedrock does not replace the database).
