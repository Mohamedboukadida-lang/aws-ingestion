# Alert email lives in Secrets Manager, not in code, tfvars or the command line.
# Create it once (the value never enters git):
#   aws secretsmanager create-secret --name aws-ingestion/alert-email --secret-string "you@example.com"
data "aws_secretsmanager_secret_version" "alert_email" {
  secret_id = "aws-ingestion/alert-email"
}

locals {
  alert_email = data.aws_secretsmanager_secret_version.alert_email.secret_string
}

# Persistent alert topic. It is in bootstrap (never destroyed) so the email
# subscription is confirmed once, not after every daily destroy of infra/.
#
# Not encrypted with the AWS-managed key on purpose: CloudWatch alarms cannot publish
# to a topic encrypted with alias/aws/sns (they need a customer-managed key, ~1 USD/month).
# Messages contain alarm names and metric values only, no event data.
resource "aws_sns_topic" "alerts" {
  name = "aws-ingestion-alerts"
}

data "aws_iam_policy_document" "alerts_publish" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_publish.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = local.alert_email
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
