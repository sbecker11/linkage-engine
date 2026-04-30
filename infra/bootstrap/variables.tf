variable "aws_region" {
  description = "AWS region where the state bucket and lock table are created."
  type        = string
  default     = "us-west-1"
}

variable "app" {
  description = "Application name prefix used for resource naming."
  type        = string
  default     = "linkage-engine"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.app))
    error_message = "app must be 3-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}
