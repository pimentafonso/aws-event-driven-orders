# Load test

The load test places orders through the API at stepped rates and then checks
that every order ended correctly. Two scripts do the work:

- `scripts/load/orders.js` (k6) places the orders. Each step of the load is
  its own k6 scenario, so the summary reports API latency per step.
- `scripts/load_check.py` waits for the run's orders to settle, checks them,
  and collects the CloudWatch figures for the run's time window.

## Before a run

- **Check the cost.** Step Functions Standard charges $0.025 per 1,000 state
  transitions above the free 4,000 a month. Each order takes 4 transitions,
  so a 4,200-order run costs about $0.42 in Step Functions and about $0.53 in
  all ([ADR 8](adr/0008-load-test-and-concurrency.md#cost)).
- **Check the account's Lambda concurrency** with
  `aws lambda get-account-settings`. The functions reserve 110 executions
  (ADR 8), so the account needs a limit above 210; the default of 1,000 is
  enough. Runs 1 and 2 in ADR 8 were made with a limit of 10, before the
  reservations, and were throttled.
- **Don't deploy during a run.** The post-deploy tests reset the stock of
  SKU-1 and SKU-5, which would break the stock check.

## Running it

Needs k6 (tested with v0.43.1), the project's Python environment and an
administrator profile. Every order of a run uses the customer ID
`load-<run-id>`, so pick a run ID you have not used before.

```bash
export AWS_PROFILE=<admin profile>
endpoint=$(terraform -chdir=infra/envs/dev output -raw api_endpoint)
run=r1

# k6 and boto3 read the credentials from the environment.
eval "$(aws configure export-credentials --format env)"

python scripts/seed_stock.py 100000
k6 run -e API_ENDPOINT="$endpoint" -e RUN_ID="$run" \
  -e RATES=5,10,20 -e STEP_SECONDS=120 -e SUMMARY="load-$run.json" \
  scripts/load/orders.js
python scripts/load_check.py "$run" --start-stock 100000 --out "check-$run.json"
```

`RATES` and `STEP_SECONDS` above are the defaults: 5, 10 and 20 orders a
second for 2 minutes each, about 4,200 orders. A step can place one more order
than rate × seconds, because k6 starts the first iteration at time zero.

The API's stage throttle is 25 requests a second with a burst of 50. Requests
above it get `429` and are counted as `orders_throttled` in the k6 summary.

## What the check reports

Checks, each PASS or FAIL:

- every order of the run reached a final status, and every one is CONFIRMED;
- the stock taken from each product equals the quantity confirmed for it;
- every confirmed order has its notification;
- no saga execution failed, timed out or was aborted;
- both dead-letter queues are empty.

Measurements, written to the `--out` file:

- notification time from `OrderConfirmed` to the notification being written
  (p50, p95, p99, max), and how many deliveries each notification took;
- saga duration and API latency (p50, p95, p99, max), from CloudWatch;
- saga executions started and throttled, API requests, 4xx and 5xx;
- Lambda errors, throttles and peak account concurrency (one-minute maximum);
- the notification queue's oldest message, and pipe failures.

CloudWatch publishes these one to three minutes late, so the check waits until
3 minutes after the last order before reading them.

## Cost per order

ADR 8 calculates it from the run's usage: Lambda invocations and duration,
DynamoDB capacity consumed, API requests, SQS messages, log bytes ingested
(all from CloudWatch), and state transitions counted from execution
histories, each at the eu-west-1 list price. To check it against the bill,
open Cost Explorer 24 to 48 hours after the run, group by usage type for the
day of the run, and subtract a quiet day.

## Trial run

Before the real run, 1 order a second for 5 seconds (run `trial1`) placed 6
orders, and every check passed. Saga duration had a median of 2.0 s and a
maximum of 2.6 s; notifications a median of 2.4 s and a maximum of 4.0 s. Both
are slower than in the end-to-end tests, probably because the functions had
been idle and started cold.
