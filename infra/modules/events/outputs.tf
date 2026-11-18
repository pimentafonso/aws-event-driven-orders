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

output "events_dlq_url" {
  description = "Dead-letter queue for events the pipe or the rules could not deliver."
  value       = aws_sqs_queue.events_dlq.id
}

output "pipe_name" {
  description = "Pipe from the orders table stream to the bus."
  value       = aws_pipes_pipe.orders.name
}

output "steps_function_name" {
  description = "Saga steps function."
  value       = module.steps.name
}

output "notifier_function_name" {
  description = "Notification consumer function."
  value       = module.notifier.name
}

output "notifications_queue_name" {
  description = "Notification queue name."
  value       = aws_sqs_queue.notifications.name
}

output "notifications_dlq_name" {
  description = "Notification dead-letter queue name."
  value       = aws_sqs_queue.notifications_dlq.name
}

output "events_dlq_name" {
  description = "Event delivery dead-letter queue name."
  value       = aws_sqs_queue.events_dlq.name
}
