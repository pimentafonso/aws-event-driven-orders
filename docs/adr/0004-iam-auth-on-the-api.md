# 4. IAM authorisation on the HTTP API

- Status: accepted
- Date: 2026-11-18

## Context

The orders API is reachable from the internet. Every accepted request runs a
Lambda function and writes to DynamoDB, so an open endpoint lets anyone who
finds the URL create data and spend money. The callers of this API are my own
test scripts and, later, a load test, not browsers or end users.

## Decision

Every route uses `AWS_IAM` authorisation: a request must be signed with SigV4
by a principal in this account that may call `execute-api:Invoke`. The stage
also throttles requests (25 per second, bursts of 50 by default).

## Alternatives considered

- **No authorisation, throttle only.** Cheapest to call, but a throttle caps the
  damage instead of preventing it, and a month at 25 requests per second is far
  over the always-free allowances.
- **Cognito JWT authoriser.** The right choice for end users, but it adds a user
  pool and a token flow that this project does not need yet.
- **Lambda authoriser with a shared key.** Runs a function for every rejected
  request and keeps a long-lived secret in the client.

## Consequences

- Unsigned requests get `403` from API Gateway before Lambda runs.
- Test clients must sign requests: `scripts/smoke_api.py` uses botocore's SigV4
  signer, and the load test will need a SigV4-capable client.
- The account's Lambda concurrency limit is 10 (checked with
  `aws lambda get-account-settings` on 18 November 2026), so no concurrency can
  be reserved; the stage throttle is the only per-API cap.
