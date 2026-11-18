# Orders HTTP API: API Gateway (HTTP API, IAM auth) -> Lambda -> DynamoDB.

data "aws_caller_identity" "current" {}

locals {
  function_name = "${var.name_prefix}-orders-api"
  account_id    = data.aws_caller_identity.current.account_id
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${local.function_name}.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

# -----------------------------------------------------------------------------
# Logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "function" {
  #checkov:skip=CKV_AWS_158:CloudWatch's default encryption is used; a KMS key costs $1/month and this log holds no personal data.
  #checkov:skip=CKV_AWS_338:Dev keeps logs for a short time to keep storage cost near zero.
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "access" {
  #checkov:skip=CKV_AWS_158:Same as the function log group.
  #checkov:skip=CKV_AWS_338:Same as the function log group.
  name              = "/aedo/${var.name_prefix}/api-access"
  retention_in_days = var.log_retention_days
}

# -----------------------------------------------------------------------------
# Function role: inside the workload permissions boundary, with access to the
# two tables and its own log group only.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "function" {
  name                 = local.function_name
  description          = "Orders API Lambda function"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "function" {
  statement {
    sid       = "Orders"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [var.orders_table_arn]
  }

  statement {
    sid = "IdempotencyRecords"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [var.idempotency_table_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.function.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "function" {
  name   = "orders-api"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

# -----------------------------------------------------------------------------
# Function
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_115:The account's concurrency limit is 10 and AWS keeps 10 unreserved, so nothing can be reserved; the API stage throttle caps load instead.
  #checkov:skip=CKV_AWS_116:Synchronous API: errors go back to the caller, so a dead-letter queue would never receive anything.
  #checkov:skip=CKV_AWS_117:No VPC resources are used; DynamoDB is reached over its public endpoint with IAM and TLS.
  #checkov:skip=CKV_AWS_173:The environment variables hold table names only, no secrets.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for this demo; CI builds the package from the reviewed main branch.
  function_name    = local.function_name
  description      = "Orders HTTP API: create (idempotent) and read orders"
  role             = aws_iam_role.function.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "orders_api.app.lambda_handler"
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  memory_size      = var.memory_mb
  timeout          = 10
  layers           = [var.powertools_layer_arn]

  environment {
    variables = {
      ORDERS_TABLE                 = var.orders_table_name
      IDEMPOTENCY_TABLE            = var.idempotency_table_name
      POWERTOOLS_SERVICE_NAME      = "orders-api"
      POWERTOOLS_METRICS_NAMESPACE = "aedo"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.function.name
  }

  depends_on = [aws_iam_role_policy.function]
}

# -----------------------------------------------------------------------------
# HTTP API. Every route needs a SigV4-signed request (AWS_IAM), so only
# principals in this account with execute-api:Invoke can reach the function.
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-orders"
  description   = "Orders API (IAM auth)"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "function" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "this" {
  for_each = toset(["POST /orders", "GET /orders/{order_id}"])

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.function.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate
    throttling_burst_limit = var.throttle_burst
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      requestTime        = "$context.requestTime"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      integrationError   = "$context.integrationErrorMessage"
      authorizerError    = "$context.authorizer.error"
      caller             = "$context.identity.caller"
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
