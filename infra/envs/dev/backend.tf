terraform {
  # The bucket name contains the account ID, so it is passed at init time:
  #   terraform init -backend-config="bucket=<account-id>-aedo-tfstate"
  backend "s3" {
    key          = "env/dev/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
