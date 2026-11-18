# One Lambda function with its own log group and a role inside the workload
# permissions boundary. The caller passes the role's policy.

data "aws_caller_identity" "current" {}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${var.name}.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:CloudWatch's default encryption is used; a KMS key costs $1/month and these logs hold no personal data.
  #checkov:skip=CKV_AWS_338:Dev keeps logs for a short time to keep storage cost near zero.
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

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
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = var.description
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "base" {
  source_policy_documents = [var.policy_json]

  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "this" {
  name   = var.name
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.base.json
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_115:The account's concurrency limit is 10 and AWS keeps 10 unreserved, so nothing can be reserved.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by Step Functions or by an SQS event source mapping, which has its own dead-letter queue.
  #checkov:skip=CKV_AWS_117:No VPC resources are used; DynamoDB is reached over its public endpoint with IAM and TLS.
  #checkov:skip=CKV_AWS_173:The environment variables hold resource names only, no secrets.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for this demo; CI builds the package from the reviewed main branch.
  function_name    = var.name
  description      = var.description
  role             = aws_iam_role.this.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = var.handler
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds
  layers           = [var.powertools_layer_arn]

  environment {
    variables = merge(
      {
        POWERTOOLS_SERVICE_NAME      = var.service_name
        POWERTOOLS_METRICS_NAMESPACE = "aedo"
        POWERTOOLS_LOG_LEVEL         = "INFO"
      },
      var.environment,
    )
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  depends_on = [aws_iam_role_policy.this]
}
