variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-west-1"
}

variable "app" {
  description = "Application name prefix used across all modules."
  type        = string
  default     = "linkage-engine"
}

variable "aws_account_id" {
  description = "AWS account ID (used by IAM module for OIDC provider ARN construction)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format for the OIDC deploy role."
  type        = string
  default     = "sbecker11/linkage-engine"
}

variable "domain_name" {
  description = "Custom domain for HTTPS. Leave empty to use HTTP only (no ACM cert created)."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address to receive SNS alerts. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend limit in USD. Alert fires at 80%."
  type        = number
  default     = 50
}

variable "aurora_min_capacity" {
  description = "Minimum Aurora Serverless v2 ACUs (0 = scales to zero when idle)."
  type        = number
  default     = 0
}

variable "aurora_max_capacity" {
  description = "Maximum Aurora Serverless v2 ACUs."
  type        = number
  default     = 2
}

variable "ecs_desired_count" {
  description = "Desired number of running ECS tasks."
  type        = number
  default     = 1
}

variable "ecr_image_uri" {
  description = "Full ECR image URI with tag. Set via -var at deploy time by GitHub Actions."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default = {
    App       = "linkage-engine"
    Env       = "prod"
    ManagedBy = "terraform"
  }
}
