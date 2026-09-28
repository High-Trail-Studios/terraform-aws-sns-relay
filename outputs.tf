output "topic_arns" {
  description = "Route key => SNS topic ARN (created or existing). Publish alerts here."
  value       = local.topic_arns
}

output "lambda_function_name" {
  description = "Name of the relay function."
  value       = aws_lambda_function.relay.function_name
}

output "lambda_role_arn" {
  description = "Execution role of the relay, e.g. for a KMS key policy."
  value       = aws_iam_role.relay.arn
}

output "dlq_url" {
  description = "URL of the dead-letter queue holding alerts that failed to relay."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue, for your own monitoring."
  value       = aws_sqs_queue.dlq.arn
}

output "code_bucket" {
  description = "Bucket holding the Lambda package."
  value       = local.code_bucket
}

output "required_ssm_parameters" {
  description = "SecureString parameters you must create before alerts flow. Terraform never writes these values."
  value = concat(
    flatten([
      for k, r in var.routes : concat(
        ["${var.ssm_prefix}/${k}/url"],
        r.auth_token ? ["${var.ssm_prefix}/${k}/token"] : [],
      )
    ]),
    var.heartbeat_enabled ? ["${var.ssm_prefix}/_heartbeat/url"] : [],
  )
}
