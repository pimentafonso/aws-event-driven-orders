output "alarm_topic_arn" {
  description = "SNS topic the alarms notify; subscribe an email address to it by hand."
  value       = aws_sns_topic.alarms.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard for the order flow."
  value       = aws_cloudwatch_dashboard.orders.dashboard_name
}
