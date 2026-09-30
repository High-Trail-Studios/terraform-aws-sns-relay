terraform {
  required_version = ">= 1.7.0"
}

provider "aws" {
  region = "us-east-1"
}

module "sns_relay" {
  source = "../.."

  routes = {
    ops-slack     = { adapter = "slack" }
    db-alerts     = { adapter = "slack", topic_name = "prod-db-alerts" }
    incident-hook = { adapter = "webhook", auth_token = true }
  }

  heartbeat_enabled = true
}

output "topic_arns" {
  value = module.sns_relay.topic_arns
}

output "required_ssm_parameters" {
  value = module.sns_relay.required_ssm_parameters
}
