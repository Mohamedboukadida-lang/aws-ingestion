data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/../build/ingest"
  output_path = "${path.module}/../build/ingest.zip"
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.name}-ingest"
  retention_in_days = 14
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name}-ingest"
  role             = aws_iam_role.producer.arn
  runtime          = "python3.13"
  handler          = "ingest.app.handler"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  timeout          = 10
  memory_size      = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.events.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}
