variable "name_prefix" {
  description = "Prefix for resource names, for example aedo-dev."
  type        = string
}

variable "source_dir" {
  description = "Directory packaged as the function code (the src folder)."
  type        = string
}

variable "powertools_layer_arn" {
  description = "AWS-managed Powertools for AWS Lambda (Python) layer, pinned to the version in requirements-dev.txt."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Boundary every role created here must carry."
  type        = string
}

variable "orders_table_name" {
  description = "Orders table name."
  type        = string
}

variable "orders_table_arn" {
  description = "Orders table ARN."
  type        = string
}

variable "idempotency_table_name" {
  description = "Idempotency table name."
  type        = string
}

variable "idempotency_table_arn" {
  description = "Idempotency table ARN."
  type        = string
}

variable "memory_mb" {
  description = "Function memory in MB (CPU scales with it)."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "Days to keep function and access logs."
  type        = number
  default     = 14
}

variable "throttle_rate" {
  description = "Steady-state requests per second the API accepts."
  type        = number
  default     = 25
}

variable "throttle_burst" {
  description = "Burst of requests the API accepts above the steady rate."
  type        = number
  default     = 50
}
