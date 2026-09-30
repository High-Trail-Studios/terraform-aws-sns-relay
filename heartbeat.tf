# Scheduled heartbeat. Alerts are rare, so a dead man's switch fed only by
# deliveries would page you during every quiet stretch. This invokes the relay
# on a timer; the relay checks that every route's secrets resolve and then
# pings the heartbeat URL. It never contacts a destination.

locals {
  scheduled_heartbeat = var.heartbeat_enabled && var.heartbeat_schedule != null
}

resource "aws_cloudwatch_event_rule" "heartbeat" {
  count = local.scheduled_heartbeat ? 1 : 0

  name                = "${var.name_prefix}-heartbeat"
  description         = "Invokes ${local.function_name} so the heartbeat monitor sees it alive between alerts."
  schedule_expression = var.heartbeat_schedule

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "heartbeat" {
  count = local.scheduled_heartbeat ? 1 : 0

  rule  = aws_cloudwatch_event_rule.heartbeat[0].name
  arn   = aws_lambda_function.relay.arn
  input = jsonencode({ relay_heartbeat = true })
}

resource "aws_lambda_permission" "heartbeat" {
  count = local.scheduled_heartbeat ? 1 : 0

  statement_id  = "eventbridge-heartbeat"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.relay.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat[0].arn
}
