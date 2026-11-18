# Fault switch for resilience experiments (see src/faults.py and
# scripts/fault_experiment.py). Terraform creates it with every rate at 0 and
# then leaves the value alone, so an experiment can change it without a deploy
# and without the next apply undoing it.

resource "aws_ssm_parameter" "faults" {
  #checkov:skip=CKV2_AWS_34:Holds two failure rates, nothing secret; a SecureString would add a KMS decrypt to every read.
  name        = "/${var.name_prefix}/faults"
  description = "Fault injection rates (0 to 1) for the saga steps and the notifier"
  type        = "String"
  value = jsonencode({
    payment_unavailable_rate = 0
    notifier_failure_rate    = 0
  })

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_iam_policy_document" "read_faults" {
  statement {
    sid       = "ReadFaultSwitch"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.faults.arn]
  }
}
