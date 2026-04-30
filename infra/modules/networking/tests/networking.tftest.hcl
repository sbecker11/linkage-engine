# Networking module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/networking/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app            = "linkage-engine"
  vpc_id         = "vpc-00000000000000001"
  container_port = 8080
  tags = {
    App = "linkage-engine"
    Env = "prod"
  }
}

run "security_group_names_follow_convention" {
  command = plan

  assert {
    condition     = aws_security_group.alb.name == "linkage-engine-alb-sg"
    error_message = "ALB SG name must be '<app>-alb-sg'."
  }

  assert {
    condition     = aws_security_group.ecs.name == "linkage-engine-ecs-sg"
    error_message = "ECS SG name must be '<app>-ecs-sg'."
  }

  assert {
    condition     = aws_security_group.db.name == "linkage-engine-db-sg"
    error_message = "DB SG name must be '<app>-db-sg'."
  }
}

run "all_security_groups_are_in_the_correct_vpc" {
  command = plan

  assert {
    condition     = aws_security_group.alb.vpc_id == "vpc-00000000000000001"
    error_message = "ALB SG must be in the provided VPC."
  }

  assert {
    condition     = aws_security_group.ecs.vpc_id == "vpc-00000000000000001"
    error_message = "ECS SG must be in the provided VPC."
  }

  assert {
    condition     = aws_security_group.db.vpc_id == "vpc-00000000000000001"
    error_message = "DB SG must be in the provided VPC."
  }
}

run "alb_accepts_http_on_port_80" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_http.from_port == 80
    error_message = "ALB must accept HTTP on port 80."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_http.cidr_ipv4 == "0.0.0.0/0"
    error_message = "ALB HTTP must be open to the internet."
  }
}

run "alb_accepts_https_on_port_443" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_https.from_port == 443
    error_message = "ALB must accept HTTPS on port 443."
  }
}

run "ecs_accepts_container_port_from_alb_only" {
  # apply needed: referenced_security_group_id is computed from alb.id (not known at plan)
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ecs_from_alb.from_port == 8080
    error_message = "ECS ingress must be on container_port (8080)."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.ecs_from_alb.referenced_security_group_id
      == aws_security_group.alb.id
    )
    error_message = "ECS must only accept traffic from the ALB security group."
  }
}

run "db_accepts_postgres_from_ecs_only" {
  # apply needed: referenced_security_group_id is computed from ecs.id (not known at plan)
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_ecs.from_port == 5432
    error_message = "DB ingress must be on PostgreSQL port 5432."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.db_from_ecs.referenced_security_group_id
      == aws_security_group.ecs.id
    )
    error_message = "DB must only accept traffic from the ECS security group."
  }
}

run "custom_container_port_is_respected" {
  command = plan

  variables {
    container_port = 9090
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ecs_from_alb.from_port == 9090
    error_message = "Custom container_port must be reflected in ECS ingress rule."
  }
}
