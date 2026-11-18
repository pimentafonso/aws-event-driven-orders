# Alarms, the topic they notify and the dashboard. Each alarm watches one
# metric, so the eight of them stay inside CloudWatch's ten free alarm metrics.
# docs/runbook.md says what to do when each one fires.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  runbook    = "https://github.com/pimentafonso/aws-event-driven-orders/blob/main/docs/runbook.md"

  alarms = {
    "notifications-dlq-not-empty" = {
      description = "A notification failed three times and is in the dead-letter queue."
      namespace   = "AWS/SQS"
      metric      = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = var.notifications_dlq_name }
      statistic   = "Maximum"
      threshold   = 0
    }
    "events-dlq-not-empty" = {
      description = "The pipe or a rule could not deliver an event; it is in the events dead-letter queue."
      namespace   = "AWS/SQS"
      metric      = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = var.events_dlq_name }
      statistic   = "Maximum"
      threshold   = 0
    }
    "notifications-backlog" = {
      description = "The oldest notification has waited more than ${var.backlog_age_seconds} seconds."
      namespace   = "AWS/SQS"
      metric      = "ApproximateAgeOfOldestMessage"
      dimensions  = { QueueName = var.notifications_queue_name }
      statistic   = "Maximum"
      threshold   = var.backlog_age_seconds
    }
    "saga-executions-failed" = {
      description = "An order saga execution failed. Rejected orders succeed, so this is a technical failure."
      namespace   = "AWS/States"
      metric      = "ExecutionsFailed"
      dimensions  = { StateMachineArn = var.state_machine_arn }
      statistic   = "Sum"
      threshold   = 0
    }
    "pipe-failures" = {
      description = "The orders pipe failed to publish OrderPlaced events."
      namespace   = "AWS/EventBridge/Pipes"
      metric      = "ExecutionFailed"
      dimensions  = { PipeName = var.pipe_name }
      statistic   = "Sum"
      threshold   = 0
    }
    "api-5xx" = {
      description = "The orders API returned a server error."
      namespace   = "AWS/ApiGateway"
      metric      = "5xx"
      dimensions  = { ApiId = var.api_id }
      statistic   = "Sum"
      threshold   = 0
    }
    "notifier-errors" = {
      description = "The notifier function failed as a whole (a bad message alone is reported per message and does not count)."
      namespace   = "AWS/Lambda"
      metric      = "Errors"
      dimensions  = { FunctionName = var.notifier_function_name }
      statistic   = "Sum"
      threshold   = 0
    }
    "lambda-throttles" = {
      description = "Lambda throttled an invocation somewhere in the account (the account allows 10 concurrent executions)."
      namespace   = "AWS/Lambda"
      metric      = "Throttles"
      dimensions  = {}
      statistic   = "Sum"
      threshold   = 0
    }
  }
}

# -----------------------------------------------------------------------------
# Alarm topic. The email subscription is made by hand (see the README), so no
# address is stored in this repository or its state.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alarms" {
  #checkov:skip=CKV_AWS_26:CloudWatch cannot publish to a topic encrypted with the AWS managed key, and a customer managed key costs $1/month. Alarm messages hold metric names only.
  name = "${var.name_prefix}-alarms"
}

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid       = "AlarmsFromThisProject"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${var.name_prefix}-*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid = "AccountManagesTheTopic"
    actions = [
      "sns:GetTopicAttributes",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
    ]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name_prefix}-${each.key}"
  alarm_description   = "${each.value.description} Runbook: ${local.runbook}#${each.key}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  period              = 60
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  # Idle resources stop sending some metrics; no data means nothing is wrong.
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.alarms.arn]
  ok_actions         = [aws_sns_topic.alarms.arn]
}
