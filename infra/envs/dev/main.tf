locals {
  name_prefix = "aedo-${var.environment}"
}

# Created by the account module (infra/account); every role here must carry it.
data "aws_iam_policy" "workload_boundary" {
  name = "aedo-workload-boundary"
}

module "data" {
  source      = "../../modules/data"
  name_prefix = local.name_prefix
}

module "api" {
  source = "../../modules/api"

  name_prefix              = local.name_prefix
  source_dir               = "${path.module}/../../../src"
  powertools_layer_arn     = var.powertools_layer_arn
  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  orders_table_name      = module.data.orders_table_name
  orders_table_arn       = module.data.orders_table_arn
  idempotency_table_name = module.data.idempotency_table_name
  idempotency_table_arn  = module.data.idempotency_table_arn
}

module "events" {
  source = "../../modules/events"

  name_prefix              = local.name_prefix
  source_dir               = "${path.module}/../../../src"
  powertools_layer_arn     = var.powertools_layer_arn
  permissions_boundary_arn = data.aws_iam_policy.workload_boundary.arn

  orders_table_name = module.data.orders_table_name
  orders_table_arn  = module.data.orders_table_arn
  orders_stream_arn = module.data.orders_stream_arn
}
