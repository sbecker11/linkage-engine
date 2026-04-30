variable "domain_name" {
  description = "Fully-qualified domain name for the ACM certificate."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
