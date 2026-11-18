variable "name" {
  description = "Function, role and log group name (must start with the environment prefix, for example aedo-dev-)."
  type        = string
}

variable "description" {
  description = "What the function does."
  type        = string
}

variable "service_name" {
  description = "Powertools service name, shown in logs, metrics and traces."
  type        = string
}

variable "source_dir" {
  description = "Directory packaged as the function code (the src folder)."
  type        = string
}

variable "handler" {
  description = "Module path and function, for example saga.steps.lambda_handler."
  type        = string
}

variable "powertools_layer_arn" {
  description = "AWS-managed Powertools for AWS Lambda (Python) layer."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Boundary the function's role must carry."
  type        = string
}

variable "policy_json" {
  description = "IAM policy for the function's own resources; log and tracing permissions are added here."
  type        = string
}

variable "environment" {
  description = "Extra environment variables."
  type        = map(string)
  default     = {}
}

variable "memory_mb" {
  description = "Memory in MB (CPU scales with it)."
  type        = number
  default     = 256
}

variable "timeout_seconds" {
  description = "Timeout in seconds."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "Days to keep the function's logs."
  type        = number
  default     = 14
}
