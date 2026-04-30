# Aurora module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/aurora/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app        = "linkage-engine"
  db_sg_id   = "sg-00000000000000001"
  subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  db_password = "test-password-not-real"
  tags = {
    App = "linkage-engine"
    Env = "prod"
  }
}

run "cluster_identifier_follows_convention" {
  command = plan

  assert {
    condition     = aws_rds_cluster.main.cluster_identifier == "linkage-engine-aurora"
    error_message = "Aurora cluster identifier must be '<app>-aurora'."
  }
}

run "engine_is_aurora_postgresql" {
  command = plan

  assert {
    condition     = aws_rds_cluster.main.engine == "aurora-postgresql"
    error_message = "Engine must be aurora-postgresql."
  }
}

run "serverless_scaling_defaults_are_correct" {
  command = plan

  assert {
    condition     = aws_rds_cluster.main.serverlessv2_scaling_configuration[0].min_capacity == 0
    error_message = "Default min_capacity must be 0 (scales to zero when idle)."
  }

  assert {
    condition     = aws_rds_cluster.main.serverlessv2_scaling_configuration[0].max_capacity == 2
    error_message = "Default max_capacity must be 2 ACUs."
  }
}

run "backup_retention_is_seven_days" {
  command = plan

  assert {
    condition     = aws_rds_cluster.main.backup_retention_period == 7
    error_message = "Backup retention must be 7 days."
  }
}

run "cloudwatch_logs_export_is_enabled" {
  command = plan

  assert {
    condition     = contains(aws_rds_cluster.main.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "PostgreSQL logs must be exported to CloudWatch."
  }
}

run "db_name_and_username_defaults" {
  command = plan

  assert {
    condition     = aws_rds_cluster.main.database_name == "linkage_db"
    error_message = "Default database name must be 'linkage_db'."
  }

  assert {
    condition     = aws_rds_cluster.main.master_username == "ancestry"
    error_message = "Default master username must be 'ancestry'."
  }
}

run "writer_instance_uses_serverless_class" {
  command = plan

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.serverless"
    error_message = "Writer instance must use db.serverless class for Serverless v2."
  }
}

run "subnet_group_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_db_subnet_group.main.name == "linkage-engine-subnet-group"
    error_message = "DB subnet group name must be '<app>-subnet-group'."
  }
}

run "custom_capacity_is_respected" {
  command = plan

  variables {
    min_capacity = 0.5
    max_capacity = 8
  }

  assert {
    condition     = aws_rds_cluster.main.serverlessv2_scaling_configuration[0].min_capacity == 0.5
    error_message = "Custom min_capacity must be reflected in the cluster config."
  }

  assert {
    condition     = aws_rds_cluster.main.serverlessv2_scaling_configuration[0].max_capacity == 8
    error_message = "Custom max_capacity must be reflected in the cluster config."
  }
}
