provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-event-driven-orders"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
