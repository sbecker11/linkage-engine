variable "app" {
  description = "Application name; used as the ECR repository name."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
