# End-to-end fixture: deploys the module for real, plus a throwaway HTTPS
# receiver, so CI can prove an alert travels SNS -> relay -> destination and
# that a failed alert lands in the DLQ. Every name carries var.run_id, so
# parallel runs never collide. Run by .github/workflows/e2e.yml; see docs/ci.md.

variable "run_id" {
  description = "Unique per CI run, e.g. \"ci-e2e-12345678-1\". Prefixes every resource name."
  type        = string

  validation {
    condition     = can(regex("^ci-e2e-[a-z0-9-]{1,33}$", var.run_id))
    error_message = "run_id must start with \"ci-e2e-\" (the CI role's permissions are scoped to that prefix)."
  }
}

variable "receiver_token" {
  description = "Bearer token the receiver requires. Generated per run by the workflow."
  type        = string
  sensitive   = true
}

provider "aws" {
  default_tags {
    tags = {
      ManagedBy = "sns-relay-e2e"
      RunId     = var.run_id
    }
  }
}

locals {
  ssm_prefix = "/${var.run_id}"
  receiver   = "${var.run_id}-receiver"
}

module "sns_relay" {
  source = "../.."

  name_prefix = var.run_id
  ssm_prefix  = local.ssm_prefix

  routes = {
    # Has its secrets: must reach the receiver, with the auth header.
    ok = { adapter = "webhook", auth_token = true }
    # Deliberately has no SSM parameter: must land in the DLQ.
    missing = { adapter = "webhook" }
  }

  # Fail straight to the DLQ instead of retrying for minutes.
  max_retry_attempts = 0
  create_dlq_alarm   = false
  log_retention_days = 1
}

# --- Secrets for the "ok" route ---------------------------------------------
# Test-only values, so unlike real deployments they are managed here (and sit
# in the runner's throwaway state) to guarantee they are destroyed.

resource "aws_ssm_parameter" "ok_url" {
  name  = "${local.ssm_prefix}/ok/url"
  type  = "SecureString"
  value = aws_lambda_function_url.receiver.function_url
}

resource "aws_ssm_parameter" "ok_token" {
  name  = "${local.ssm_prefix}/ok/token"
  type  = "SecureString"
  value = var.receiver_token
}

# --- Receiver: logs what it is sent, rejects requests without the token ------

data "archive_file" "receiver" {
  type        = "zip"
  source_file = "${path.module}/receiver/receiver.py"
  output_path = "${path.module}/.build/receiver.zip"
}

data "aws_iam_policy_document" "receiver_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "receiver" {
  name               = local.receiver
  assume_role_policy = data.aws_iam_policy_document.receiver_assume.json
}

resource "aws_iam_role_policy" "receiver" {
  name = "logs"
  role = aws_iam_role.receiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.receiver.arn}:*"
    }]
  })
}

# Created here so it is destroyed; otherwise Lambda creates one on first
# invoke and it outlives the run.
resource "aws_cloudwatch_log_group" "receiver" {
  name              = "/aws/lambda/${local.receiver}"
  retention_in_days = 1
}

resource "aws_lambda_function" "receiver" {
  function_name    = local.receiver
  role             = aws_iam_role.receiver.arn
  runtime          = "python3.14"
  architectures    = ["arm64"]
  handler          = "receiver.handler"
  memory_size      = 128
  timeout          = 5
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256

  environment {
    variables = { EXPECTED_AUTH = "Bearer ${var.receiver_token}" }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.receiver.name
  }

  depends_on = [aws_iam_role_policy.receiver]
}

# The relay speaks plain HTTPS, so the URL is public; the receiver itself
# rejects anything without the per-run token, and it lives for minutes.
resource "aws_lambda_function_url" "receiver" {
  function_name      = aws_lambda_function.receiver.function_name
  authorization_type = "NONE"
}

# Public function URLs need both permissions.
resource "aws_lambda_permission" "receiver_url" {
  statement_id           = "public-url"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.receiver.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "receiver_invoke" {
  statement_id             = "public-url-invoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.receiver.function_name
  principal                = "*"
  invoked_via_function_url = true
}

output "ok_topic_arn" {
  value = module.sns_relay.topic_arns["ok"]
}

output "missing_topic_arn" {
  value = module.sns_relay.topic_arns["missing"]
}

output "dlq_url" {
  value = module.sns_relay.dlq_url
}

output "relay_log_group" {
  value = "/aws/lambda/${module.sns_relay.lambda_function_name}"
}

output "receiver_log_group" {
  value = aws_cloudwatch_log_group.receiver.name
}

output "receiver_url" {
  value = aws_lambda_function_url.receiver.function_url
}
