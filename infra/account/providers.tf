provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-event-driven-orders"
      Scope     = "account"
      ManagedBy = "terraform"
    }
  }
}
