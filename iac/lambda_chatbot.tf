locals {
  chatbot_lambda_code_path = "${path.root}/../code/"
  chatbot_lambda_code_rebuild_trigger = {
    # compute a map composed of the relative file path as key and the file hash as value, for every files of your processing jobs, recursively. Ignoring some irrelevant path patterns
    task_code_hashes = jsonencode({
      for file_path in fileset(trimsuffix(local.chatbot_lambda_code_path, "/"), "**") :
      file_path => filemd5("${trimsuffix(local.chatbot_lambda_code_path, "/")}/${file_path}")
      if alltrue([
        for directory_pattern_to_ignore in [
          ".mypy_cache/", ".ipynb_checkpoints/", "__pycache__/", "function.zip", "poetry.lock"
        ] :
        !strcontains(file_path, directory_pattern_to_ignore)
      ]) # ignoring path if it contains any of the irrelevant directory
    })
    dockerfile_hash = filemd5("${local.chatbot_lambda_code_path}/Dockerfile"),
  }
  # AWS lambda does not detect image change if tag is the same ('latest' for exemple)
  chatbot_lambda_code_image_tag = sha1(jsonencode(local.chatbot_lambda_code_rebuild_trigger))
}

module "chatbot_lambda_code" {
  source                = "git::https://github.com/erwan-simon/terraform-module-build-image-and-push-to-ecr//iac/?ref=v1.0.0"
  ecr_name              = "${local.environment_name}_chatbot_lambda_code"
  code_path             = abspath(local.chatbot_lambda_code_path)
  image_tag             = local.chatbot_lambda_code_image_tag
  image_rebuild_trigger = jsonencode(local.chatbot_lambda_code_rebuild_trigger)
  tags_map = {
    Appli          = var.project_name
    Component      = local.domain_name
    Env            = terraform.workspace
    git_repository = var.git_repository
  }
}

resource "time_sleep" "wait_for_ecr_to_create" {
  # docker image takes a little while to effectively appear in the ECR after being pushed
  depends_on = [module.chatbot_lambda_code]
  triggers   = local.chatbot_lambda_code_rebuild_trigger

  create_duration = "30s"
}

resource "aws_lambda_function" "chatbot" {
  function_name = local.environment_name
  role          = aws_iam_role.lambda.arn

  package_type = "Image"
  image_uri    = "${module.chatbot_lambda_code.ecr_url}:${local.chatbot_lambda_code_image_tag}"
  timeout      = 900
  memory_size  = 520

  environment {
    variables = {
      PROJECT_NAME           = var.project_name
      DOMAIN_NAME            = local.domain_name
      STAGE_NAME             = local.stage_name
      SLACK_SECRET_ARN       = data.aws_secretsmanager_secret.slack_token.name
      AUTHORIZED_SLACK_USERS = var.authorized_slack_users
    }
  }
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.chatbot.name
  }
  depends_on = [time_sleep.wait_for_ecr_to_create]
}

resource "aws_cloudwatch_log_group" "chatbot" {
  name              = "${local.environment_name}/"
  retention_in_days = 14
}

resource "aws_lambda_function_event_invoke_config" "chatbot" {
  function_name                = aws_lambda_function.chatbot.function_name
  maximum_event_age_in_seconds = 60
  maximum_retry_attempts       = 0
}

resource "aws_iam_role" "lambda" {
  name = "${local.environment_name}_lambda"

  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"

      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lambda" {
  name   = "${local.environment_name}_lambda"
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_policy_attachment" "lambda" {
  name       = "${local.environment_name}_lambda"
  roles      = [aws_iam_role.lambda.name]
  policy_arn = aws_iam_policy.lambda.arn
}

data "aws_iam_policy_document" "lambda" {
  statement {
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:List*",
      "bedrock:Get*",
      "bedrock:Describe*",
      "states:Describe*",
      "states:Get*",
      "states:List*",
      "states:RedriveExecution",
      "logs:Get*",
      "logs:List*",
      "logs:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "ecr:Describe*",
      "ec2:Get*",
      "ec2:List*",
      "ec2:Describe*",
      "ecs:Get*",
      "ecs:List*",
      "ecs:Describe*",
      "emr-serverless:Get*",
      "emr-serverless:List*",
      "emr-serverless:Describe*",
      "iam:Get*",
      "iam:List*",
      "iam:Describe*",
      "s3:Get*",
      "s3:List*",
      "glue:BatchGet*",
      "glue:Get*",
      "glue:List*",
      "glue:Describe*",
      "athena:*",
      "lakeformation:Get*",
      "lakeformation:Describe*",
      "lakeformation:List*"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogGroupFields",
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      data.aws_secretsmanager_secret.slack_token.arn
    ]
  }
}

resource "aws_lambda_function_url" "chatbot" {
  function_name      = aws_lambda_function.chatbot.function_name
  authorization_type = "NONE"
}
