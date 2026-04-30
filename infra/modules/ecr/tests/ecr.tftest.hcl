# ECR module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/ecr/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app = "linkage-engine"
  tags = {
    App       = "linkage-engine"
    ManagedBy = "terraform"
    Env       = "prod"
  }
}

run "repository_name_matches_app" {
  command = plan

  assert {
    condition     = aws_ecr_repository.main.name == "linkage-engine"
    error_message = "ECR repository name must equal var.app."
  }
}

run "scan_on_push_is_enabled" {
  command = plan

  assert {
    condition     = aws_ecr_repository.main.image_scanning_configuration[0].scan_on_push == true
    error_message = "scan_on_push must be true to catch vulnerabilities on every push."
  }
}

run "tags_are_applied" {
  command = plan

  assert {
    condition     = aws_ecr_repository.main.tags["App"] == "linkage-engine"
    error_message = "App tag must be set on the ECR repository."
  }

  assert {
    condition     = aws_ecr_repository.main.tags["ManagedBy"] == "terraform"
    error_message = "ManagedBy tag must be set on the ECR repository."
  }
}

run "lifecycle_policy_is_attached_to_repository" {
  command = plan

  assert {
    condition     = aws_ecr_lifecycle_policy.main.repository == aws_ecr_repository.main.name
    error_message = "Lifecycle policy must reference the ECR repository."
  }
}

run "outputs_are_set" {
  command = plan

  assert {
    condition     = output.repository_name == "linkage-engine"
    error_message = "repository_name output must equal var.app."
  }
}
