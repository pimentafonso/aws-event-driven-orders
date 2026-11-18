# Event flow: orders table stream -> EventBridge Pipe -> orders bus.
# Rules on the bus start the saga (saga.tf) and feed the notification queue
# (notifications.tf).

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  source     = "aedo.orders"
}

resource "aws_cloudwatch_event_bus" "orders" {
  name        = "${var.name_prefix}-orders"
  description = "Order lifecycle events"
}

# -----------------------------------------------------------------------------
# Dead-letter queue for event delivery: events the pipe cannot publish, and
# events the rules cannot deliver to the saga or the notification queue, land
# here instead of being dropped (M4).
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "events_dlq" {
  name                      = "${var.name_prefix}-events-dlq"
  message_retention_seconds = 14 * 24 * 60 * 60
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "events_dlq" {
  statement {
    sid       = "RuleTargets"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.order_placed.arn,
        aws_cloudwatch_event_rule.order_confirmed.arn,
      ]
    }
  }
}

resource "aws_sqs_queue_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id
  policy    = data.aws_iam_policy_document.events_dlq.json
}

# -----------------------------------------------------------------------------
# Pipe: new ORDER items only (not stock updates, not notifications), reshaped
# into a small OrderPlaced event.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "pipe_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "pipe" {
  name                 = "${var.name_prefix}-orders-pipe"
  description          = "Reads the orders table stream and publishes OrderPlaced events"
  assume_role_policy   = data.aws_iam_policy_document.pipe_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "pipe" {
  statement {
    sid = "ReadStream"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [var.orders_stream_arn]
  }

  statement {
    sid       = "PublishEvents"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.orders.arn]
  }

  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events_dlq.arn]
  }
}

resource "aws_iam_role_policy" "pipe" {
  name   = "orders-pipe"
  role   = aws_iam_role.pipe.id
  policy = data.aws_iam_policy_document.pipe.json
}

resource "aws_pipes_pipe" "orders" {
  name     = "${var.name_prefix}-orders-placed"
  role_arn = aws_iam_role.pipe.arn
  source   = var.orders_stream_arn
  target   = aws_cloudwatch_event_bus.orders.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position                  = "LATEST"
      batch_size                         = 10
      maximum_batching_window_in_seconds = 0
      maximum_retry_attempts             = 5

      # After the retries, the record goes to the dead-letter queue instead
      # of blocking the shard until it expires from the stream.
      dead_letter_config {
        arn = aws_sqs_queue.events_dlq.arn
      }
    }

    filter_criteria {
      filter {
        pattern = jsonencode({
          eventName = ["INSERT"]
          dynamodb = {
            NewImage = {
              sk = { S = ["ORDER"] }
            }
          }
        })
      }
    }
  }

  target_parameters {
    input_template = <<-EOT
      {"order_id": "<$.dynamodb.NewImage.order_id.S>", "customer_id": "<$.dynamodb.NewImage.customer_id.S>"}
    EOT

    eventbridge_event_bus_parameters {
      source      = local.source
      detail_type = "OrderPlaced"
    }
  }

  depends_on = [aws_iam_role_policy.pipe]
}
