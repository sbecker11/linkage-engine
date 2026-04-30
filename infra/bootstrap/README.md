# Bootstrap — Terraform Remote State

Creates the S3 bucket and DynamoDB table that hold Terraform remote state for all
other `infra/` modules. This module itself uses **local state** (stored on disk) and
is run **once per AWS account**, typically by a platform engineer with admin access.

## Resources Created

| Resource | Name | Purpose |
|---|---|---|
| `aws_s3_bucket` | `linkage-engine-tfstate` | Stores all `.tfstate` files |
| `aws_s3_bucket_versioning` | — | Protects state history (90-day noncurrent expiry) |
| `aws_s3_bucket_server_side_encryption_configuration` | — | AES-256 encryption at rest |
| `aws_s3_bucket_public_access_block` | — | All public access blocked |
| `aws_s3_bucket_lifecycle_configuration` | — | Expires old noncurrent versions after 90 days |
| `aws_dynamodb_table` | `linkage-engine-tflock` | Prevents concurrent `terraform apply` runs |

## Usage

```bash
cd infra/bootstrap

# Download the AWS provider plugin (no remote backend configured here)
terraform init

# Preview what will be created
terraform plan

# Create the resources (takes ~10 seconds)
terraform apply
```

After apply, copy the printed `backend_config` output into
`infra/envs/prod/versions.tf` to enable remote state for the production environment.

## Running Tests

Tests use a mock AWS provider — no credentials required.

```bash
cd infra/bootstrap
terraform init
terraform test
```

Expected output:

```
bootstrap.tftest.hcl... in progress
  run "s3_bucket_name_follows_convention"... pass
  run "s3_versioning_is_enabled"... pass
  run "s3_encryption_uses_aes256"... pass
  run "s3_public_access_is_fully_blocked"... pass
  run "s3_lifecycle_expires_old_noncurrent_versions"... pass
  run "s3_bucket_tagged_correctly"... pass
  run "dynamodb_table_name_follows_convention"... pass
  run "dynamodb_uses_on_demand_billing"... pass
  run "dynamodb_hash_key_is_lockid"... pass
  run "dynamodb_tagged_correctly"... pass
  run "outputs_match_resource_names"... pass
  run "custom_app_name_produces_correct_resource_names"... pass
bootstrap.tftest.hcl... tearing down
bootstrap.tftest.hcl... pass

Success! 12 passed, 0 failed.
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-west-1` | AWS region for state resources |
| `app` | `linkage-engine` | Prefix for resource names |

## Notes

- The S3 bucket has `prevent_destroy = true`. To delete it you must first remove
  that lifecycle block and run `terraform apply`, then `terraform destroy`.
- The local `.terraform/` directory and `terraform.tfstate` created here are
  gitignored. Keep the local state file safe — losing it means you would need to
  manually import the S3 bucket and DynamoDB table if you ever need to recreate
  the bootstrap resources.
- Re-running `terraform apply` is safe (idempotent).
