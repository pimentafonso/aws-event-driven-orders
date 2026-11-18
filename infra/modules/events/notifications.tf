# OrderConfirmed -> SQS -> notifier Lambda (partial batch responses).
# Messages that fail three times move to the dead-letter queue;
# scripts/redrive_dlq.sh moves them back once the cause is fixed.

locals {
  notifier_timeout_seconds = 10
}

resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${var.name_prefix}-notifications-dlq"
  message_retention_seconds = 14 * 24 * 60 * 60
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "notifications" {
  name                    = "${var.name_prefix}-notifications"
  sqs_managed_sse_enabled = true
  # AWS recommends at least six times the function timeout for Lambda sources.
  visibility_timeout_seconds = 6 * local.notifier_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "notifications_dlq" {
  queue_url = aws_sqs_queue.notifications_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.notifications.arn]
  })
}

# Only the OrderConfirmed rule may send to the queue.
data "aws_iam_policy_document" "notifications_queue" {
  statement {
    sid       = "OrderConfirmedRule"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_confirmed.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "notifications" {
  queue_url = aws_sqs_queue.notifications.id
  policy    = data.aws_iam_policy_document.notifications_queue.json
}

resource "aws_cloudwatch_event_rule" "order_confirmed" {
  name           = "${var.name_prefix}-order-confirmed"
  description    = "Queue a notification for each confirmed order"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  event_pattern = jsonencode({
    source        = [local.source]
    "detail-type" = ["OrderConfirmed"]
  })
}

resource "aws_cloudwatch_event_target" "notifications" {
  rule           = aws_cloudwatch_event_rule.order_confirmed.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  arn            = aws_sqs_queue.notifications.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}

# -----------------------------------------------------------------------------
# Consumer
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "notifier" {
  statement {
    sid       = "RecordNotifications"
    actions   = ["dynamodb:PutItem"]
    resources = [var.orders_table_arn]
  }

  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.notifications.arn]
  }
}

module "notifier" {
  source = "../function"

  name                     = "${var.name_prefix}-notifier"
  description              = "Sends (simulated) notifications for confirmed orders"
  service_name             = "notifier"
  source_dir               = var.source_dir
  handler                  = "notifier.handler.lambda_handler"
  powertools_layer_arn     = var.powertools_layer_arn
  permissions_boundary_arn = var.permissions_boundary_arn
  policy_json              = data.aws_iam_policy_document.notifier.json
  environment              = { ORDERS_TABLE = var.orders_table_name }
  timeout_seconds          = local.notifier_timeout_seconds
}

resource "aws_lambda_event_source_mapping" "notifications" {
  event_source_arn                   = aws_sqs_queue.notifications.arn
  function_name                      = module.notifier.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]

  # The account allows 10 concurrent executions in total; keep the consumer
  # from taking them all.
  scaling_config {
    maximum_concurrency = 2
  }
}
