variable "app" {
  description = "Application name prefix; the secret is named '<app>/runtime'."
  type        = string
}

variable "db_url" {
  description = "JDBC connection URL for the Aurora cluster."
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "Database master username."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database master password."
  type        = string
  sensitive   = true
}

variable "ingest_api_key" {
  description = "API key required for POST /v1/records ingest endpoint."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
