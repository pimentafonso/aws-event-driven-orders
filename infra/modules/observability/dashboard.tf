# One dashboard for the whole order flow, top to bottom in the order an
# order travels: API, saga, events, notifications, then the Lambda functions.

locals {
  functions = [var.api_function_name, var.steps_function_name, var.notifier_function_name]

  widget = {
    region = local.region
    view   = "timeSeries"
    period = 60
  }

  widgets = [
    {
      type   = "alarm"
      x      = 0
      y      = 0
      width  = 24
      height = 3
      properties = {
        title  = "Alarms"
        alarms = [for a in aws_cloudwatch_metric_alarm.this : a.arn]
      }
    },
    {
      type = "metric", x = 0, y = 3, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Orders"
        stat  = "Sum"
        metrics = [
          ["aedo", "OrdersCreated", "service", "orders-api", { label = "created" }],
          ["aedo", "OrdersConfirmed", "service", "order-saga", { label = "confirmed" }],
          ["aedo", "OrdersRejected", "service", "order-saga", { label = "rejected (out of stock)" }],
          ["aedo", "StockReleased", "service", "order-saga", { label = "rejected after payment (stock released)" }],
        ]
      })
    },
    {
      type = "metric", x = 8, y = 3, width = 8, height = 6
      properties = merge(local.widget, {
        title = "API requests"
        stat  = "Sum"
        metrics = [
          ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { label = "requests" }],
          ["AWS/ApiGateway", "4xx", "ApiId", var.api_id, { label = "4xx" }],
          ["AWS/ApiGateway", "5xx", "ApiId", var.api_id, { label = "5xx" }],
        ]
      })
    },
    {
      type = "metric", x = 16, y = 3, width = 8, height = 6
      properties = merge(local.widget, {
        title = "API latency (ms)"
        metrics = [
          ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50", label = "p50" }],
          ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p95", label = "p95" }],
          ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p99", label = "p99" }],
        ]
      })
    },
    {
      type = "metric", x = 0, y = 9, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Saga executions"
        stat  = "Sum"
        metrics = [
          ["AWS/States", "ExecutionsStarted", "StateMachineArn", var.state_machine_arn, { label = "started" }],
          ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn, { label = "succeeded" }],
          ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn, { label = "failed" }],
        ]
      })
    },
    {
      type = "metric", x = 8, y = 9, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Saga duration (ms)"
        metrics = [
          ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn, { stat = "p50", label = "p50" }],
          ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn, { stat = "p95", label = "p95" }],
          ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn, { stat = "Maximum", label = "max" }],
        ]
      })
    },
    {
      type = "metric", x = 16, y = 9, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Orders pipe"
        stat  = "Sum"
        metrics = [
          ["AWS/EventBridge/Pipes", "EventCount", "PipeName", var.pipe_name, { label = "events in" }],
          ["AWS/EventBridge/Pipes", "TargetStageFailed", "PipeName", var.pipe_name, { label = "publish failed" }],
          ["AWS/EventBridge/Pipes", "ExecutionFailed", "PipeName", var.pipe_name, { label = "execution failed" }],
        ]
      })
    },
    {
      type = "metric", x = 0, y = 15, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Notification latency after OrderConfirmed (ms)"
        metrics = [
          ["aedo", "NotificationLatency", "service", "notifier", { stat = "p50", label = "p50" }],
          ["aedo", "NotificationLatency", "service", "notifier", { stat = "Maximum", label = "max" }],
        ]
      })
    },
    {
      type = "metric", x = 8, y = 15, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Queue depth"
        stat  = "Maximum"
        metrics = [
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.notifications_queue_name, { label = "notifications" }],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.notifications_dlq_name, { label = "notifications DLQ" }],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.events_dlq_name, { label = "events DLQ" }],
        ]
      })
    },
    {
      type = "metric", x = 16, y = 15, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Oldest notification waiting (s)"
        stat  = "Maximum"
        metrics = [
          ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", var.notifications_queue_name, { label = "age" }],
        ]
        annotations = {
          horizontal = [{ label = "alarm", value = var.backlog_age_seconds }]
        }
      })
    },
    {
      type = "metric", x = 0, y = 21, width = 8, height = 6
      properties = merge(local.widget, {
        title   = "Lambda duration p95 (ms)"
        metrics = [for f in local.functions : ["AWS/Lambda", "Duration", "FunctionName", f, { stat = "p95", label = f }]]
      })
    },
    {
      type = "metric", x = 8, y = 21, width = 8, height = 6
      properties = merge(local.widget, {
        title   = "Lambda errors"
        stat    = "Sum"
        metrics = [for f in local.functions : ["AWS/Lambda", "Errors", "FunctionName", f, { label = f }]]
      })
    },
    {
      type = "metric", x = 16, y = 21, width = 8, height = 6
      properties = merge(local.widget, {
        title = "Account concurrency (limit 10)"
        metrics = [
          ["AWS/Lambda", "ConcurrentExecutions", { stat = "Maximum", label = "concurrent executions" }],
          ["AWS/Lambda", "Throttles", { stat = "Sum", label = "throttles" }],
        ]
      })
    },
  ]
}

resource "aws_cloudwatch_dashboard" "orders" {
  dashboard_name = "${var.name_prefix}-orders"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
