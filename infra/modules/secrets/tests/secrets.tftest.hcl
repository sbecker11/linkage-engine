# Secrets module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/secrets/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app            = "linkage-engine"
  db_url         = "jdbc:postgresql://test-host:5432/linkage_db"
  db_username    = "ancestry"
  db_password    = "test-password-not-real"
  ingest_api_key = "test-api-key-not-real"
  tags = {
    App = "linkage-engine"
    Env = "prod"
  }
}

run "secret_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.runtime.name == "linkage-engine/runtime"
    error_message = "Secret name must be '<app>/runtime'."
  }
}

run "secret_has_description" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.runtime.description == "linkage-engine runtime credentials"
    error_message = "Secret must have a descriptive description field."
  }
}

run "secret_is_tagged" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.runtime.tags["App"] == "linkage-engine"
    error_message = "Secret must carry the App tag."
  }
}

run "secret_version_contains_all_required_keys" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.runtime.secret_string)["DB_URL"]
      == "jdbc:postgresql://test-host:5432/linkage_db"
    )
    error_message = "secret_string must contain DB_URL."
  }

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.runtime.secret_string)["DB_USER"]
      == "ancestry"
    )
    error_message = "secret_string must contain DB_USER."
  }

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.runtime.secret_string)["INGEST_API_KEY"]
      == "test-api-key-not-real"
    )
    error_message = "secret_string must contain INGEST_API_KEY."
  }
}

run "output_secret_name_matches_resource" {
  command = plan

  assert {
    condition     = output.secret_name == "linkage-engine/runtime"
    error_message = "secret_name output must match the secret resource name."
  }
}
