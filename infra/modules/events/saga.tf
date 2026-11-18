# Saga: OrderPlaced -> Step Functions (standard) -> saga steps Lambda.

data "aws_iam_policy_document" "steps" {
  statement {
    sid       = "Orders"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:ConditionCheckItem"]
    resources = [var.orders_table_arn]
  }
}

module "steps" {
  source = "../function"

  name                     = "${var.name_prefix}-saga-steps"
  description              = "Order saga steps: reserve, charge (simulated), release, reject, confirm"
  service_name             = "order-saga"
  source_dir               = var.source_dir
  handler                  = "saga.steps.lambda_handler"
  powertools_layer_arn     = var.powertools_layer_arn
  permissions_boundary_arn = var.permissions_boundary_arn
  policy_json              = data.aws_iam_policy_document.steps.json
  environment              = { ORDERS_TABLE = var.orders_table_name }
}

# -----------------------------------------------------------------------------
# State machine
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "saga" {
  #checkov:skip=CKV_AWS_158:CloudWatch's default encryption is used; a KMS key costs $1/month and these logs hold no personal data.
  #checkov:skip=CKV_AWS_338:Dev keeps logs for a short time to keep storage cost near zero.
  name              = "/aws/vendedlogs/states/${var.name_prefix}-order-saga"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "saga_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "saga" {
  name                 = "${var.name_prefix}-order-saga"
  description          = "Order saga state machine"
  assume_role_policy   = data.aws_iam_policy_document.saga_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "saga" {
  statement {
    sid       = "InvokeSteps"
    actions   = ["lambda:InvokeFunction"]
    resources = [module.steps.arn, "${module.steps.arn}:*"]
  }

  statement {
    sid       = "PublishOrderConfirmed"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.orders.arn]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }

  statement {
    sid = "LogDelivery"
    # Step Functions logging uses CloudWatch log delivery, whose actions do
    # not support resource-level permissions.
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "saga" {
  name   = "order-saga"
  role   = aws_iam_role.saga.id
  policy = data.aws_iam_policy_document.saga.json
}

resource "aws_sfn_state_machine" "saga" {
  name     = "${var.name_prefix}-order-saga"
  type     = "STANDARD"
  role_arn = aws_iam_role.saga.arn
  definition = templatefile("${path.module}/saga.asl.json", {
    steps_function_arn = module.steps.arn
    event_bus_name     = aws_cloudwatch_event_bus.orders.name
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.saga.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.saga]
}

# -----------------------------------------------------------------------------
# OrderPlaced on the bus starts an execution.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "order_placed" {
  name           = "${var.name_prefix}-order-placed"
  description    = "Start the order saga for each new order"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  event_pattern = jsonencode({
    source        = [local.source]
    "detail-type" = ["OrderPlaced"]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "start_saga" {
  name                 = "${var.name_prefix}-start-saga"
  description          = "Lets the OrderPlaced rule start the order saga"
  assume_role_policy   = data.aws_iam_policy_document.events_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "start_saga" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.saga.arn]
  }
}

resource "aws_iam_role_policy" "start_saga" {
  name   = "start-saga"
  role   = aws_iam_role.start_saga.id
  policy = data.aws_iam_policy_document.start_saga.json
}

resource "aws_cloudwatch_event_target" "saga" {
  rule           = aws_cloudwatch_event_rule.order_placed.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  arn            = aws_sfn_state_machine.saga.arn
  role_arn       = aws_iam_role.start_saga.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
