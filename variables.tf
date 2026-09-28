variable "name_prefix" {
  description = "Prefix for every resource this module creates. Also the default SNS topic name prefix."
  type        = string
  default     = "sns-relay"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 characters of letters, digits, and hyphens."
  }
}

variable "routes" {
  description = <<-EOT
    One entry per destination. The map key is the route's machine name (e.g. "ops-slack"); it
    names the SSM parameters the relay reads and, by default, the SNS topic.

      adapter            - "slack" or "webhook".
      topic_name         - Override the created topic's name. Default: "<name_prefix>-<key>".
      existing_topic_arn - Subscribe to a topic you already own instead of creating one. The
                           module never creates, modifies, or destroys that topic.
      auth_token         - Send a token read from SSM "<ssm_prefix>/<key>/token" on each request.
      auth_header        - Header that carries the token. Default "Authorization".
      auth_scheme        - Value prefix, e.g. "Bearer" -> "Authorization: Bearer <token>".
                           Set to "" to send the raw token.
  EOT
  type = map(object({
    adapter            = string
    topic_name         = optional(string)
    existing_topic_arn = optional(string)
    auth_token         = optional(bool, false)
    auth_header        = optional(string, "Authorization")
    auth_scheme        = optional(string, "Bearer")
  }))

  validation {
    condition     = length(var.routes) > 0
    error_message = "Define at least one route."
  }

  validation {
    condition     = alltrue([for k in keys(var.routes) : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", k))])
    error_message = "Route keys must be lowercase letters, digits, and hyphens (max 63), starting with a letter or digit."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : contains(["slack", "webhook"], r.adapter)])
    error_message = "adapter must be one of: slack, webhook."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : !(r.topic_name != null && r.existing_topic_arn != null)])
    error_message = "Set topic_name or existing_topic_arn on a route, not both."
  }

  validation {
    condition = alltrue([
      for r in values(var.routes) :
      r.existing_topic_arn == null || can(regex("^arn:aws[a-zA-Z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$", r.existing_topic_arn))
    ])
    error_message = "existing_topic_arn must be a standard SNS topic ARN (FIFO topics cannot deliver to Lambda)."
  }
}

variable "topic_kms_key_id" {
  description = "KMS key for SSE on created topics. Null means no SSE. Do not use alias/aws/sns if CloudWatch alarms publish to the topic: its key policy cannot grant them access. A customer-managed key works but bills about $1/month."
  type        = string
  default     = null
}

variable "ssm_prefix" {
  description = "SSM path the relay reads secrets from. Terraform grants read access here but never writes values, so no secret lands in state."
  type        = string
  default     = "/sns-relay"

  validation {
    condition     = can(regex("^/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$", var.ssm_prefix))
    error_message = "ssm_prefix must start with / and must not end with /."
  }
}

variable "ssm_kms_key_arn" {
  description = "KMS key ARN, only if your SecureString parameters use a customer-managed key. Leave null for the default aws/ssm key."
  type        = string
  default     = null
}

# --- Code storage -----------------------------------------------------------

variable "code_bucket_name" {
  description = "Existing S3 bucket for the Lambda package. Null creates a small dedicated bucket that is destroyed with the module."
  type        = string
  default     = null
}

variable "code_key_prefix" {
  description = "Key prefix inside the code bucket, e.g. \"lambda/\". Useful when sharing an existing bucket."
  type        = string
  default     = ""
}

# --- Lambda -----------------------------------------------------------------

variable "lambda_memory_mb" {
  description = "Lambda memory. The relay is I/O bound; 128 MB is enough."
  type        = number
  default     = 128
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout. Must cover one destination request plus a heartbeat ping."
  type        = number
  default     = 15
}

variable "http_timeout_seconds" {
  description = "Timeout for each outbound HTTP request."
  type        = number
  default     = 5
}

variable "max_retry_attempts" {
  description = "Lambda async retries after the first failed attempt (0-2) before the event goes to the DLQ."
  type        = number
  default     = 2

  validation {
    condition     = var.max_retry_attempts >= 0 && var.max_retry_attempts <= 2
    error_message = "max_retry_attempts must be between 0 and 2."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the relay's log group."
  type        = number
  default     = 14
}

# --- Failure handling -------------------------------------------------------

variable "create_dlq_alarm" {
  description = "Create a CloudWatch alarm that fires when anything lands in the DLQ. Turn off if you already monitor SQS/Lambda your own way."
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "ARNs notified when the DLQ alarm fires or recovers. Do not point this at one of the relay's own topics: if the relay is broken, you would never hear about it."
  type        = list(string)
  default     = []
}

# --- Heartbeat --------------------------------------------------------------

variable "heartbeat_enabled" {
  description = "Ping the URL in SSM \"<ssm_prefix>/_heartbeat/url\" after each successful delivery (and on heartbeat_schedule). Works with Better Stack, Healthchecks.io, Dead Man's Snitch, or anything that accepts a GET."
  type        = bool
  default     = false
}

variable "heartbeat_schedule" {
  description = "EventBridge schedule for a standalone heartbeat so a quiet period without alerts does not look like an outage. Null disables it, so pings then happen only after deliveries."
  type        = string
  default     = "rate(5 minutes)"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}
