# 3. Terraform state and GitHub access to AWS

- Status: accepted
- Date: 2026-11-17

## Context

Terraform needs remote state that CI and my laptop share, and GitHub Actions
needs AWS access for `plan` on pull requests and `apply` on `main`. The repository
is public, so anything a workflow posts is public too.

## Decision

**State.** One S3 bucket per account, `<account-id>-aedo-tfstate`, created by
`scripts/bootstrap-state.sh`: versioned (old versions expire after 90 days),
SSE-S3 encryption, public access blocked, TLS-only bucket policy. Locking uses
S3 native lock files (`use_lockfile`), so there is no DynamoDB lock table. The
bucket name holds the account ID, so it is passed at `init` time
(`-backend-config`) and never committed. Keys: `account/` and `env/<env>/`.

**Account module.** `infra/account` holds the GitHub roles and the workload
permissions boundary. An administrator applies it with `scripts/account.sh`;
CI only plans it. It reads the existing GitHub OIDC provider instead of
creating one (one per URL per account; `aws-ha-web-platform` created it).

**Roles.** Both trust only this repository through GitHub's immutable OIDC
subject (`owner@id/repo@id`), so a re-created repository with the same name
cannot assume them.

| Role | Trusted subject | Can do |
|---|---|---|
| `aedo-github-plan` | `pull_request` | `ReadOnlyAccess`, read state, plan with `-lock=false` |
| `aedo-github-dev-deploy` | `environment:dev` (main only) | the above, write `env/dev/` state, create `aedo-dev-*` roles only with the boundary, plus service writes added per milestone |

A shared guardrail policy denies both roles data reads (object contents outside
the state bucket, secrets, parameters, DynamoDB items, queue messages, log
events), the audit trail, and every Region but eu-west-1.

**Pull request comments** list resource addresses and actions only. The full
plan stays in the job log, where GitHub masks the account ID.

## Consequences

- Least privilege grows with the code: the deploy role gets write access to a
  service in the same pull request that first uses it, and that change shows up
  in the account plan on the pull request.
- Pull requests from forks get no OIDC token, so they run lint only.
- Changing the account module needs an administrator, which is deliberate: CI
  cannot widen its own permissions.
