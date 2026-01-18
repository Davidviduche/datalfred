resource "aws_iam_role" "lambda_failsafe" {
  name = "${local.environment_name}_lambda_failsafe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_failsafe" {
  role       = aws_iam_role.lambda_failsafe.name
  policy_arn = aws_iam_policy.lambda_failsafe.arn
}

resource "aws_iam_policy" "lambda_failsafe" {
  name   = "${local.environment_name}_lambda_failsafe"
  policy = data.aws_iam_policy_document.lambda_failsafe.json
}

data "aws_iam_policy_document" "lambda_failsafe" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "lambda:PutFunctionConcurrency",
    ]
    resources = [aws_lambda_function.chatbot.arn]
  }
}


resource "aws_sns_topic" "chatbot_failsafe" {
  name = "${local.environment_name}_failsafe"
}

resource "aws_lambda_function" "chatbot_failsafe" {
  function_name = "${local.environment_name}_failsafe"
  runtime       = "python3.13"
  role          = aws_iam_role.lambda_failsafe.arn
  handler       = "main.main"

  filename         = data.archive_file.chatbot_failsafe.output_path
  source_code_hash = filebase64sha256(data.archive_file.chatbot_failsafe.output_path)
  environment {
    variables = {
      DATALFRED_CHATBOT_FUNCTION_NAME = aws_lambda_function.chatbot.function_name
    }
  }

}

data "archive_file" "chatbot_failsafe" {
  type        = "zip"
  source_file = "${path.module}/../code/chatbot_failsafe/main.py"
  output_path = "${path.module}/../code/chatbot_failsafe/function.zip"
}

resource "aws_sns_topic_subscription" "lambda_failsafe" {
  topic_arn = aws_sns_topic.chatbot_failsafe.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chatbot_failsafe.arn
}

resource "aws_lambda_permission" "chatbot_failsafe_allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatbot_failsafe.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.chatbot_failsafe.arn
}

resource "aws_cloudwatch_log_metric_filter" "chatbot_failsafe_error_pattern" {
  name           = "${local.environment_name}_failsafe"
  log_group_name = aws_cloudwatch_log_group.chatbot.name

  pattern = "Signatures does not match. Refusing request ..."

  metric_transformation {
    name      = "${local.environment_name}_failsafe"
    namespace = "Custom/Lambda"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "chatbot_failsafe_too_many_errors" {
  alarm_name          = "${local.environment_name}_failsafe"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.chatbot_failsafe_error_pattern.metric_transformation[0].name
  namespace           = "Custom/Lambda"
  period              = 3600
  statistic           = "Sum"
  threshold           = 100

  alarm_description = "Triggers when more than 5 errors are logged in one minute"
  alarm_actions = [
    aws_sns_topic.alerting_failsafe.arn,
    aws_lambda_function.chatbot_failsafe.arn
  ]
  actions_enabled = true
}

resource "aws_sns_topic" "alerting_failsafe" {
  name = "${local.environment_name}_failsafe"
}

resource "aws_sns_topic_policy" "alerting_failsafe" {
  arn    = aws_sns_topic.alerting_failsafe.arn
  policy = data.aws_iam_policy_document.sns_topic_alerting_failsafe.json
}

data "aws_iam_policy_document" "sns_topic_alerting_failsafe" {
  statement {
    effect = "Allow"
    actions = [
      "SNS:Publish",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [
      aws_sns_topic.alerting_failsafe.arn,
    ]
  }
}

resource "aws_sns_topic_subscription" "alerting_failsafe_email_target" {
  for_each  = toset(split(",", var.failure_notification_receivers))
  topic_arn = aws_sns_topic.alerting_failsafe.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_lambda_permission" "chatbot_failsafe" {
  statement_id  = "${local.environment_name}_failsafe"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatbot_failsafe.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.chatbot_failsafe_too_many_errors.arn
}
