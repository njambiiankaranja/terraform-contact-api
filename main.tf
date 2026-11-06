# 1. DynamoDB table for submissions
resource "aws_dynamodb_table" "submissions" {
  name         = "${var.project_name}-submissions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  # DynamoDB deletes items automatically once their expires_at time has passed
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# 2. SNS topic and email subscription (you must confirm the email once)
resource "aws_sns_topic" "notifications" {
  name = "${var.project_name}-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# 3. IAM role for the Lambda function
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Write to this one table and publish to this one topic, nothing else
resource "aws_iam_role_policy" "lambda_access" {
  name = "SubmitAccess"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.submissions.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.notifications.arn
      }
    ]
  })
}

# 4. Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "handler.py"
  output_path = "lambda_function.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-submit"
  retention_in_days = 14
}

resource "aws_lambda_function" "submit" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-submit"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.11"
  timeout          = 10
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME     = aws_dynamodb_table.submissions.name
      TOPIC_ARN      = aws_sns_topic.notifications.arn
      RETENTION_DAYS = tostring(var.retention_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# 5. HTTP API in front of the function
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submit.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "submit" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /submit"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Limit request rates so a bot cannot flood your inbox or your table
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# 6. Alert by email if the function throws errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "The contact form function reported an error"

  dimensions = {
    FunctionName = aws_lambda_function.submit.function_name
  }

  alarm_actions = [aws_sns_topic.notifications.arn]
}