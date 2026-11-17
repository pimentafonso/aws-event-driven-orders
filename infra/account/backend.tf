terraform {
  # Same bucket as the environments, passed at init time by scripts/account.sh.
  backend "s3" {
    key          = "account/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
