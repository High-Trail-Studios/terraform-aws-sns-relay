# One queue catches both failure paths:
#   - Lambda async on-failure destination: the relay ran and gave up after retries.
#   - SNS subscription redrive: SNS could not invoke the Lambda at all.
# The two produce different message shapes; see README "Failure handling".

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days, the SQS maximum
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

data "aws_iam_policy_document" "dlq" {
  statement {
    sid       = "AllowSnsRedrive"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = values(local.topic_arns)
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  count = var.create_dlq_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-dlq-not-empty"
  alarm_description = "An alert failed to relay and is sitting in ${aws_sqs_queue.dlq.name}. Inspect and redrive it."

  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}
