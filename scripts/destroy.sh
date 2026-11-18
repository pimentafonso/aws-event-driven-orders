#!/usr/bin/env bash
# Tear the project down.
#
#   bash scripts/destroy.sh          destroy the dev environment only
#   bash scripts/destroy.sh --all    also destroy the account module (GitHub
#                                    roles, boundary) and delete the state
#                                    bucket with every object version in it
#
# Run with an administrator profile: AWS_PROFILE=<profile> bash scripts/destroy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

all=false
[ "${1:-}" = --all ] && all=true
bucket=$(state_bucket)

if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
  echo "No state bucket ($bucket): nothing to destroy."
  exit 0
fi

echo "Destroying dev environment"
tf_init envs/dev
terraform -chdir=infra/envs/dev destroy -input=false -auto-approve

if [ "$all" != true ]; then
  echo "Done. Account module and state bucket kept (use --all to remove them)."
  exit 0
fi

echo "Destroying account module"
tf_init account
terraform -chdir=infra/account destroy -input=false -auto-approve \
  -var="state_bucket=$bucket"

echo "Deleting state bucket $bucket and all its object versions"
# Delete every object version and delete marker, up to 1,000 per call.
versions='[Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}'
remaining() {
  aws s3api list-object-versions --bucket "$bucket" --max-items 1000 \
    --query "length($versions)" --output text
}
next_batch() {
  aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json \
    --query "{Objects: $versions, Quiet: \`true\`}"
}
while [ "$(remaining)" != 0 ]; do
  aws s3api delete-objects --bucket "$bucket" --delete "$(next_batch)" >/dev/null
done
aws s3api delete-bucket --bucket "$bucket"
echo "Everything removed."
