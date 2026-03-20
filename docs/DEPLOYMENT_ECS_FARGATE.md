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
  - ECS task role (Bedrock invoke + Secrets Manager read)

## 2) Configure GitHub repository settings

Set these **Repository Variables**:

- `AWS_REGION` (example: `us-west-1`)
- `ECR_REPOSITORY` (example: `linkage-engine`)
- `ECS_CLUSTER` (example: `linkage-engine-cluster`)
- `ECS_SERVICE` (example: `linkage-engine-service`)

Set this **Repository Secret**:

- `AWS_DEPLOY_ROLE_ARN` (OIDC assumable role used by GitHub Actions)

## 3) Update task definition placeholders

Edit `deploy/ecs/task-definition.json`:

- Replace `<ACCOUNT_ID>` placeholders.
- Confirm `executionRoleArn` and `taskRoleArn`.
- Confirm Secrets Manager ARNs for:
  - `DB_URL`
  - `DB_USER`
  - `DB_PASSWORD`
- Adjust Bedrock/env values as needed.

## 4) Deploy

- Push changes to your branch.
- In GitHub Actions, run `deploy-ecr-ecs` via **Run workflow**.
- The workflow will:
  1. Build Docker image
  2. Push image to ECR
  3. Render task definition with pushed image tag
  4. Update ECS service and wait for stability

## 5) Notes

- SQL retrieval remains in PostgreSQL (wherever `DB_URL` points).
- Bedrock is used by the application for semantic summarization/embeddings, not as a database.
- For ALB health checks, add a lightweight non-LLM endpoint (for example `/health`) to avoid calling Bedrock on every probe.
