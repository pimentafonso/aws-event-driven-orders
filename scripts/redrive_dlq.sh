#!/usr/bin/env bash
# Move every message in a dead-letter queue back to its source queue, once the
# cause of the failures is fixed. Uses SQS's built-in message move task.
#
# Usage: bash scripts/redrive_dlq.sh [dlq-name]     (default: aedo-dev-notifications-dlq)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

dlq=${1:-${PROJECT_PREFIX}-dev-notifications-dlq}
url=$(aws sqs get-queue-url --region "$REGION" --queue-name "$dlq" --query QueueUrl --output text)
arn=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$url" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
depth=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$url" \
  --attribute-names ApproximateNumberOfMessages \
  --query Attributes.ApproximateNumberOfMessages --output text)

if [ "$depth" = 0 ]; then
  echo "$dlq is empty: nothing to redrive."
  exit 0
fi

echo "Moving about $depth message(s) from $dlq back to its source queue"
task=$(aws sqs start-message-move-task --region "$REGION" --source-arn "$arn" \
  --query TaskHandle --output text)

while true; do
  status=$(aws sqs list-message-move-tasks --region "$REGION" --source-arn "$arn" \
    --max-results 1 --query 'Results[0].[Status,ApproximateNumberOfMessagesMoved]' --output text)
  echo "  $status"
  case "$status" in
    COMPLETED*) break ;;
    FAILED* | CANCELLED*) echo "Move task $task did not complete" >&2; exit 1 ;;
  esac
  sleep 5
done
