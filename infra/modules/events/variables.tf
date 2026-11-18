variable "name_prefix" {
  description = "Prefix for resource names, for example aedo-dev."
  type        = string
}

variable "source_dir" {
  description = "Directory packaged as the function code (the src folder)."
  type        = string
}

variable "powertools_layer_arn" {
  description = "AWS-managed Powertools for AWS Lambda (Python) layer."
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

variable "orders_stream_arn" {
  description = "Orders table stream ARN."
  type        = string
}

variable "max_receive_count" {
  description = "Receives before a notification message moves to the dead-letter queue."
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "Days to keep the state machine's logs."
  type        = number
  default     = 14
}
