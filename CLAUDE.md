# sns-relay

Relays SNS notifications to a downstream destination.

<!-- Scaffold. Org philosophy loads automatically from the parent directory and
     is not repeated here. Fill in Stack, Commands, and the destination list
     once code exists. -->

## Design constraints

- **The destination is the variable.** Put an adapter interface at that
  boundary so a new destination is an addition, not a rewrite. The generic core
  is worth more than any single hardcoded target — resist wiring one
  destination's API through the middle of the relay.
- **SNS delivery is at-least-once.** Duplicates are normal, not a bug. Either
  make the relay idempotent or state plainly in the README that consumers may
  see the same alert twice. Do not claim exactly-once.
- **Failures need somewhere to go.** A relay that silently drops an alert is
  worse than no relay, because it looks like quiet. DLQ or equivalent, and say
  what the retry semantics actually are.
- **Destination credentials are real secrets** (webhook URLs included — a Slack
  webhook URL is a credential). SSM SecureString or equivalent; never in
  plaintext env or in state.

## Out of scope (v1)

- Alert routing rules, deduplication windows, escalation policies. That is a
  notification platform, not a relay. Note the extension; don't build it.

## Stack

- Terraform module at the repo root (AWS provider 6.x). One SNS topic per
  route; the Lambda maps an incoming record's `TopicArn` to its route.
- Lambda: Python 3.14, arm64, standard library only (boto3 from the runtime).
  Package is zipped by `archive_file` and uploaded to S3 (module-created or
  caller-supplied bucket).
- Adapters live in `src/relay/adapters/`; the core (`handler.py`,
  `transport.py`) owns HTTP, auth, and error handling.

## Commands

- Tests: `python3 -m unittest discover -s tests`
- Format: `terraform fmt -check -recursive`
- Validate: `terraform init -backend=false && terraform validate`
- Terraform tests: `terraform test` (mocked AWS provider; `tests/module.tftest.hcl`)
- CI: `.github/workflows/test.yml`; `ci-passed` is the required check. See `docs/ci.md`.
- Locally `terraform` may be OpenTofu; CI runs HashiCorp Terraform.
