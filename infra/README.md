# linkage-engine — Terraform Infrastructure

Terraform IaC for the production ECS Fargate environment. Replaces `deploy/provision-aws.sh`.

## Prerequisites

- [Terraform >= 1.9](https://developer.hashicorp.com/terraform/install)
- AWS CLI v2 configured (`aws sts get-caller-identity` must succeed)
- Sufficient IAM permissions (AdministratorAccess or equivalent)

## Directory Structure

```
infra/
├── bootstrap/        # ONE-TIME: create S3 state bucket + DynamoDB lock table
├── modules/          # Reusable resource modules (added in Phase 2)
│   ├── ecr/
│   ├── networking/
│   ├── aurora/
│   ├── secrets/
│   ├── iam/
│   ├── alb/
│   ├── acm/
│   ├── waf/
│   ├── ecs/
│   └── monitoring/
└── envs/
    └── prod/         # Production environment root (added in Phase 2)
```

## Quick Start

### Step 1 — Bootstrap (run once per AWS account)

```bash
cd infra/bootstrap
terraform init
terraform apply
```

Copy the `backend_config` output into `infra/envs/prod/versions.tf`.

### Step 2 — Deploy production (after Phase 2 modules exist)

```bash
cd infra/envs/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — fill in aws_region, domain_name, alert_email
terraform init
terraform plan
terraform apply
```

### Step 3 — Import existing resources (first time only)

```bash
cd infra/envs/prod
bash ../../import.sh
terraform plan   # should show no changes after successful import
```

## Running Tests

Each module has a `tests/` subdirectory with `.tftest.hcl` files. Tests use mock
providers and require no real AWS credentials.

```bash
# Test the bootstrap module
cd infra/bootstrap
terraform init
terraform test

# Test any other module (once modules exist)
cd infra/modules/ecr
terraform init
terraform test
```

## Local Development

Adding Terraform has **no effect on local development**. The Spring Boot app is still
run with:

```bash
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
```

See the project root `README.md` for local dev setup instructions.
