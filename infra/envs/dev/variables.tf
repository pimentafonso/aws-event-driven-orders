variable "region" {
  description = "AWS region for every resource in this environment."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "Use 2-16 lowercase letters, digits or hyphens, starting with a letter."
  }
}
