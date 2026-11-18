# DynamoDB tables for the orders service. Both are on-demand, so an idle
# environment pays only for storage.

resource "aws_dynamodb_table" "orders" {
  #checkov:skip=CKV_AWS_119:AWS-owned encryption keys on purpose; a customer-managed KMS key costs $1/month per environment and adds nothing for demo data.
  name         = "${var.name_prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # New orders flow to EventBridge through a pipe (modules/events).
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  deletion_protection_enabled = var.deletion_protection
}

# Powertools idempotency records: one item per Idempotency-Key, removed by TTL.
resource "aws_dynamodb_table" "idempotency" {
  #checkov:skip=CKV_AWS_119:Same reason as the orders table.
  #checkov:skip=CKV_AWS_28:Records expire after a day; restoring them would only bring back stale keys.
  name         = "${var.name_prefix}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "expiration"
    enabled        = true
  }

  deletion_protection_enabled = var.deletion_protection
}
