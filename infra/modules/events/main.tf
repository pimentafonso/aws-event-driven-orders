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
