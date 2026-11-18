output "event_bus_name" {
  description = "Orders event bus."
  value       = aws_cloudwatch_event_bus.orders.name
}

output "state_machine_arn" {
  description = "Order saga state machine."
  value       = aws_sfn_state_machine.saga.arn
}

output "notifications_queue_url" {
  description = "Notification queue."
  value       = aws_sqs_queue.notifications.id
}

output "notifications_dlq_url" {
  description = "Notification dead-letter queue."
  value       = aws_sqs_queue.notifications_dlq.id
}
