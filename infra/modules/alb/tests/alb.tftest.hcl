# ALB module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/alb/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app            = "linkage-engine"
  vpc_id         = "vpc-00000000000000001"
  subnet_ids     = ["subnet-00000000000000001", "subnet-00000000000000002"]
  alb_sg_id      = "sg-00000000000000001"
  container_port = 8080
}

run "alb_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_lb.main.name == "linkage-engine-alb"
    error_message = "ALB name must be '<app>-alb'."
  }
}

run "alb_is_internet_facing_application_lb" {
  command = plan

  assert {
    condition     = aws_lb.main.internal == false
    error_message = "ALB must be internet-facing."
  }

  assert {
    condition     = aws_lb.main.load_balancer_type == "application"
    error_message = "Load balancer type must be 'application'."
  }
}

run "target_group_name_and_type" {
  command = plan

  assert {
    condition     = aws_lb_target_group.app.name == "linkage-engine-tg"
    error_message = "Target group name must be '<app>-tg'."
  }

  assert {
    condition     = aws_lb_target_group.app.target_type == "ip"
    error_message = "Target type must be 'ip' for Fargate awsvpc networking."
  }
}

run "health_check_uses_actuator_endpoint" {
  command = plan

  assert {
    condition     = aws_lb_target_group.app.health_check[0].path == "/actuator/health"
    error_message = "Health check path must be '/actuator/health'."
  }

  assert {
    condition     = aws_lb_target_group.app.health_check[0].healthy_threshold == 2
    error_message = "Healthy threshold must be 2."
  }

  assert {
    condition     = aws_lb_target_group.app.health_check[0].unhealthy_threshold == 3
    error_message = "Unhealthy threshold must be 3."
  }
}

run "http_listener_forwards_on_port_80" {
  command = plan

  assert {
    condition     = aws_lb_listener.http.port == 80
    error_message = "HTTP listener must be on port 80."
  }

  assert {
    condition     = aws_lb_listener.http.protocol == "HTTP"
    error_message = "HTTP listener protocol must be HTTP."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "HTTP listener default action must be 'forward'."
  }
}

run "https_listener_not_created_without_cert" {
  command = plan

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "HTTPS listener must not be created when cert_arn is empty."
  }
}

run "https_listener_created_when_cert_provided" {
  command = plan

  variables {
    cert_arn = "arn:aws:acm:us-west-1:286103606369:certificate/test-cert-id"
  }

  assert {
    condition     = length(aws_lb_listener.https) == 1
    error_message = "HTTPS listener must be created when cert_arn is provided."
  }

  assert {
    condition     = aws_lb_listener.https[0].port == 443
    error_message = "HTTPS listener must be on port 443."
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "HTTPS listener must use TLS 1.3 security policy."
  }
}
