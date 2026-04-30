variable "app" {
  description = "Application name prefix for ALB and target group names."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the target group."
  type        = string
}

variable "subnet_ids" {
  description = "List of public subnet IDs for the ALB."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID to attach to the ALB."
  type        = string
}

variable "container_port" {
  description = "Port the ECS container listens on (health check + target group port)."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "HTTP path used for ALB target group health checks."
  type        = string
  default     = "/actuator/health"
}

variable "cert_arn" {
  description = "ACM certificate ARN. When non-empty, an HTTPS :443 listener is created."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
