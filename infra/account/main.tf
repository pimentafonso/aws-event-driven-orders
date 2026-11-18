# Account-level resources, applied once by an administrator (scripts/account.sh):
#
# - a permissions boundary that caps every IAM role the environments create
# - a plan role that pull requests use to run `terraform plan` (read only)
# - a deploy role per environment that GitHub Actions uses to apply
#
# The GitHub OIDC provider already exists in this account (created by
# aws-ha-web-platform). An account can hold only one provider per URL, so it is
# read here, not created.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.region

  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket}"

  # Roles created by the environments are named <prefix>-<env>-*. The GitHub
  # roles below are named <prefix>-github-*, so a deploy role can never edit
  # itself or another GitHub role.
  workload_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.prefix}-dev-*"
}

# -----------------------------------------------------------------------------
# Workload permissions boundary: the most any Lambda, Step Functions or Pipes
# role in this project can ever do, whatever its own policy says.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*${var.prefix}-*"]
  }

  statement {
    sid = "Tracing"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    # X-Ray's write actions do not support resource-level permissions.
    resources = ["*"]
  }

  statement {
    sid = "OwnTables"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:TransactWriteItems",
      "dynamodb:TransactGetItems",
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [
      "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.prefix}-*",
      "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.prefix}-*/index/*",
      "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.prefix}-*/stream/*",
    ]
  }

  statement {
    sid       = "OwnEventBus"
    actions   = ["events:PutEvents"]
    resources = ["arn:${local.partition}:events:${local.region}:${local.account_id}:event-bus/${var.prefix}-*"]
  }

  statement {
    sid = "OwnQueues"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = ["arn:${local.partition}:sqs:${local.region}:${local.account_id}:${var.prefix}-*"]
  }

  statement {
    sid = "OwnStateMachines"
    actions = [
      "states:StartExecution",
      "states:DescribeExecution",
      "states:SendTaskSuccess",
      "states:SendTaskFailure",
    ]
    resources = [
      "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${var.prefix}-*",
      "arn:${local.partition}:states:${local.region}:${local.account_id}:execution:${var.prefix}-*:*",
    ]
  }

  statement {
    sid       = "OwnFunctions"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${var.prefix}-*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${var.prefix}-workload-boundary"
  description = "Ceiling for every IAM role the aws-event-driven-orders environments create"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# -----------------------------------------------------------------------------
# Guard rails shared by both GitHub roles. ReadOnlyAccess lets Terraform
# refresh any resource, but it also reads data; these denies take the data
# reads back out, so a plan job sees configuration, never content.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "github_guardrails" {
  statement {
    sid    = "NoDataReads"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:GetRecords",
      "sqs:ReceiveMessage",
      "kinesis:GetRecords",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults",
    ]
    resources = ["*"]
  }

  statement {
    sid           = "NoObjectReadsOutsideState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${local.state_bucket_arn}/*"]
  }

  statement {
    sid     = "NotTheAuditTrail"
    effect  = "Deny"
    actions = ["s3:*", "cloudtrail:*"]
    resources = [
      "arn:${local.partition}:s3:::security-*",
      "arn:${local.partition}:s3:::security-*/*",
      "arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*",
    ]
  }

  statement {
    sid    = "OnlyThisRegion"
    effect = "Deny"
    # Global services and the calls Terraform makes to them are excluded.
    not_actions = ["iam:*", "sts:*", "organizations:Describe*", "support:*"]
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }
}

resource "aws_iam_policy" "github_guardrails" {
  name        = "${var.prefix}-github-guardrails"
  description = "Denies data reads, audit-trail access and other Regions to the aws-event-driven-orders GitHub roles"
  policy      = data.aws_iam_policy_document.github_guardrails.json
}

# -----------------------------------------------------------------------------
# Plan role: pull requests from this repository only. Reads AWS and state.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${var.prefix}-github-plan"
  description          = "GitHub Actions runs terraform plan on pull requests with this role (read only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${local.state_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "plan_guardrails" {
  role       = aws_iam_role.github_plan.name
  policy_arn = aws_iam_policy.github_guardrails.arn
}

# -----------------------------------------------------------------------------
# Dev deploy role: jobs in the GitHub "dev" environment only (main branch).
# Write access to services is added milestone by milestone, as the code that
# needs it arrives (see docs/adr/0003).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "dev_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_subject_prefix}:environment:dev"]
    }
  }
}

resource "aws_iam_role" "github_dev_deploy" {
  name                 = "${var.prefix}-github-dev-deploy"
  description          = "GitHub Actions applies the dev environment with this role (OIDC, no stored keys)"
  assume_role_policy   = data.aws_iam_policy_document.dev_deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "dev_deploy" {
  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid = "DevStateAndLock"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # terraform.tfstate and its .tflock lock file
    resources = ["${local.state_bucket_arn}/env/dev/*"]
  }

  statement {
    sid = "WorkloadRolesInsideTheBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [local.workload_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "ManageWorkloadRoles"
    actions = [
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.workload_role_arn]
  }

  statement {
    sid       = "PassWorkloadRoles"
    actions   = ["iam:PassRole"]
    resources = [local.workload_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "lambda.amazonaws.com",
        "states.amazonaws.com",
        "pipes.amazonaws.com",
        "events.amazonaws.com",
        "apigateway.amazonaws.com",
      ]
    }
  }

  # --- M2: synchronous API (DynamoDB, Lambda, HTTP API, logs) ---------------

  statement {
    sid = "DevTables"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
    ]
    resources = ["arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.prefix}-dev-*"]
  }

  statement {
    sid = "DevFunctions"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${var.prefix}-dev-*"]
  }

  statement {
    sid       = "PowertoolsLayer"
    actions   = ["lambda:GetLayerVersion"]
    resources = ["arn:${local.partition}:lambda:${local.region}:017000801446:layer:AWSLambdaPowertoolsPythonV3-*"]
  }

  statement {
    sid = "HttpApis"
    # HTTP API ARNs hold a generated ID, not a name, so this cannot be scoped
    # to aedo-dev-*. The account has no other HTTP APIs in this Region.
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = [
      "arn:${local.partition}:apigateway:${local.region}::/apis",
      "arn:${local.partition}:apigateway:${local.region}::/apis/*",
      "arn:${local.partition}:apigateway:${local.region}::/tags/*",
    ]
  }

  statement {
    sid = "DevLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.prefix}-dev-*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aedo/${var.prefix}-dev/*",
    ]
  }

  statement {
    sid = "ApiAccessLogDelivery"
    # Needed by the caller that turns on HTTP API access logging. These
    # actions do not support resource-level permissions.
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

  statement {
    sid    = "KeepTheBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dev_deploy" {
  name   = "dev-deploy"
  role   = aws_iam_role.github_dev_deploy.id
  policy = data.aws_iam_policy_document.dev_deploy.json
}

resource "aws_iam_role_policy_attachment" "dev_deploy_read_only" {
  role       = aws_iam_role.github_dev_deploy.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "dev_deploy_guardrails" {
  role       = aws_iam_role.github_dev_deploy.name
  policy_arn = aws_iam_policy.github_guardrails.arn
}
