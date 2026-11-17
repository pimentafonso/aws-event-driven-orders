terraform {
  # 1.10+ for S3 native state locking (use_lockfile), added in M1.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }
}
