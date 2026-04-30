variable "app" {
  description = "Application name prefix for resource naming."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used for log group retention)."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name for CloudWatch alarm dimensions."
  type        = string
}

variable "service_name" {
  description = "ECS service name for CloudWatch alarm dimensions."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch alarm dimensions (e.g. 'app/linkage-engine-alb/abc123')."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix for CloudWatch alarm dimensions (e.g. 'targetgroup/linkage-engine-tg/abc123')."
  type        = string
}

variable "db_cluster_identifier" {
  description = "Aurora cluster identifier for CloudWatch alarm dimensions."
  type        = string
}

variable "log_retention_days" {
  description = "Number of days to retain ECS logs in CloudWatch."
  type        = number
  default     = 30
}

variable "monthly_budget_usd" {
  description = "Monthly AWS budget in USD. Alert fires at 80% of this amount."
  type        = number
  default     = 50
}

variable "aws_account_id" {
  description = "AWS account ID for the budget resource."
  type        = string
}

variable "alert_email" {
  description = "Email address to subscribe to the SNS alerts topic. Leave empty to skip."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
