# sns-alert-relay

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

TBD — no code yet.

## Commands

TBD — no build, test, or deploy commands yet.
