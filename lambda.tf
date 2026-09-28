locals {
  create_code_bucket = var.code_bucket_name == null
  code_bucket        = local.create_code_bucket ? aws_s3_bucket.code[0].id : var.code_bucket_name
  code_key           = "${var.code_key_prefix}${var.name_prefix}/relay.zip"
  function_name      = var.name_prefix
}

data "archive_file" "relay" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/.build/relay.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

# --- Code bucket (only when the caller did not supply one) ------------------

resource "aws_s3_bucket" "code" {
  count = local.create_code_bucket ? 1 : 0

  bucket_prefix = "${var.name_prefix}-code-"

  # The bucket only ever holds this module's build artifact, which is rebuilt
  # from source on every apply, so emptying it on destroy is safe.
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "code" {
  count = local.create_code_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.code[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "relay" {
  bucket      = local.code_bucket
  key         = local.code_key
  source      = data.archive_file.relay.output_path
  source_hash = data.archive_file.relay.output_base64sha256

  tags = var.tags
}

# --- Function ---------------------------------------------------------------

resource "aws_cloudwatch_log_group" "relay" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_lambda_function" "relay" {
  function_name = local.function_name
  role          = aws_iam_role.relay.arn
  runtime       = "python3.14"
  architectures = ["arm64"]
  handler       = "relay.handler.handler"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_seconds

  s3_bucket        = aws_s3_object.relay.bucket
  s3_key           = aws_s3_object.relay.key
  source_code_hash = data.archive_file.relay.output_base64sha256

  environment {
    variables = {
      RELAY_ROUTES        = jsonencode(local.routes_config)
      RELAY_SSM_PREFIX    = var.ssm_prefix
      RELAY_HTTP_TIMEOUT  = tostring(var.http_timeout_seconds)
      RELAY_HEARTBEAT     = var.heartbeat_enabled ? "true" : "false"
      RELAY_SECRETS_TTL_S = "300"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.relay.name
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.relay]
}

resource "aws_lambda_function_event_invoke_config" "relay" {
  function_name          = aws_lambda_function.relay.function_name
  maximum_retry_attempts = var.max_retry_attempts

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}
