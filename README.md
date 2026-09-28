# sns-relay

A small Terraform module that relays SNS notifications to HTTP destinations
(Slack, generic JSON webhooks) through a single Lambda, with a dead-letter
queue, an optional heartbeat, and no secrets in Terraform state.

```
CloudWatch alarm ──► SNS topic (ops-slack) ─┐
                                            ├─► relay Lambda ─► adapter ─► HTTPS POST
anything else    ──► SNS topic (hook)     ──┘        │
                                                     └─ after retries ─► SQS DLQ ─► alarm
```

Each **route** is one destination with its own SNS topic. The relay uses the
topic an alert arrived on to decide where to send it. There is no routing
table to maintain.

## Why not a native SNS HTTPS subscription?

SNS can POST to a URL itself, but it wraps every message in its own envelope
and requires the endpoint to confirm the subscription. Slack, Teams and most
SaaS webhooks can't do either. If your endpoint *can* handle the SNS
envelope, use a native subscription instead: it's one less moving part.

## Quick start

```hcl
module "sns_relay" {
  source = "git::https://github.com/<org>/sns-relay.git?ref=v0.1.0"

  routes = {
    ops-slack = { adapter = "slack" }
  }
}

output "topic_arns" {
  value = module.sns_relay.topic_arns
}
```

```sh
terraform init
terraform plan      # review what will be created
terraform apply

# Terraform never writes secret values. Store the webhook URL yourself:
aws ssm put-parameter --type SecureString \
  --name /sns-relay/ops-slack/url \
  --value 'https://hooks.slack.com/services/...'

# Send a test alert:
aws sns publish --subject "Test" --message "hello from sns-relay" \
  --topic-arn "$(terraform output -json topic_arns | jq -r '."ops-slack"')"
```

The module's `required_ssm_parameters` output lists every parameter your
routes need. Until a route's parameter exists, alerts to that route fail and land in
the DLQ, so you don't lose them silently.

Requirements: Terraform ≥ 1.7, AWS provider 6.x, and a region where the
Lambda `python3.14` runtime is available on arm64.

## Naming

Both prefixes can be changed. The defaults suit a single relay per account
and region:

| Variable | Default | Controls |
|----------|---------|----------|
| `name_prefix` | `sns-relay` | Lambda, IAM role, DLQ, alarm, heartbeat rule, code bucket, and default topic names (`<name_prefix>-<route>`) |
| `ssm_prefix` | `/sns-relay` | Where the relay reads secrets: `<ssm_prefix>/<route>/url` and so on |

To run more than one relay in the same account and region (for example
`prod` and `staging`), give each one a different `name_prefix` **and**
`ssm_prefix`. IAM and resource names would collide on `name_prefix`. A
shared `ssm_prefix` would let each relay read the other's secrets.

## Routes

`routes` is a map. Each key is the route's machine name (lowercase, digits
and hyphens). The key names its SSM parameters and, by default, its topic.

```hcl
routes = {
  # New topic, named "<name_prefix>-ops-slack"
  ops-slack = { adapter = "slack" }

  # New topic with your naming convention
  db-alerts = { adapter = "slack", topic_name = "prod-db-alerts" }

  # A topic you already own. The module subscribes to it but never
  # creates, modifies, or destroys it.
  legacy = {
    adapter            = "slack"
    existing_topic_arn = "arn:aws:sns:us-east-1:123456789012:legacy-alarms"
  }

  # Generic webhook with a token: "Authorization: Bearer <token>"
  incident-hook = { adapter = "webhook", auth_token = true }

  # Custom header, raw token: "X-Api-Key: <token>"
  vendor = {
    adapter     = "webhook"
    auth_token  = true
    auth_header = "X-Api-Key"
    auth_scheme = ""
  }
}
```

| Adapter   | Sends |
|-----------|-------|
| `slack`   | `{"text": ...}` to a Slack incoming webhook. CloudWatch alarm payloads become a one-line summary with a state emoji. Everything else is sent as the subject plus the message. |
| `webhook` | `{"source", "id", "topic_arn", "timestamp", "subject", "message", "attributes"}`. `id` is the SNS MessageId. Use it to deduplicate. |

## Secrets

Webhook URLs are credentials: anyone holding a Slack webhook URL can post to
your channel. They live in SSM Parameter Store as SecureString values:

| Parameter | When |
|-----------|------|
| `<ssm_prefix>/<route>/url` | Always |
| `<ssm_prefix>/<route>/token` | `auth_token = true` |
| `<ssm_prefix>/_heartbeat/url` | `heartbeat_enabled = true` |

- Terraform grants the Lambda read access to `<ssm_prefix>/*` and never
  writes the values, so they never appear in state or plan output.
- The Lambda caches values for 5 minutes. After rotating a value, allow up
  to 5 minutes before the old one stops being used.
- URLs and tokens are never logged. Errors name only the destination host.
- Only `https://` destinations are accepted, and redirects are not
  followed, so an auth header can't be forwarded to a host you didn't
  configure.
- If your parameters use a customer-managed KMS key, set `ssm_kms_key_arn`.

## Failure handling

**Delivery is at-least-once. Receivers may see the same alert more than
once.** SNS can redeliver a message, and the relay retries on failure. A
retry after a timeout may repeat a request the destination actually
received. The `webhook` adapter includes the SNS MessageId as `id` so
receivers can deduplicate. Slack has no way to do that, so an occasional
duplicate message is expected.

What happens when a delivery fails:

1. SNS invokes the Lambda asynchronously.
2. Any failure raises an error: a non-2xx response, a timeout, a missing
   SSM parameter, or a topic with no route. Lambda then retries twice
   (`max_retry_attempts`) with backoff over a few minutes.
3. After the last retry the event goes to the SQS DLQ
   (`<name_prefix>-dlq`), which keeps messages for 14 days.
4. If SNS can't invoke the Lambda at all (rare), the subscription's redrive
   policy sends the message to the same DLQ.

The two paths produce different message shapes. A message from the Lambda
path is an invocation record with the original SNS event under
`requestPayload`. A message from the SNS redrive path is the raw SNS
message. Neither is redriven automatically. Inspect the message, fix the
cause, and re-publish it to the topic.

With `create_dlq_alarm = true` (the default), a CloudWatch alarm fires when
the DLQ is non-empty. It notifies `alarm_actions`. With no actions it still
shows in the console, but nobody gets paged. **Don't point `alarm_actions`
at one of the relay's own topics:** if the relay is broken, you'd never hear
about it. Set `create_dlq_alarm = false` if you already monitor SQS and
Lambda your own way. `dlq_arn` is an output for that purpose.

## Heartbeat (optional)

Set `heartbeat_enabled = true` and store a URL at
`<ssm_prefix>/_heartbeat/url`. It works with Better Stack heartbeats,
Healthchecks.io, Dead Man's Snitch, or anything else that accepts a `GET`.

- **After each successful delivery** the relay pings the URL. A failed ping
  is logged and ignored. It never fails the invocation, because that would
  trigger a retry and resend an alert that was already delivered.
- **On a schedule** (`heartbeat_schedule`, default `rate(5 minutes)`) the
  relay checks that every route's secrets resolve, then pings. It never
  contacts a destination. Without the schedule, a quiet week with no alerts
  looks exactly like a dead relay, and a dead man's switch would page you.
  Set the monitor's expected period longer than the schedule.

The scheduled ping shows that the Lambda runs and its configuration is
complete. It **can't** prove that SNS is still subscribed or that a
destination will accept a request. The DLQ alarm covers the second.

## IAM

The Lambda role can do exactly this:

| Permission | Resource | Why |
|------------|----------|-----|
| `logs:CreateLogStream`, `logs:PutLogEvents` | its own log group | Logging |
| `ssm:GetParameter` | `<ssm_prefix>/*` | Read webhook URLs, tokens, heartbeat URL |
| `sqs:SendMessage` | the DLQ | Lambda on-failure destination |
| `kms:Decrypt` (only if `ssm_kms_key_arn` is set) | that key, via SSM only | Decrypt SecureStrings |

The only other access policy is on the DLQ, which accepts `sqs:SendMessage`
from `sns.amazonaws.com` for this module's topics only. Invoke permissions
on the Lambda are limited to those topics and, if enabled, the heartbeat
schedule rule.

## Cost

Nothing here bills by the hour. At alert volumes this costs effectively
nothing, but here is where money can go:

- **CloudWatch alarm:** about $0.10/month, the only fixed cost. Turn it off
  with `create_dlq_alarm = false`.
- **Lambda, SNS, SQS:** pay per request and well inside the free tier for
  alerting. SNS-to-Lambda deliveries aren't charged.
- **Heartbeat schedule:** `rate(5 minutes)` is about 8,640 short invocations
  a month, still negligible. A tighter schedule costs proportionally more.
- **CloudWatch Logs:** billed on ingestion. There are a few lines per alert,
  kept for `log_retention_days` (14 by default).
- **SSM:** standard parameters with standard throughput are free. The
  5-minute cache keeps the relay well under the throughput limits.
- **Topic encryption** is off by default. The AWS-managed `aws/sns` key
  can't be used if CloudWatch alarms publish to the topic, because its key
  policy can't grant them access. A customer-managed key (`topic_kms_key_id`)
  works but costs about $1/month.
- **Code bucket:** one small object in S3. Pass `code_bucket_name` to reuse
  a bucket you already have.

## Teardown

`terraform destroy` removes everything the module created: topics,
subscriptions, the Lambda, the log group, the DLQ (and any messages still in
it), the alarm, the heartbeat rule, and the code bucket if the module created
it. For an existing bucket, only the relay's object is removed.

It does **not** remove:
- topics passed as `existing_topic_arn`, since they're yours;
- the SSM parameters you created by hand. Delete those with
  `aws ssm delete-parameters`.

Check the DLQ before destroying. Anything in it is gone once the queue is
deleted.

## What this does not do

- **No routing rules, deduplication windows, or escalation.** One topic, one
  destination. Content-based routing (for example, by severity or keyword)
  would turn a relay into a notification platform. It's a possible future
  direction, not part of v1.
- **No exactly-once delivery.** See *Failure handling*.
- **No FIFO topics.** SNS FIFO topics can't deliver to Lambda.
- **No cross-account or cross-region topics.** An existing topic must be in
  the same account and region as the module.
- **No plain-HTTP destinations.**
- **The Lambda uses the runtime's bundled boto3**, which AWS updates on its
  own schedule. The relay only calls `ssm:GetParameter`, a stable API, so
  this trades exact pinning for having no dependencies to package.

## Adding a destination

1. Add `src/relay/adapters/<name>.py` with a subclass of `Adapter` whose
   `render(alert)` returns the JSON body.
2. Register it in `src/relay/adapters/__init__.py`.
3. Add the name to the `adapter` validation in `variables.tf`.
4. Add a test in `tests/`.

HTTP, auth headers, timeouts, retries, and the DLQ come from the core, so an
adapter only decides what the payload looks like.

## Development

```sh
python3 -m unittest discover -s tests     # unit tests, stdlib only
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test                            # mocked AWS provider, no credentials
```

CI runs all of this on every PR, on every push to `main`, and weekly. See
[docs/ci.md](docs/ci.md), which also covers failure alerts through SNS.
