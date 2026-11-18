# What three load tests found in an event-driven order system

This project is an order system on AWS serverless, built with Terraform: an
HTTP API, DynamoDB, an EventBridge Pipe that turns the table's stream into
events, a Step Functions saga that reserves stock, charges a simulated payment
and compensates when payment fails, and an SQS consumer that sends
notifications. The happy path is the easy part. The point of the project was
the rest: proving, with measurements on AWS, that it stays correct when things go
wrong, and finding out what it costs.

## The design in one paragraph

The API writes one item, the order, and nothing else. The table's stream is the
outbox: an order cannot be saved without its event, so there is no dual-write
problem. Every saga step checks the order's status before acting and uses a
DynamoDB transaction, so duplicate events and retries are harmless. Anything
that cannot be delivered ends up in a dead-letter queue with an alarm on it,
never silently dropped. Eight alarms email me, and each links to a runbook
section saying what to do.

## What only AWS could find

The unit tests run the real handlers against DynamoDB mocked by moto. They
passed every time. Four problems still reached AWS:

1. **A 36-character limit.** DynamoDB's `ClientRequestToken` for idempotent
   transactions is at most 36 characters. moto does not check it; the first
   saga run on AWS failed on it.
2. **A one-second setting that cost twenty.** The notification queue's event
   source mapping had a batching window of 1 second. Measured end to end,
   notifications took 11 to 21 seconds. With the window at 0 they take 0.5 to
   0.8 seconds.
3. **A provider default.** The first deploy that gave the pipe a dead-letter
   queue failed: the Terraform AWS provider sent a maximum record age of 0,
   which AWS rejects. Setting -1 (no limit) explicitly fixed it.
4. **A race that looked like an empty shelf.** This one matters most, and the
   load test found it.

## The race

The load test places orders at 5, 10 and 20 a second for two minutes each,
about 4,200 orders, spread over five products with 100,000 units each. No order
should be rejected. The first run rejected 106 as out of stock.

DynamoDB's metrics showed exactly 106 `TransactionConflict`s. At 20 orders a
second over five products, two reservations sometimes update the same stock
item at the same moment, and DynamoDB cancels one transaction. The reserve
step treated every cancellation reason as "not enough stock". The compensation
step had the mirror-image bug: a conflict looked like "already released", so a
failed payment could have left an order reserved and its stock gone for good.

The fix is small. A conflict, or a throttle, now raises its own error, which
the state machine retries with jittered backoff; only a failed stock condition
means out of stock. The next run had 110 conflicts and confirmed every order.
The lesson is broader: the unit tests could not produce this, and neither could
the end-to-end tests, which place one order at a time.

## The limit nobody mentions

The account allowed 10 concurrent Lambda executions in total, not the usual
1,000. The first two runs lost 31 and 34 orders to it: the API's 5xx count
matched the API function's throttles exactly. After AWS raised the limit, each
function got its own reserved concurrency, so a burst on the API cannot starve
the saga. The third run:

- 4,201 of 4,201 orders confirmed, stock exact for every product;
- 0 throttles, 0 errors returned to the client, 0 dead-lettered messages;
- API latency p50 103 ms, p99 251 ms, measured by the client;
- notification p99 down from about 4 s to 1.15 s;
- 17 concurrent executions at peak.

## What it costs

From run 3's measured usage at list prices: **$127 per million orders**, and
79% of it is Step Functions Standard, which bills each of the 4 state
transitions an order makes. Express workflows would cut the total to about $28,
but give up the execution history and redrive that the runbook relies on. At
this project's volume the free tier covers it; at a million orders a month the
switch would be worth it, and the idempotent steps already make it safe. The
second-largest cost was a surprise: the saga's execution log, at 17 KB an
order, duplicated history that Standard keeps anyway.

## What I would tell someone building this

- Test on the real service early, and under concurrency. Mocks agree with your
  assumptions.
- Count cancellation reasons, not cancellations. A DynamoDB transaction can
  fail for reasons that have nothing to do with your data.
- Check your account's quotas before you load test, and read your own 5xx
  against throttles: here they matched one for one.
- Measure the cost per unit of work. The expensive part was not compute.

Code, ADRs and raw results: the [repository](../README.md),
[ADR 8](adr/0008-load-test-and-concurrency.md) and
[`docs/load-results/`](load-results/).
