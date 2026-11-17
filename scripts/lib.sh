#!/usr/bin/env bash
# Shared settings for the scripts. Sourced, not run.

# Used by the scripts that source this file.
# shellcheck disable=SC2034
REGION=${AWS_REGION:-eu-west-1}
PROJECT_PREFIX=aedo

account_id() {
  aws sts get-caller-identity --query Account --output text
}

# The bucket name holds the account ID, so it is worked out at run time and
# never committed.
state_bucket() {
  echo "$(account_id)-${PROJECT_PREFIX}-tfstate"
}

# terraform init for a root module under infra/, against the state bucket.
tf_init() {
  local dir=$1
  terraform -chdir="infra/$dir" init -input=false -reconfigure \
    -backend-config="bucket=$(state_bucket)"
}
