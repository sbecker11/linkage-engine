resource "aws_ecs_cluster" "main" {
  name = "${var.app}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]
}


resource "aws_ecs_task_definition" "main" {
  family                   = var.app
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = var.app
      image     = var.ecr_image_uri
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "AWS_REGION",                  value = var.aws_region },
        { name = "SPRING_PROFILES_ACTIVE",       value = "bedrock" },
        { name = "BEDROCK_MODEL_ID",             value = var.bedrock_model_id },
        { name = "SPRING_AI_MODEL_EMBEDDING",    value = "bedrock-titan" },
        { name = "BEDROCK_EMBEDDING_MODEL_ID",   value = var.bedrock_embedding_model_id },
        { name = "LINKAGE_SEMANTIC_LLM_ENABLED", value = tostring(var.semantic_llm_enabled) },
        { name = "LINKAGE_COST_ENABLED",       value = "true" },
        { name = "LINKAGE_COST_TAG_KEY",       value = "App" },
        { name = "LINKAGE_COST_TAG_VALUE",     value = var.app }
      ]

      secrets = [
        { name = "DB_URL",         valueFrom = "${var.secret_arn}:DB_URL::" },
        { name = "DB_USER",        valueFrom = "${var.secret_arn}:DB_USER::" },
        { name = "DB_PASSWORD",    valueFrom = "${var.secret_arn}:DB_PASSWORD::" },
        { name = "INGEST_API_KEY", valueFrom = "${var.secret_arn}:INGEST_API_KEY::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "main" {
  name                               = "${var.app}-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.main.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.app
    container_port   = var.container_port
  }

  # Allow external deploys (via GitHub Actions terraform apply) to update the
  # task definition without Terraform treating it as drift.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = var.tags
}
