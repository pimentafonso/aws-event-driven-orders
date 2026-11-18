variable "name_prefix" {
  description = "Prefix for resource names, for example aedo-dev."
  type        = string
}

variable "deletion_protection" {
  description = "Protect the tables from deletion. Off in dev so scripts/destroy.sh can remove them."
  type        = bool
  default     = false
}
