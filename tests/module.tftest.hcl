# Plan-level tests against a mocked AWS provider: no credentials, no cost.
# They prove the module's wiring and input validation, not AWS behaviour;
# a real apply of examples/basic is the only check for that.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  # The provider validates ARNs, so computed ARNs need realistic values.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/sns-relay-lambda" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:111111111111:function:sns-relay" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:111111111111:sns-relay-dlq" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:mock-topic" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:/aws/lambda/sns-relay" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:111111111111:rule/sns-relay-heartbeat" }
  }
}

variables {
  routes = {
    ops-slack = { adapter = "slack" }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_sns_topic.route["ops-slack"].name == "sns-relay-ops-slack"
    error_message = "Default topic name should be <name_prefix>-<route>."
  }
  assert {
    condition     = aws_lambda_function.relay.function_name == "sns-relay"
    error_message = "Lambda should be named after name_prefix."
  }
  assert {
    condition     = aws_lambda_function.relay.runtime == "python3.14" && aws_lambda_function.relay.architectures[0] == "arm64"
    error_message = "Lambda runtime or architecture changed."
  }
  assert {
    condition     = length(aws_s3_bucket.code) == 1 && aws_s3_bucket.code[0].force_destroy
    error_message = "Without code_bucket_name the module should create a destroyable bucket."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dlq) == 1
    error_message = "DLQ alarm should be on by default."
  }
  assert {
    condition     = length(aws_cloudwatch_event_rule.heartbeat) == 0
    error_message = "Heartbeat schedule should be off unless heartbeat_enabled."
  }
  assert {
    condition     = aws_sns_topic.route["ops-slack"].kms_master_key_id == null
    error_message = "Topic SSE should be off by default (aws/sns breaks CloudWatch alarm publishing)."
  }
  assert {
    condition     = output.required_ssm_parameters == ["/sns-relay/ops-slack/url"]
    error_message = "Only the url parameter should be required by default."
  }
}

run "topic_name_override" {
  command = plan

  variables {
    routes = {
      db-alerts = { adapter = "slack", topic_name = "prod-db-alerts" }
    }
  }

  assert {
    condition     = aws_sns_topic.route["db-alerts"].name == "prod-db-alerts"
    error_message = "topic_name should override the default topic name."
  }
}

run "existing_topic_is_subscribed_not_created" {
  command = plan

  variables {
    routes = {
      legacy = {
        adapter            = "slack"
        existing_topic_arn = "arn:aws:sns:us-east-1:111111111111:legacy-alarms"
      }
    }
  }

  assert {
    condition     = length(aws_sns_topic.route) == 0
    error_message = "An existing topic must not be created or managed."
  }
  assert {
    condition     = aws_sns_topic_subscription.route["legacy"].topic_arn == "arn:aws:sns:us-east-1:111111111111:legacy-alarms"
    error_message = "The relay should subscribe to the existing topic."
  }
  assert {
    condition     = aws_lambda_permission.sns["legacy"].source_arn == "arn:aws:sns:us-east-1:111111111111:legacy-alarms"
    error_message = "Invoke permission should be scoped to the existing topic."
  }
}

run "custom_prefixes" {
  command = plan

  variables {
    name_prefix = "relay-staging"
    ssm_prefix  = "/relay/staging"
  }

  assert {
    condition     = aws_sns_topic.route["ops-slack"].name == "relay-staging-ops-slack"
    error_message = "name_prefix should drive topic names."
  }
  assert {
    condition     = output.required_ssm_parameters == ["/relay/staging/ops-slack/url"]
    error_message = "ssm_prefix should drive parameter paths."
  }
}

run "existing_code_bucket" {
  command = plan

  variables {
    code_bucket_name = "my-artifacts"
    code_key_prefix  = "lambda/"
  }

  assert {
    condition     = length(aws_s3_bucket.code) == 0
    error_message = "No bucket should be created when code_bucket_name is set."
  }
  assert {
    condition     = aws_s3_object.relay.bucket == "my-artifacts" && aws_s3_object.relay.key == "lambda/sns-relay/relay.zip"
    error_message = "Package should go to the caller's bucket under code_key_prefix."
  }
}

run "alarm_can_be_disabled" {
  command = plan

  variables {
    create_dlq_alarm = false
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dlq) == 0
    error_message = "create_dlq_alarm = false should remove the alarm."
  }
  assert {
    condition     = aws_sqs_queue.dlq.name == "sns-relay-dlq"
    error_message = "The DLQ itself must always exist."
  }
}

run "auth_and_heartbeat_parameters" {
  command = plan

  variables {
    routes = {
      hook = { adapter = "webhook", auth_token = true }
    }
    heartbeat_enabled = true
  }

  assert {
    condition = output.required_ssm_parameters == [
      "/sns-relay/hook/url",
      "/sns-relay/hook/token",
      "/sns-relay/_heartbeat/url",
    ]
    error_message = "Token and heartbeat parameters should be listed when enabled."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.heartbeat[0].schedule_expression == "rate(5 minutes)"
    error_message = "Heartbeat schedule should default to every 5 minutes."
  }
}

run "heartbeat_without_schedule" {
  command = plan

  variables {
    heartbeat_enabled  = true
    heartbeat_schedule = null
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.heartbeat) == 0
    error_message = "heartbeat_schedule = null should mean post-delivery pings only."
  }
}

# --- Input validation -------------------------------------------------------

run "rejects_topic_name_with_existing_arn" {
  command = plan
  variables {
    routes = {
      bad = {
        adapter            = "slack"
        topic_name         = "x"
        existing_topic_arn = "arn:aws:sns:us-east-1:111111111111:x"
      }
    }
  }
  expect_failures = [var.routes]
}

run "rejects_unknown_adapter" {
  command = plan
  variables {
    routes = { bad = { adapter = "pagerduty" } }
  }
  expect_failures = [var.routes]
}

run "rejects_bad_route_key" {
  command = plan
  variables {
    routes = { "Ops_Slack" = { adapter = "slack" } }
  }
  expect_failures = [var.routes]
}

run "rejects_fifo_topic" {
  command = plan
  variables {
    routes = {
      bad = { adapter = "slack", existing_topic_arn = "arn:aws:sns:us-east-1:111111111111:alerts.fifo" }
    }
  }
  expect_failures = [var.routes]
}

run "rejects_empty_routes" {
  command = plan
  variables {
    routes = {}
  }
  expect_failures = [var.routes]
}
