variable "app" {
  description = "Application name prefix used for resource naming."
  type        = string
}

variable "db_sg_id" {
  description = "Security group ID to attach to the Aurora cluster."
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group."
  type        = list(string)
}

variable "db_name" {
  description = "Name of the initial database created in the cluster."
  type        = string
  default     = "linkage_db"
}

variable "db_username" {
  description = "Master username for the Aurora cluster."
  type        = string
  default     = "ancestry"
}

variable "db_password" {
  description = "Master password for the Aurora cluster. Supply from a random_password resource in the root module."
  type        = string
  sensitive   = true
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version. Pin this to the live cluster version to avoid attempted downgrades."
  type        = string
  default     = "16.13"
}

variable "min_capacity" {
  description = "Minimum Aurora Serverless v2 capacity units (ACUs)."
  type        = number
  default     = 0
}

variable "max_capacity" {
  description = "Maximum Aurora Serverless v2 capacity units (ACUs)."
  type        = number
  default     = 2
}

variable "backup_retention_days" {
  description = "Number of days to retain automated backups."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
