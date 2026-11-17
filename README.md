# aws-event-driven-orders

Event-driven order processing on AWS serverless, built with Terraform.

> **Status:** work in progress (M0, repository bootstrap). Nothing is deployed yet,
> so this README has no results. Every number added later will be measured.

## What it will do

A client places an order through an HTTP API. A saga then reserves stock,
charges a simulated payment and confirms the order, or undoes the earlier
steps when one fails. The focus is on the failure paths that tutorials skip:

- **Duplicate requests and deliveries**: an `Idempotency-Key` on the API and
  idempotent consumers, so retries never create a second order or charge.
- **Partial failures**: SQS partial batch responses, dead-letter queues and a
  redrive script.
- **Compensation**: a Step Functions saga that rolls back reserved stock when
  payment fails.
- **Proof**: fault-injection tests, a load test and the real cost per million
  orders, taken from the AWS bill.

## Planned architecture

| Layer | Services |
|---|---|
| API | API Gateway HTTP API, Lambda (Python 3.13, Powertools) |
| State | DynamoDB (single table, on-demand) |
| Events | DynamoDB Streams, EventBridge Pipes, EventBridge custom bus |
| Workflow | Step Functions (saga with compensation) |
| Messaging | SQS with dead-letter queues |
| Observability | CloudWatch Logs, metrics (EMF), alarms, dashboard; X-Ray |
| Delivery | Terraform, GitHub Actions with OIDC (no long-lived keys) |

## Milestones

| | Milestone | Status |
|---|---|---|
| M0 | Repository bootstrap: layout, ADRs, lint and security scans in CI | in progress |
| M1 | Terraform foundation: S3 state, OIDC deploy role, plan on pull requests | planned |
| M2 | Synchronous API with idempotency | planned |
| M3 | Event flow and saga | planned |
| M4 | Fault injection, integration tests, observability | planned |
| M5 | Load test, measured cost, final write-up | planned |

## Repository layout

```
infra/envs/<env>/   Terraform root module per environment
infra/modules/      reusable Terraform modules (from M2)
docs/adr/           architecture decision records
scripts/            lint and (from M1) bootstrap, deploy and destroy scripts
```

## Running the checks locally

Needs Terraform 1.10+, Python 3.13 and optionally TFLint and ShellCheck.

```bash
pip install --user -r scripts/requirements-lint.txt
bash scripts/lint.sh
```

Locally, a missing linter is skipped with a warning. In CI every linter is
required.

## Decisions

- [ADR 1: Terraform for infrastructure](docs/adr/0001-terraform-for-infrastructure.md)
- [ADR 2: Python for the Lambda handlers](docs/adr/0002-python-lambda-handlers.md)

## Licence

[MIT](LICENSE)
