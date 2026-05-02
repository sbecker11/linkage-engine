# ECS module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/ecs/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app                = "linkage-engine"
  aws_region         = "us-west-1"
  execution_role_arn = "arn:aws:iam::286103606369:role/linkage-engine-execution-role"
  task_role_arn      = "arn:aws:iam::286103606369:role/linkage-engine-task-role"
  secret_arn         = "arn:aws:secretsmanager:us-west-1:286103606369:secret:linkage-engine/runtime-test"
  ecr_image_uri      = "286103606369.dkr.ecr.us-west-1.amazonaws.com/linkage-engine:sha-abc123"
  ecs_sg_id          = "sg-00000000000000001"
  subnet_ids         = ["subnet-00000000000000001", "subnet-00000000000000002"]
  target_group_arn   = "arn:aws:elasticloadbalancing:us-west-1:286103606369:targetgroup/linkage-engine-tg/test"
}

run "cluster_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.main.name == "linkage-engine-cluster"
    error_message = "ECS cluster name must be '<app>-cluster'."
  }
}

run "service_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_ecs_service.main.name == "linkage-engine-service"
    error_message = "ECS service name must be '<app>-service'."
  }
}

run "task_definition_family_is_app_name" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.main.family == "linkage-engine"
    error_message = "Task definition family must be var.app."
  }
}

run "task_definition_uses_fargate_awsvpc" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.main.network_mode == "awsvpc"
    error_message = "Network mode must be awsvpc for Fargate."
  }

  assert {
    condition     = contains(aws_ecs_task_definition.main.requires_compatibilities, "FARGATE")
    error_message = "Task definition must require FARGATE compatibility."
  }
}

run "task_definition_cpu_and_memory_defaults" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.main.cpu == "1024"
    error_message = "Default task CPU must be 1024 (1 vCPU)."
  }

  assert {
    condition     = aws_ecs_task_definition.main.memory == "2048"
    error_message = "Default task memory must be 2048 MiB."
  }
}

run "task_definition_container_image_matches_variable" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image
      == "286103606369.dkr.ecr.us-west-1.amazonaws.com/linkage-engine:sha-abc123"
    )
    error_message = "Container image must match var.ecr_image_uri."
  }
}

run "task_definition_injects_secrets_from_secrets_manager" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets[0].name
      == "DB_URL"
    )
    error_message = "First secret injection must be DB_URL."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets[3].name
      == "INGEST_API_KEY"
    )
    error_message = "Fourth secret injection must be INGEST_API_KEY."
  }
}

run "task_definition_sets_spring_profile_to_bedrock" {
  command = plan

  assert {
    condition = contains([
      for env in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].environment :
      env.value if env.name == "SPRING_PROFILES_ACTIVE"
    ], "bedrock")
    error_message = "SPRING_PROFILES_ACTIVE must be set to 'bedrock'."
  }
}

run "task_definition_enables_cost_explorer_for_chord_page" {
  command = plan

  assert {
    condition = contains([
      for env in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].environment :
      env.value if env.name == "LINKAGE_COST_ENABLED"
    ], "true")
    error_message = "LINKAGE_COST_ENABLED must be true for production MTD cost display."
  }

  assert {
    condition = contains([
      for env in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].environment :
      env.value if env.name == "LINKAGE_COST_TAG_VALUE"
    ], "linkage-engine")
    error_message = "LINKAGE_COST_TAG_VALUE must match var.app for App-tag cost filtering."
  }
}

run "service_uses_fargate_launch_type" {
  command = plan

  assert {
    condition     = aws_ecs_service.main.launch_type == "FARGATE"
    error_message = "ECS service must use FARGATE launch type."
  }
}

run "service_desired_count_default_is_one" {
  command = plan

  assert {
    condition     = aws_ecs_service.main.desired_count == 1
    error_message = "Default desired_count must be 1."
  }
}

run "output_names_match_resources" {
  command = plan

  assert {
    condition     = output.cluster_name == "linkage-engine-cluster"
    error_message = "cluster_name output must match the cluster resource."
  }

  assert {
    condition     = output.service_name == "linkage-engine-service"
    error_message = "service_name output must match the service resource."
  }

  assert {
    condition     = output.task_family == "linkage-engine"
    error_message = "task_family output must match the task definition family."
  }
}
