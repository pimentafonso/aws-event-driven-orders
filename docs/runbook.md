# Runbook

What to do when an alarm fires. Every alarm email links to its section here.
Commands assume an administrator profile (`export AWS_PROFILE=...`) and
Region `eu-west-1`; names are for the `dev` environment.

Start with the `aedo-dev-orders` dashboard. Its rows follow an order through
the system: API, saga, events, notifications, then the Lambda functions.

## notifications-dlq-not-empty

A notification failed three times and SQS moved it to
`aedo-dev-notifications-dlq`. The other messages in its batch were not affected
(partial batch responses).

1. Find the reason in the notifier's logs:
   CloudWatch Logs Insights on `/aws/lambda/aedo-dev-notifier`,
   `filter level = "ERROR" or ispresent(exception) | sort @timestamp desc`.
2. A message that is not an `OrderConfirmed` event (`InvalidMessageError`) will
   never succeed: read it with `aws sqs receive-message`, then delete it.
3. For anything else, fix the cause, then move the messages back:
   `bash scripts/redrive_dlq.sh`. A redriven notification that was already sent
   is skipped, because the notifier writes each order's notification once.

## events-dlq-not-empty

An event was not delivered and went to `aedo-dev-events-dlq`. Two senders use
this queue:

- **A rule** (`OrderPlaced` to the saga, or `OrderConfirmed` to the
  notification queue) gave up after its retries. The message is the event
  itself; its attributes `RULE_ARN`, `TARGET_ARN` and `ERROR_CODE` say which
  rule and why. Fix the target, then publish the event again with
  `aws events put-events` (the saga and the notifier ignore duplicates).
- **The orders pipe** could not publish after five attempts. For a DynamoDB
  stream source the message holds the shard and sequence numbers of the failed
  records, not the records. The orders are still in the table as `PENDING`:
  find them by the sequence numbers' time and start the saga for each one with
  `aws stepfunctions start-execution`, input
  `{"detail": {"order_id": "<id>"}}`.

## notifications-backlog

The oldest message in `aedo-dev-notifications` has waited more than five
minutes, so notifications are late.

1. Check the notifier on the dashboard: errors, duration and throttles.
2. Check that the event source mapping is enabled:
   `aws lambda list-event-source-mappings --function-name aedo-dev-notifier`.
3. Throttling means other functions are using the account's 10 concurrent
   executions; see `lambda-throttles`.

## saga-executions-failed

An order saga execution failed. Rejected orders (out of stock, declined
payment) end in success, so this is a technical failure, and the order is
probably stuck in `PENDING` or `RESERVED`.

1. Open the failed execution in the Step Functions console and read the
   failed step's error.
2. Fix the cause (a deploy, a permission, a quota).
3. Run the same execution again from the failed step:
   `aws stepfunctions redrive-execution --execution-arn <arn>`. Every step is
   idempotent, so steps that already succeeded are safe to run again.

## pipe-failures

The pipe from the orders table stream failed to publish `OrderPlaced`. New
orders stay `PENDING` until it recovers. Records that fail five times go to
`aedo-dev-events-dlq` (see `events-dlq-not-empty`).

1. Check the pipe's state: `aws pipes describe-pipe --name aedo-dev-orders-placed`.
2. Check the bus still exists and the pipe role can `events:PutEvents` to it.

## api-5xx

The orders API returned a server error.

1. The API's access log (`/aedo/aedo-dev/api-access`) shows the route,
   status and `integrationError` for each request.
2. The function's log (`/aws/lambda/aedo-dev-orders-api`) has the exception.
   Each request ID matches across both logs.

## notifier-errors

The notifier failed as a whole, for example a timeout or an import error,
rather than one bad message. The whole batch will be retried and can end in
the dead-letter queue.

Check the function's log for the error and the recent deploys in GitHub
Actions. Once fixed, redrive anything in the dead-letter queue.

## lambda-throttles

Lambda refused an invocation because the account's 10 concurrent executions
were in use. Step Functions and the SQS event source mapping retry throttled
calls, so this usually means delay, not loss.

If it happens under normal load, request a higher
"Concurrent executions" quota in Service Quotas (free). The notifier is capped
at 2 concurrent executions so it can never take all 10.
