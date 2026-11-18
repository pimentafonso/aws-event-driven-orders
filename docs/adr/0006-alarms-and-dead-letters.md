# 6. Alarms, dashboard and dead-letter queues

- Status: accepted
- Date: 2026-11-18

## Context

After M3 the happy path and the business failures (out of stock, declined
payment) worked, but two technical failures had no safety net:

- The pipe retried a failing record five times and then dropped it, so the
  order stayed `PENDING` with no trace.
- The `OrderPlaced` and `OrderConfirmed` rules retried for an hour and then
  dropped the event.

Nothing told anyone when something went wrong either: there were logs and
metrics, but no alarms.

The account is on the AWS free plan. CloudWatch gives 10 alarm metrics,
3 dashboards and 10 custom metrics free each month; beyond that, alarms cost
$0.10 per metric and custom metrics $0.30 each per month.

## Decisions

**One dead-letter queue for event delivery.** The pipe and both rule targets
send what they cannot deliver to `aedo-dev-events-dlq`. One queue keeps it to
one alarm. The two senders are easy to tell apart: rule messages are the event
with `RULE_ARN` and `ERROR_CODE` attributes, while pipe messages describe the
failed stream records. The notification queue keeps its own dead-letter queue,
because its messages are redriven to their source with SQS's move task, which
the events queue cannot use.

**Alarms on symptoms that need a person, one metric each.** Eight alarms:
both dead-letter queues not empty, notification backlog older than five
minutes, failed saga executions, pipe failures, API 5xx, notifier errors and
Lambda throttles anywhere in the account. Each watches a single metric, so all
eight fit in the free ten. Rejected orders are not alarmed on: a rejection is a
business result, and the saga ends in success for it. The saga steps
function's own `Errors` metric is not alarmed on for the same reason, since
`OutOfStockError` and `PaymentDeclinedError` are raised as Lambda errors on
purpose.

**Every alarm links to the runbook.** The alarm description ends with a link to
its section in `docs/runbook.md`, so the email says what to do next.

**Email by a subscription made by hand.** Terraform creates the SNS topic and a
topic policy that only lets this project's alarms publish. The email address is
subscribed with one CLI command, so it is never in the repository or the state.
The topic is not encrypted with KMS: CloudWatch cannot publish to a topic that
uses the AWS managed key, and a customer managed key costs $1 a month for
messages that hold only alarm names.

**A notification latency metric, split by hop in the logs.** The notifier
records when `OrderConfirmed` was published, when it reached the queue and
when Lambda first received it. Only the total is a custom metric
(`NotificationLatency`), which brings the project to 8 of the 10 free custom
metrics; the per-hop split is in the log line and on the stored notification.

## Consequences

- An event that cannot be delivered is kept for 14 days and raises an alarm.
- A pipe dead letter holds stream positions, not the order, so recovering it is
  a manual step (see the runbook). The order itself is safe in the table.
- New alarms or custom metrics now have a cost line to check: two more of
  each are free, after that they are billed.
