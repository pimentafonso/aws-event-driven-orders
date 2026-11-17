# 2. Python for the Lambda handlers

- Status: accepted
- Date: 2026-11-17

## Context

The handlers need idempotency, structured logging, metrics and tracing, and
partial batch responses for SQS. Writing these by hand is error-prone.

## Decision

Write the handlers in Python 3.13 with
[Powertools for AWS Lambda (Python)](https://docs.powertools.aws.dev/lambda/python/latest/).
Lint and format with Ruff; test with pytest.

## Consequences

- Powertools provides idempotency (backed by DynamoDB), batch processing,
  logging, metrics (EMF) and tracing, so the code focuses on business logic.
- Cold starts in Python are short for this kind of handler; they will be
  measured in the load test rather than assumed.
