# 5. Event flow and order saga

- Status: accepted; the concurrency limits are superseded by [ADR 8](0008-load-test-and-concurrency.md)
- Date: 2026-11-18

## Context

After an order is stored, three things must happen: reserve stock, take
payment and notify the customer. If payment fails, the reserved stock must be
given back. Each step can fail, be retried or run twice, because AWS event
delivery is at least once.

## Decisions

**The table stream is the outbox.** The API only writes the order to DynamoDB.
The table's stream feeds an EventBridge Pipe, which publishes `OrderPlaced`.
Writing the order and publishing the event are therefore one operation: there
is no "saved but never announced" (or "announced but never saved") case, which
a direct `PutEvents` call from the API would allow. The pipe filters to new
`ORDER` items only, so stock and notification writes never produce events.

**Orchestration, not choreography, for the saga.** A Step Functions state
machine runs reserve -> charge -> confirm, and on a failed payment runs the
compensating step (release stock). The whole flow, including the
compensation, is visible in one definition (`infra/modules/events/saga.asl.json`)
and in each execution's history. Choreography (services reacting to each
other's events) would spread the same logic over several rules and handlers.

**Standard workflow, not Express.** Standard keeps a full, searchable
execution history for 90 days and runs each state exactly once. Express is
cheaper at high volume but at least once per state and keeps history only in
CloudWatch Logs. At this project's volume Standard costs very little; the M5
load test will put a measured number on it.

**Idempotent steps instead of exactly-once delivery.** Every step checks the
order's status before acting and changes it with a DynamoDB condition, inside a
transaction with the stock updates. Retrying a step, or running a second
execution for the same order, changes nothing the second time. The simulated
payment derives its payment ID from the order ID, so a retried charge would
reuse the provider's idempotency key.

**Notifications go through SQS.** `OrderConfirmed` events reach the notifier
through a queue with a dead-letter queue (three receives). The consumer
reports failures per message, so one bad message does not fail its batch, and
it records each notification with a conditional write, so duplicates are
skipped. `scripts/redrive_dlq.sh` moves dead-lettered messages back after a fix.

## Consequences

- A rejected order ends the execution in a `Succeed` state: rejection is a
  business outcome. Executions only fail on technical errors, which is what the
  M4 alarms will watch.
- If confirming fails after payment succeeded, the execution fails and the
  order stays `RESERVED`; a real system would need a refund path. Out of scope
  here, and noted.
- The notifier's concurrency is capped at 2, because the account allows 10
  concurrent Lambda executions in total.
