data "archive_file" "aggregate" {
  type        = "zip"
  source_dir  = "${path.module}/../build/aggregate"
  output_path = "${path.module}/../build/aggregate.zip"
}

resource "aws_cloudwatch_log_group" "aggregate" {
  name              = "/aws/lambda/${local.name}-aggregate"
  retention_in_days = 14
}

resource "aws_lambda_function" "aggregate" {
  function_name    = "${local.name}-aggregate"
  role             = aws_iam_role.aggregator.arn
  runtime          = "python3.13"
  handler          = "aggregate.app.handler"
  filename         = data.archive_file.aggregate.output_path
  source_code_hash = data.archive_file.aggregate.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.aggregate]
}

# Daily at 00:05 UTC, aggregating the previous (complete) UTC day.
resource "aws_cloudwatch_event_rule" "daily_aggregate" {
  name                = "${local.name}-daily-aggregate"
  schedule_expression = "cron(5 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "daily_aggregate" {
  rule = aws_cloudwatch_event_rule.daily_aggregate.name
  arn  = aws_lambda_function.aggregate.arn
}

resource "aws_lambda_permission" "events_aggregate" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aggregate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_aggregate.arn
}
