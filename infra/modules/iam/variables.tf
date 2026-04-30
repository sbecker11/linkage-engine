variable "app" {
  description = "Application name prefix for role names."
  type        = string
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret the execution role must be able to read."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the deploy role must be able to push to."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID used to construct the OIDC provider ARN."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format allowed to assume the deploy role."
  type        = string
  default     = "sbecker11/linkage-engine"
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
