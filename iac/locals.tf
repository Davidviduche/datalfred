locals {
  domain_name      = "chatbot"
  stage_name       = terraform.workspace
  environment_name = "${var.project_name}_${local.domain_name}_${local.stage_name}"
}
