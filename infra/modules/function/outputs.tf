output "arn" {
  description = "Function ARN."
  value       = aws_lambda_function.this.arn
}

output "name" {
  description = "Function name."
  value       = aws_lambda_function.this.function_name
}
