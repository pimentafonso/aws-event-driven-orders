variable "region" {
  description = "Region the GitHub roles may deploy to."
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix of every resource name in this project."
  type        = string
  default     = "aedo"
}

variable "state_bucket" {
  description = "Terraform state bucket (contains the account ID; passed by scripts/account.sh)."
  type        = string
}

variable "github_subject_prefix" {
  description = <<-EOT
    Start of the OIDC sub claim for this repository. The repository uses
    GitHub's immutable subjects (owner@owner_id/repo@repo_id), so a renamed or
    re-created repository with the same name cannot assume these roles.
  EOT
  type        = string
  default     = "repo:pimentafonso@350777569/aws-event-driven-orders@1462094778"
}
