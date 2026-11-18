output "orders_table_name" {
  description = "Name of the orders table."
  value       = aws_dynamodb_table.orders.name
}

output "orders_table_arn" {
  description = "ARN of the orders table."
  value       = aws_dynamodb_table.orders.arn
}

output "idempotency_table_name" {
  description = "Name of the idempotency table."
  value       = aws_dynamodb_table.idempotency.name
}

output "idempotency_table_arn" {
  description = "ARN of the idempotency table."
  value       = aws_dynamodb_table.idempotency.arn
}

output "orders_stream_arn" {
  description = "Stream of the orders table."
  value       = aws_dynamodb_table.orders.stream_arn
}
