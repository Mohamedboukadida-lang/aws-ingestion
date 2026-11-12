data "archive_file" "consumer" {
  type        = "zip"
  source_dir  = "${path.module}/../build/consumer"
  output_path = "${path.module}/../build/consumer.zip"
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${local.name}-consumer"
  retention_in_days = 14
}

resource "aws_lambda_function" "consumer" {
  function_name    = "${local.name}-consumer"
  role             = aws_iam_role.consumer.arn
  runtime          = "python3.13"
  handler          = "consumer.app.handler"
  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256
  timeout          = 30 # queue visibility timeout (180 s) is 6x this
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME     = aws_dynamodb_table.events.name
      ARCHIVE_BUCKET = aws_s3_bucket.archive.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

resource "aws_lambda_event_source_mapping" "consumer" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 10

  # Only failed records are returned to the queue (then the DLQ after 3 receives).
  function_response_types = ["ReportBatchItemFailures"]
}
