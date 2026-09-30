#!/usr/bin/env bash
# Assertions for the e2e fixture. Run from tests/e2e after `terraform apply`.
# Needs the AWS CLI, jq, curl, and credentials for the fixture's account.
#
#   1. An alert published to the "ok" topic reaches the receiver, with auth.
#   2. An alert published to the "missing" topic (no SSM parameter) lands in
#      the DLQ as a Lambda on-failure record.
set -euo pipefail

out() { terraform output -raw "$1"; }

OK_TOPIC=$(out ok_topic_arn)
MISSING_TOPIC=$(out missing_topic_arn)
DLQ_URL=$(out dlq_url)
RELAY_LOGS=$(out relay_log_group)
RECEIVER_LOGS=$(out receiver_log_group)
RECEIVER_URL=$(out receiver_url)

MARKER="e2e-$(date +%s)-$RANDOM"
DEADLINE_S=${E2E_DEADLINE_S:-240}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Poll "$@" every 10s until it succeeds or DEADLINE_S passes.
wait_for() {
  local what=$1; shift
  local end=$((SECONDS + DEADLINE_S))
  until "$@"; do
    if ((SECONDS >= end)); then
      log "FAIL: timed out after ${DEADLINE_S}s waiting for $what"
      return 1
    fi
    sleep 10
  done
  log "ok: $what"
}

# A new public function URL takes a moment to accept traffic. Until then it
# answers 403; once live, the receiver itself answers 401 (no token). Waiting
# here keeps a propagation delay from failing test 1 into the DLQ.
receiver_live() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$RECEIVER_URL")" = 401 ]
}

received() {
  aws logs filter-log-events --log-group-name "$RECEIVER_LOGS" \
    --filter-pattern "\"$MARKER-ok\"" --query 'length(events)' --output text |
    grep -qv '^0$'
}

in_dlq() {
  aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 10 \
    --wait-time-seconds 10 --visibility-timeout 0 --output json |
    jq -e --arg m "$MARKER-missing" \
      '[.Messages[]?.Body | (fromjson? // {}) | .requestPayload.Records[0].Sns.Message] | index($m) != null' \
      >/dev/null
}

dump_logs() {
  log "relay logs:"
  aws logs tail "$RELAY_LOGS" --since 15m --format short || true
  log "receiver logs:"
  aws logs tail "$RECEIVER_LOGS" --since 15m --format short || true
}
trap 'dump_logs' ERR

wait_for "receiver URL is live" receiver_live

log "publishing $MARKER-ok and $MARKER-missing"
aws sns publish --topic-arn "$OK_TOPIC" --subject e2e --message "$MARKER-ok" >/dev/null
aws sns publish --topic-arn "$MISSING_TOPIC" --subject e2e --message "$MARKER-missing" >/dev/null

wait_for "alert delivered to receiver with auth" received
wait_for "undeliverable alert landed in the DLQ" in_dlq

log "PASS"
