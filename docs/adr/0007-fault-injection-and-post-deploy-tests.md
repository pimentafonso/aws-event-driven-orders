# 7. Fault injection and post-deploy tests

- Status: accepted
- Date: 2026-11-18

## Context

The unit tests run the handlers against DynamoDB mocked by moto. They cannot
show what the deployed system does when a step fails: Step Functions' retries,
SQS redelivery and the dead-letter queues only exist in AWS. M3 also showed
that moto misses real limits: the 36-character `ClientRequestToken` limit was
only found by the first run on AWS.

## Decisions

**A fault switch in Parameter Store, read at run time.** `/aedo-dev/faults`
holds two failure rates: the payment provider not answering, and the notifier
failing a message. The functions cache it for 10 seconds, so an experiment
turns faults on and off without a deploy. Terraform creates the parameter at 0
and ignores later changes to its value. If the switch cannot be read, every
rate is 0. AWS Fault Injection Service was not used: its Lambda actions inject
generic errors or latency at the runtime level, while these faults are named
errors that the state machine handles on purpose.

**An unavailable payment provider is retried, then compensated.** The charge
step raises `PaymentProviderUnavailableError`. The state machine retries it
3 times with jittered backoff; if all 4 attempts fail, the existing compensation
releases the stock and rejects the order as `PAYMENT_FAILED`.

**A failed batch is reported per message.** When every message in a batch
fails, Powertools fails the whole invocation by default. A batch holding a
single bad message would then count as a Lambda error. The notifier now
reports each failed message instead, so `notifier-errors` stays a signal about
the function, and the dead-letter queue handles bad messages.

**End-to-end tests after every deploy, against dev.** A second job in the
deploy workflow runs `smoke_api.py` and `e2e_saga.py` once the apply finishes.
It uses its own role, `aedo-github-dev-test`, which can call the API, read
orders and set stock for `PRODUCT#` keys, and nothing else. A temporary stack
per run was considered: it isolates better, but it takes five to six minutes
per run, roughly doubles the deploy role's permissions, and a failed destroy
leaves resources running. With one developer and one environment, testing dev
right after it changes catches the same problems.

## Results

`scripts/fault_experiment.py`, two runs of 20 orders each. The payment provider
failed 50% of attempts, and the notifier failed 50% of deliveries:

| | Run 1 | Run 2 |
|---|---|---|
| Orders confirmed | 18 | 20 |
| Rejected as `PAYMENT_FAILED` (all 4 attempts failed) | 2 | 0 |
| Confirmed after 1 to 3 failed charge attempts | 6 | 7 |
| Saga executions that failed | 0 | 0 |
| Stock taken | 18, equal to confirmed | 20, equal to confirmed |
| Notified on the 1st / 2nd / 3rd delivery | 7 / 7 / 3 | 10 / 6 / 3 |
| Dead-lettered after 3 failed deliveries | 1 | 1 |

The dead-lettered notifications were sent after `scripts/redrive_dlq.sh` moved
them back with the switch at 0. `notifications-dlq-not-empty` went to ALARM
when they arrived and back to OK after the redrive; `notifier-errors` stayed OK
throughout. No order was notified twice: each order has one notification item,
written with a condition.

The first run's script reported the dead-lettered notification as missing. It
counted the queue with SQS's approximate message counts, which had not caught
up. The script now reads the messages themselves.

## Consequences

- Every merge to `main` is followed by the smoke test and the end-to-end test
  against the deployed stack, so a deploy that breaks the order flow fails the
  workflow.
- The tests write orders to dev and reset the stock of two test products each
  run.
- Fault experiments need an administrator, because they change the switch and
  read execution history; CI does not run them.
