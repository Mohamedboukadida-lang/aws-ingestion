locals {
  # Persistent topic created in bootstrap/ (so the email subscription is confirmed once).
  alerts_topic_arn = "arn:aws:sns:${var.region}:${local.account_id}:${var.project}-alerts"

  lambda_names = {
    ingest    = aws_lambda_function.ingest.function_name
    consumer  = aws_lambda_function.consumer.function_name
    aggregate = aws_lambda_function.aggregate.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = local.lambda_names
  alarm_name          = "${local.name}-${each.key}-errors"
  alarm_description   = "The ${each.key} Lambda reported errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
}

# Throttled invocations are NOT counted in the Errors metric: the day 12 load test
# produced hundreds of throttles with all Errors alarms still OK.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each            = { for k, v in local.lambda_names : k => v if k != "aggregate" }
  alarm_name          = "${local.name}-${each.key}-throttles"
  alarm_description   = "The ${each.key} Lambda was throttled (account concurrency limit)."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "API Gateway returned 5xx responses."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.http.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
}

# Old messages mean the consumer is stuck or too slow, before anything reaches the DLQ.
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${local.name}-queue-age"
  alarm_description   = "Oldest message in the events queue is older than 5 minutes."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.events.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
}

# ---------- API Gateway access logs ----------
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-http"
  retention_in_days = 14
}

# ---------- Dashboard ----------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.http.id],
            [".", "4xx", ".", "."],
            [".", "5xx", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Queue depth and age"
          region = var.region
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.events.name, { stat = "Maximum" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", aws_sqs_queue.events_dlq.name, { stat = "Maximum", label = "DLQ depth" }],
            [".", "ApproximateAgeOfOldestMessage", ".", aws_sqs_queue.events.name, { stat = "Maximum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Lambda errors and throttles"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = concat(
            [for k, v in local.lambda_names : ["AWS/Lambda", "Errors", "FunctionName", v, { label = "${k} errors" }]],
            [for k, v in local.lambda_names : ["AWS/Lambda", "Throttles", "FunctionName", v, { label = "${k} throttles" }]],
          )
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda duration p95 (ms)"
          region  = var.region
          stat    = "p95"
          period  = 300
          metrics = [for k, v in local.lambda_names : ["AWS/Lambda", "Duration", "FunctionName", v, { label = k }]]
        }
      },
      {
        type = "alarm", x = 0, y = 12, width = 24, height = 3
        properties = {
          title = "Alarms"
          alarms = concat(
            [aws_cloudwatch_metric_alarm.dlq_not_empty.arn, aws_cloudwatch_metric_alarm.api_5xx.arn, aws_cloudwatch_metric_alarm.queue_age.arn],
            [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.arn],
          )
        }
      },
    ]
  })
}

# ---------- Saved Logs Insights queries (fields come from the JSON logs) ----------
resource "aws_cloudwatch_query_definition" "slow_requests" {
  name            = "${local.name}/ingest-slowest-requests"
  log_group_names = [aws_cloudwatch_log_group.ingest.name]
  query_string    = <<-EOT
    fields @timestamp, request_id, method, path, status, duration_ms
    | filter msg = "request"
    | sort duration_ms desc
    | limit 20
  EOT
}

resource "aws_cloudwatch_query_definition" "status_counts" {
  name            = "${local.name}/ingest-status-counts"
  log_group_names = [aws_cloudwatch_log_group.ingest.name]
  query_string    = <<-EOT
    filter msg = "request"
    | stats count() as requests, avg(duration_ms) as avg_ms by status, bin(5m)
    | sort @timestamp desc
  EOT
}

resource "aws_cloudwatch_query_definition" "consumer_outcomes" {
  name            = "${local.name}/consumer-outcomes"
  log_group_names = [aws_cloudwatch_log_group.consumer.name]
  query_string    = <<-EOT
    filter msg in ["processed", "record_failed"]
    | stats count() as n by msg, outcome, error, bin(1h)
  EOT
}
