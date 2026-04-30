variable "app" {
  description = "Application name; used for cluster, service, task family, and container name."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used in CloudWatch log config and task environment vars)."
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the ECS task execution role."
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the ECS task role (runtime app permissions)."
  type        = string
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret injected into the container."
  type        = string
}

variable "ecr_image_uri" {
  description = "Full ECR image URI including tag (e.g. 123456789.dkr.ecr.us-west-1.amazonaws.com/linkage-engine:sha-abc123)."
  type        = string
}

variable "ecs_sg_id" {
  description = "Security group ID for ECS tasks."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS task networking (awsvpc mode)."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB target group ARN to register tasks with."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name for ECS task logs."
  type        = string
  default     = "/ecs/linkage-engine"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Task CPU units (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Desired number of running ECS tasks."
  type        = number
  default     = 1
}

variable "health_check_grace_period_seconds" {
  description = "Seconds ECS waits before starting health checks after a task starts."
  type        = number
  default     = 120
}

variable "bedrock_model_id" {
  description = "Bedrock model ID for the chat/summarise feature."
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
}

variable "bedrock_embedding_model_id" {
  description = "Bedrock model ID for embedding generation."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "semantic_llm_enabled" {
  description = "Whether the Bedrock LLM summary feature is enabled."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
