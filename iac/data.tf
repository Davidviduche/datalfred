data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_secretsmanager_secret" "slack_token" {
  name = "${var.project_name}_slack_alerting_prod"
}
