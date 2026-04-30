variable "app" {
  description = "Application name prefix for WAF WebACL naming."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to associate with the WAF WebACL."
  type        = string
}

variable "rate_limit" {
  description = "Maximum number of requests per IP per 5-minute window before blocking."
  type        = number
  default     = 500
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
