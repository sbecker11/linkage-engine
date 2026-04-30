# Bootstrap module tests
#
# Uses mock_provider so no real AWS credentials are required.
# Run from infra/bootstrap/:
#   terraform init
#   terraform test

mock_provider "aws" {}

variables {
  aws_region = "us-west-1"
  app        = "linkage-engine"
}

# ── S3 bucket ──────────────────────────────────────────────────────────────────

run "s3_bucket_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_s3_bucket.tfstate.bucket == "linkage-engine-tfstate"
    error_message = "S3 bucket must be named '<app>-tfstate', got: ${aws_s3_bucket.tfstate.bucket}"
  }
}

run "s3_versioning_is_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.tfstate.versioning_configuration[0].status == "Enabled"
    error_message = "S3 bucket versioning must be Enabled to protect state history."
  }
}

run "s3_encryption_uses_aes256" {
  command = plan

  assert {
    condition = (
      one(one(aws_s3_bucket_server_side_encryption_configuration.tfstate.rule)
      .apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    )
    error_message = "S3 bucket must use AES256 server-side encryption."
  }
}

run "s3_public_access_is_fully_blocked" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.block_public_acls == true
    error_message = "block_public_acls must be true."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.block_public_policy == true
    error_message = "block_public_policy must be true."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.ignore_public_acls == true
    error_message = "ignore_public_acls must be true."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.restrict_public_buckets == true
    error_message = "restrict_public_buckets must be true."
  }
}

run "s3_lifecycle_expires_old_noncurrent_versions" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.tfstate.rule).status == "Enabled"
    error_message = "Lifecycle rule must be Enabled."
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_lifecycle_configuration.tfstate.rule)
      .noncurrent_version_expiration).noncurrent_days == 90
    )
    error_message = "Old noncurrent versions must expire after 90 days."
  }
}

run "s3_bucket_tagged_correctly" {
  command = plan

  assert {
    condition     = aws_s3_bucket.tfstate.tags["App"] == "linkage-engine"
    error_message = "S3 bucket must have App tag set to var.app."
  }

  assert {
    condition     = aws_s3_bucket.tfstate.tags["ManagedBy"] == "terraform-bootstrap"
    error_message = "S3 bucket must have ManagedBy tag set to 'terraform-bootstrap'."
  }
}

# ── DynamoDB table ─────────────────────────────────────────────────────────────

run "dynamodb_table_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.tflock.name == "linkage-engine-tflock"
    error_message = "DynamoDB table must be named '<app>-tflock', got: ${aws_dynamodb_table.tflock.name}"
  }
}

run "dynamodb_uses_on_demand_billing" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.tflock.billing_mode == "PAY_PER_REQUEST"
    error_message = "DynamoDB table must use PAY_PER_REQUEST billing to avoid over-provisioning."
  }
}

run "dynamodb_hash_key_is_lockid" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.tflock.hash_key == "LockID"
    error_message = "DynamoDB hash key must be 'LockID' — required by Terraform state locking."
  }
}

run "dynamodb_tagged_correctly" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.tflock.tags["App"] == "linkage-engine"
    error_message = "DynamoDB table must have App tag set to var.app."
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────

run "outputs_match_resource_names" {
  command = plan

  assert {
    condition     = output.state_bucket == "linkage-engine-tfstate"
    error_message = "state_bucket output must equal the S3 bucket name."
  }

  assert {
    condition     = output.lock_table == "linkage-engine-tflock"
    error_message = "lock_table output must equal the DynamoDB table name."
  }

  assert {
    condition     = output.aws_region == "us-west-1"
    error_message = "aws_region output must reflect the variable value."
  }
}

# ── Variable validation ────────────────────────────────────────────────────────

run "custom_app_name_produces_correct_resource_names" {
  command = plan

  variables {
    app = "my-other-app"
  }

  assert {
    condition     = aws_s3_bucket.tfstate.bucket == "my-other-app-tfstate"
    error_message = "Bucket name must use the custom app variable."
  }

  assert {
    condition     = aws_dynamodb_table.tflock.name == "my-other-app-tflock"
    error_message = "DynamoDB table name must use the custom app variable."
  }
}
