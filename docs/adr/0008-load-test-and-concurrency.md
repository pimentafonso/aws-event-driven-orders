# 8. Load test, stock contention and concurrency

- Status: accepted
- Date: 2026-11-18

## Context

M4 showed the system stays correct when steps fail, but only at a few orders
at a time. M5 asks what happens under sustained load: whether every order
still ends correctly, where the limits are, and what an order costs.

Two limits were known in advance:

- The account allowed 10 concurrent Lambda executions in total (ADR 4), and
  AWS keeps the last 10 unreserved, so no function could reserve any.
- The API stage accepts 25 requests a second, with bursts of 50.

## Method

`scripts/load/orders.js` (k6) places SigV4-signed orders at 5, 10 and 20 a
second, 2 minutes per step: about 4,200 orders a run, each for one unit of one
of 5 products. `scripts/load_check.py` then waits for every order to settle,
checks the outcome, and reads CloudWatch for the run's window
([procedure](../load-test.md)). Stock starts at 100,000 per product, so no
order should be rejected.

Three runs on 18 November 2026:

1. with the 10-execution account limit;
2. the same, after fixing the bug run 1 found;
3. after the limit was raised to 1,000 and each function given its own
   reserved concurrency.

## Results

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Account limit | 10 | 10 | 1,000, with reserved concurrency |
| Requests | 4,203 | 4,203 | 4,201 |
| Refused with 5xx (API function throttled) | 31 | 34 | 0 |
| Orders confirmed | 4,066 | 4,169 (all) | 4,201 (all) |
| Wrongly rejected as `OUT_OF_STOCK` | 106 | 0 | 0 |
| DynamoDB transaction conflicts | 106 | 110 | 117 |
| Lambda throttles | 155 | 158 | 0 |
| Peak concurrent executions | 10 | 10 | 17 |
| API latency p50 / p95 / p99, k6 | 114 / 226 / 329 ms | 103 / 149 / 231 ms | 103 / 171 / 251 ms |
| API latency p99 at 20 a second, k6 | 320 ms | 203 ms | 154 ms |
| Saga duration p50 / p95 / p99 | 362 / 454 / 1,455 ms | 365 / 480 / 1,495 ms | 365 / 470 / 1,467 ms |
| Notification p50 / p95 / p99 | 0.72 / 2.3 / 4.0 s | 0.69 / 2.2 / 4.1 s | 0.62 / 1.08 / 1.15 s |
| Alarms that fired | `lambda-throttles`, `api-5xx` | `lambda-throttles`, `api-5xx` | none |

In every run, the stock taken from each product equalled the quantity
confirmed for it, every confirmed order was notified exactly once on its first
delivery, no saga execution failed, and both dead-letter queues stayed empty.
API latency is measured by k6 from the client, so it includes the network;
the notification time runs from `OrderConfirmed` to the notification being
written. The raw output is in [`docs/load-results/`](../load-results/).

## Decisions

**A transaction that loses a race is retried, not treated as out of stock.**
Run 1 rejected 106 orders as out of stock while every product had over 99,000
units. DynamoDB recorded exactly 106 `TransactionConflict`s: with 5 products at
20 orders a second, two reservations sometimes update the same stock item at
once, and DynamoDB cancels one of them. `reserve()` read any cancellation
reason on a stock item as "out of stock". `release()`, the compensation, had
the same flaw the other way: a conflict looked like "already released", which
would have left the order `RESERVED` and its stock taken. Both now raise
`StockContentionError` for `TransactionConflict`, `ThrottlingError` and
`ProvisionedThroughputExceeded`; the state machine retries it up to 5 times
with jittered backoff, and an order is out of stock only when DynamoDB says
its stock condition failed. Runs 2 and 3 had 110 and 117 conflicts, and every
one was retried successfully.

The unit tests had passed with this bug: moto does not produce transaction
conflicts, and nothing in M3 or M4 ran orders concurrently enough to cause
one. As with the `ClientRequestToken` limit in M3, only AWS found it.

**Each function reserves its own concurrency.** With 10 executions for the
whole account, the API function lost 31 to 34 requests a run to throttling,
and the saga and the notifier were throttled 120-odd more times, which
retries absorbed. Once AWS raised the limit to 1,000, each function got a
reservation that is also its ceiling:

| Function | Reserved | Why |
|---|---|---|
| `orders-api` | 50 | a burst on the API cannot take the executions the saga needs; the stage throttle (25 rps) is the first limit |
| `saga-steps` | 50 | 3 to 4 short steps per order; a runaway saga cannot starve the API |
| `notifier` | 10 | the SQS event source mapping's maximum concurrency is 5, below it |

The notifier's mapping must stay below its reservation. If Lambda throttled
the poller, the batch would go back to the queue and count towards the 3
receives before the dead-letter queue, so throttling alone could dead-letter
good messages. 110 of the 1,000 executions are reserved and 890 stay shared.
Run 3 peaked at 17 concurrent executions at 20 orders a second, well under
every cap.

## What the numbers say

- **The 10-execution limit caused every refused order.** The API's 5xx count
  matched the API function's throttles exactly in both runs, and both went to
  0 once the limit was raised.
- **The notification tail came from queueing.** Notification p99 fell from
  about 4 s to 1.15 s once the notifier stopped being throttled and could run
  5 batches at once instead of 2.
- **The saga's p99 comes from stock contention, not capacity.** It stayed near
  1.5 s in run 3 with no throttling. 2.8% of orders lost a stock race and
  waited for the retry, whose first wait is up to 1 s, so the slowest 1% are
  likely orders that retried. Many more products, or orders spread across them,
  would make conflicts rarer; with 5 products at 20 orders a second they are
  expected. Every conflicted order was confirmed.
- **Each retried conflict counts as a Lambda error** on `saga-steps` (117 in
  run 3). No alarm watches that function's errors; the saga's own alarm
  (`saga-executions-failed`) watches outcomes, which stayed clean.

## Cost

Calculated from run 3's measured usage (4,201 orders, 16:18 to 16:30 UTC)
at the eu-west-1 list prices from the AWS Price List API, scaled to a million
orders. The free tier is left out, because it would cover most of a run this
size and none of a million orders.

| Service | Measured in run 3 | Per million orders | Share |
|---|---|---|---|
| Step Functions Standard | 4 state transitions per order, plus 117 retries | $100.70 | 79% |
| CloudWatch Logs ingestion | 98.5 MB, 74% of it the saga's execution log | $12.45 | 10% |
| DynamoDB writes | 42,483 write units (transactions cost double) | $7.13 | 6% |
| EventBridge custom events | 2 per order (`OrderPlaced`, `OrderConfirmed`) | $2.00 | 2% |
| SQS requests | at most 3 per order, plus 558 empty receives | $1.25 | 1% |
| API Gateway HTTP API | 1 request per order | $1.11 | 1% |
| Lambda requests | 21,069 invocations, 5 per order | $1.00 | 1% |
| Lambda duration | 676 s at 256 MB, arm64 | $0.54 | <1% |
| DynamoDB reads | 13,443 read units | $0.45 | <1% |
| EventBridge Pipes | 1 event per order after the filter | $0.40 | <1% |
| **Total** | | **$127.03** | |

That is $0.000127 per order, and about $0.53 for run 3. Not included: X-Ray
traces (sampled; not measured), log storage, and the fixed monthly cost of
metrics, alarms and the dashboard, which the free tier covers here. The SQS
figure is an upper bound, because CloudWatch counts messages, not the batched
calls that are billed. The figures will be checked against the bill once it
shows 18 November.

**Step Functions Standard is four fifths of the cost.** It bills each state
transition, $25 per million, and every order makes 4. Express workflows bill
by request and duration instead: $1 per million requests, and the saga's
average of 392 ms would cost about $0.42 per million at the minimum 64 MB.
The saga on Express would cost about $1.42 per million instead of $100.70,
bringing the total to about $28. It stays on Standard: at this project's
volume the free tier's 4,000 transitions a month cover about 1,000 orders,
and Standard gives what the runbook and the fault experiment rely on, which
Express does not: execution history kept by the service, and redriving a
failed execution from the failed step. Because every step is already
idempotent, Express's at-least-once starts would be safe, so the switch is a
volume decision, not a design one.

**The saga's execution log is the second-largest cost.** It logs every state
with its input and output, about 17 KB per order, which duplicates the
execution history that Standard keeps anyway. Logging only errors would save
about $9 per million orders.

**The pipe costs money while idle.** It polls the table's stream 8 times a
second whether or not orders arrive: 28,790 `GetRecords` calls an hour,
measured overnight with no traffic. That is about 21 million stream reads a
month; above the free 2.5 million they cost $0.226 per million, about $4.18 a
month for one shard. A Lambda function reading the stream would read it free,
but would put back the code the pipe replaced.

## Consequences

- The load test, the check and the procedure stay in the repository, so the
  numbers can be reproduced.
- ADR 4's and ADR 5's statements that no concurrency could be reserved, and
  that the notifier is capped at 2, are replaced by this ADR.
- The stage throttle is now the API's first limit, and reserved concurrency is
  the second. A run above 25 requests a second would show the throttle's 429s;
  none was run.
