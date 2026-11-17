# 1. Terraform for infrastructure

- Status: accepted
- Date: 2026-11-17

## Context

My other AWS project, [aws-ha-web-platform](https://github.com/pimentafonso/aws-ha-web-platform),
is built with CloudFormation nested stacks. This project should show a second
infrastructure-as-code tool rather than repeat the same one.

## Decision

Use Terraform (1.10 or later) with the `hashicorp/aws` provider 6.x.

- One root module per environment under `infra/envs/`, reusable modules under `infra/modules/`.
- Remote state in a versioned, encrypted S3 bucket with S3 native locking
  (`use_lockfile`), so no DynamoDB lock table is needed. Added in M1.
- `terraform fmt`, `validate`, TFLint (AWS ruleset) and Checkov run on every pull request.

## Consequences

- State is a file I own: the bucket must be created before the first `init`
  (a bootstrap script in M1) and must never be public.
- Terraform has no server-side rollback like CloudFormation. A failed apply
  leaves partial resources, which the next apply or `destroy` reconciles.
