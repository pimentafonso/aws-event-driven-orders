#!/usr/bin/env bash
# Plan or apply the account root module (GitHub roles and the workload
# permissions boundary). Run by an administrator, never from CI.
#
# Usage: AWS_PROFILE=<admin profile> bash scripts/account.sh plan|apply
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

action=${1:-plan}
case "$action" in
  plan | apply) ;;
  *) echo "Usage: $0 plan|apply" >&2; exit 2 ;;
esac

tf_init account
# apply shows the plan and waits for "yes"; plan never prompts.
input=false
if [ "$action" = apply ]; then input=true; fi
terraform -chdir=infra/account "$action" -input="$input" \
  -var="state_bucket=$(state_bucket)"
