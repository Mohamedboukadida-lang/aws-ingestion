data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------- Producer (ingest API) ----------
resource "aws_iam_role" "producer" {
  name               = "${local.name}-producer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "SendToQueue"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
    resources = [aws_sqs_queue.events.arn]
  }
}

resource "aws_iam_role_policy" "producer" {
  role   = aws_iam_role.producer.id
  policy = data.aws_iam_policy_document.producer.json
}

resource "aws_iam_role_policy_attachment" "producer_logs" {
  role       = aws_iam_role.producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---------- Consumer ----------
resource "aws_iam_role" "consumer" {
  name               = "${local.name}-consumer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.events.arn]
  }
  statement {
    sid       = "WriteTable"
    actions   = ["dynamodb:PutItem", "dynamodb:ConditionCheckItem"]
    resources = [aws_dynamodb_table.events.arn]
  }
  statement {
    sid       = "ArchiveRaw"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.archive.arn}/raw/*"]
  }
}

resource "aws_iam_role_policy" "consumer" {
  role   = aws_iam_role.consumer.id
  policy = data.aws_iam_policy_document.consumer.json
}

resource "aws_iam_role_policy_attachment" "consumer_logs" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
