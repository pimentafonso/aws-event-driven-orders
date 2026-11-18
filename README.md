# aws-event-driven-orders

Event-driven order processing on AWS serverless, built with Terraform.

> **Status:** work in progress (M2, synchronous API). No load test has run yet, so this
> README has no performance results. Every number added later will be measured.

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
| M0 | Repository bootstrap: layout, ADRs, lint and security scans in CI | done |
| M1 | Terraform foundation: S3 state, OIDC deploy role, plan on pull requests | done |
| M2 | Synchronous API with idempotency | in progress |
| M3 | Event flow and saga | planned |
| M4 | Fault injection, integration tests, observability | planned |
| M5 | Load test, measured cost, final write-up | planned |

## The API

Both routes need a SigV4-signed request (IAM authorisation, see ADR 4).

| Request | Result |
|---|---|
| `POST /orders` with `Idempotency-Key` and `{"customer_id": "c-1", "items": [{"sku": "SKU-1", "quantity": 2}]}` | `201` with the order and a `Location` header |
| The same request again (same key, same body) | `201` with the same order; nothing new is stored |
| Same key, different body | `422` |
| No key, or a malformed body | `400` |
| `GET /orders/{order_id}` | `200`, or `404` if it does not exist |
| Any unsigned request | `403` from API Gateway; Lambda never runs |

## Repository layout

```
infra/account/      GitHub roles and permissions boundary (applied by an admin)
infra/envs/<env>/   Terraform root module per environment (applied by CI)
infra/modules/      reusable Terraform modules (data, api)
src/orders_api/     Lambda handler (Python 3.13, Powertools)
tests/unit/         unit tests: the real handler against DynamoDB mocked by moto
docs/adr/           architecture decision records
scripts/            lint, state bootstrap, account apply and destroy
```

## Running the checks locally

Needs Terraform 1.10+, Python 3.13 and optionally TFLint and ShellCheck.

```bash
pip install --user -r scripts/requirements-lint.txt
bash scripts/lint.sh

python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

After a deploy, `python scripts/smoke_api.py <api-endpoint>` checks the live API
with signed requests (the endpoint is the `api_endpoint` Terraform output).

Locally, a missing linter is skipped with a warning. In CI every linter is
required.

## Deploying

Needs the AWS CLI and an administrator profile for the one-off steps.

```bash
export AWS_PROFILE=<admin profile>
bash scripts/bootstrap-state.sh   # once per account: the state bucket
bash scripts/account.sh apply     # GitHub roles and permissions boundary
```

After that, GitHub Actions does the rest: every pull request that touches
`infra/` gets a plan summary as a comment, and merging to `main` applies dev
through the `dev` environment. The repository needs one secret,
`AWS_ACCOUNT_ID`.

To remove everything: `bash scripts/destroy.sh --all` (dev, the account module,
then the state bucket with every version in it). Without `--all` it removes dev
only.

## Decisions

- [ADR 1: Terraform for infrastructure](docs/adr/0001-terraform-for-infrastructure.md)
- [ADR 2: Python for the Lambda handlers](docs/adr/0002-python-lambda-handlers.md)
- [ADR 3: Terraform state and GitHub access to AWS](docs/adr/0003-state-and-github-access.md)
- [ADR 4: IAM authorisation on the HTTP API](docs/adr/0004-iam-auth-on-the-api.md)

## Licence

[MIT](LICENSE)
