data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ssm_arn_prefix = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}"

  created_routes = { for k, r in var.routes : k => r if r.existing_topic_arn == null }

  topic_arns = merge(
    { for k, r in var.routes : k => r.existing_topic_arn if r.existing_topic_arn != null },
    { for k, t in aws_sns_topic.route : k => t.arn },
  )

  # Handed to the Lambda so it can map an incoming record's TopicArn to a route.
  # Holds no secrets: URLs and tokens stay in SSM.
  routes_config = {
    for k, r in var.routes : local.topic_arns[k] => {
      name        = k
      adapter     = r.adapter
      auth_token  = r.auth_token
      auth_header = r.auth_header
      auth_scheme = r.auth_scheme
    }
  }
}

# --- Topics -----------------------------------------------------------------

resource "aws_sns_topic" "route" {
  for_each = local.created_routes

  name = coalesce(each.value.topic_name, "${var.name_prefix}-${each.key}")

  kms_master_key_id = var.topic_kms_key_id

  tags = var.tags
}

resource "aws_sns_topic_subscription" "route" {
  for_each = var.routes

  topic_arn = local.topic_arns[each.key]
  protocol  = "lambda"
  endpoint  = aws_lambda_function.relay.arn

  # Covers the rare case where SNS itself cannot invoke the Lambda.
  redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn })

  depends_on = [aws_lambda_permission.sns, aws_sqs_queue_policy.dlq]
}

resource "aws_lambda_permission" "sns" {
  for_each = var.routes

  statement_id  = "sns-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.relay.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = local.topic_arns[each.key]
}
