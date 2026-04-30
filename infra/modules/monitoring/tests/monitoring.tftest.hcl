# Monitoring module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/monitoring/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app                     = "linkage-engine"
  aws_region              = "us-west-1"
  cluster_name            = "linkage-engine-cluster"
  service_name            = "linkage-engine-service"
  alb_arn_suffix          = "app/linkage-engine-alb/abc123"
  target_group_arn_suffix = "targetgroup/linkage-engine-tg/abc123"
  db_cluster_identifier   = "linkage-engine-aurora"
  aws_account_id          = "286103606369"
}

run "log_group_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.ecs.name == "/ecs/linkage-engine"
    error_message = "Log group name must be '/ecs/<app>'."
  }
}

run "log_group_retention_is_30_days" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.ecs.retention_in_days == 30
    error_message = "Default log retention must be 30 days."
  }
}

run "sns_topic_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_sns_topic.alerts.name == "linkage-engine-alerts"
    error_message = "SNS topic name must be '<app>-alerts'."
  }
}

run "email_subscription_not_created_without_email" {
  command = plan

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "Email subscription must not be created when alert_email is empty."
  }
}

run "email_subscription_created_when_email_provided" {
  command = plan

  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "Email subscription must be created when alert_email is provided."
  }

  assert {
    condition     = aws_sns_topic_subscription.email[0].protocol == "email"
    error_message = "Subscription protocol must be 'email'."
  }
}

run "ecs_memory_alarm_threshold_is_80_percent" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.ecs_memory_high.threshold == 80
    error_message = "ECS memory alarm threshold must be 80%."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.ecs_memory_high.comparison_operator == "GreaterThanThreshold"
    error_message = "Memory alarm must fire when utilization exceeds threshold."
  }
}

run "alb_healthy_hosts_alarm_threshold_is_one" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_healthy_hosts.threshold == 1
    error_message = "ALB healthy hosts alarm threshold must be 1."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_healthy_hosts.comparison_operator == "LessThanThreshold"
    error_message = "Alarm must fire when healthy host count drops below threshold."
  }
}

run "ecs_tasks_running_alarm_threshold_is_one" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.ecs_tasks_running.threshold == 1
    error_message = "ECS tasks running alarm threshold must be 1."
  }
}

run "budget_limit_is_50_usd" {
  command = plan

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "50"
    error_message = "Default monthly budget must be $50."
  }

  assert {
    condition     = aws_budgets_budget.monthly.limit_unit == "USD"
    error_message = "Budget limit unit must be USD."
  }
}

run "budget_alerts_at_80_percent" {
  command = plan

  assert {
    condition     = one(aws_budgets_budget.monthly.notification).threshold == 80
    error_message = "Budget alert must fire at 80% of the limit."
  }
}

run "output_log_group_name_matches_resource" {
  command = plan

  assert {
    condition     = output.log_group_name == "/ecs/linkage-engine"
    error_message = "log_group_name output must match the CloudWatch log group."
  }
}

run "output_sns_topic_name_matches_resource" {
  command = plan

  assert {
    condition     = output.sns_topic_name == "linkage-engine-alerts"
    error_message = "sns_topic_name output must match the SNS topic."
  }
}
