resource "aws_db_subnet_group" "main" {
  name        = "${var.app}-subnet-group"
  description = "Subnet group for ${var.app} Aurora cluster"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${var.app}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version
  engine_mode        = "provisioned"

  database_name   = var.db_name
  master_username = var.db_username
  master_password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_sg_id]

  backup_retention_period   = var.backup_retention_days
  deletion_protection       = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.app}-aurora-final"
  apply_immediately         = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  tags = var.tags
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.app}-aurora-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  tags = var.tags
}
