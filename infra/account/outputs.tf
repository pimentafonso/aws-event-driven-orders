output "plan_role_arn" {
  description = "Role that pull requests assume to run terraform plan."
  value       = aws_iam_role.github_plan.arn
}

output "dev_deploy_role_arn" {
  description = "Role that the GitHub dev environment assumes to apply."
  value       = aws_iam_role.github_dev_deploy.arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary every workload role must carry."
  value       = aws_iam_policy.workload_boundary.arn
}

output "dev_test_role_arn" {
  description = "Role that the GitHub dev environment assumes to run the end-to-end test."
  value       = aws_iam_role.github_dev_test.arn
}
