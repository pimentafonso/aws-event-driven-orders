variable "name_prefix" {
  description = "Prefix for resource names, for example aedo-dev."
  type        = string
}

variable "api_id" {
  description = "Orders HTTP API ID."
  type        = string
}

variable "api_function_name" {
  description = "Orders API function."
  type        = string
}

variable "steps_function_name" {
  description = "Saga steps function."
  type        = string
}

variable "notifier_function_name" {
  description = "Notification consumer function."
  type        = string
}

variable "state_machine_arn" {
  description = "Order saga state machine."
  type        = string
}

variable "pipe_name" {
  description = "Pipe from the orders table stream to the bus."
  type        = string
}

variable "notifications_queue_name" {
  description = "Notification queue."
  type        = string
}

variable "notifications_dlq_name" {
  description = "Notification dead-letter queue."
  type        = string
}

variable "events_dlq_name" {
  description = "Event delivery dead-letter queue."
  type        = string
}

variable "backlog_age_seconds" {
  description = "Alarm when the oldest notification has waited longer than this."
  type        = number
  default     = 300
}
