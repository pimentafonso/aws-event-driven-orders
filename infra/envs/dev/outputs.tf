output "api_endpoint" {
  description = "Base URL of the orders API (requests must be SigV4-signed)."
  value       = module.api.api_endpoint
}

output "function_name" {
  description = "Name of the orders API function."
  value       = module.api.function_name
}

output "state_machine_arn" {
  description = "Order saga state machine."
  value       = module.events.state_machine_arn
}

output "notifications_queue_url" {
  description = "Notification queue."
  value       = module.events.notifications_queue_url
}

output "notifications_dlq_url" {
  description = "Notification dead-letter queue."
  value       = module.events.notifications_dlq_url
}

output "events_dlq_url" {
  description = "Dead-letter queue for events the pipe or the rules could not deliver."
  value       = module.events.events_dlq_url
}

output "alarm_topic_arn" {
  description = "SNS topic the alarms notify; subscribe an email address to it by hand."
  value       = module.observability.alarm_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard for the order flow."
  value       = module.observability.dashboard_name
}
