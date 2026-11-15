# GitHub Actions -> AWS federation. Lives in bootstrap (applied once, never destroyed)
# because CI must be able to authenticate before it can deploy infra/.

variable "github_repo" {
  type        = string
  description = "owner/name of the GitHub repository"
  default     = "Mohamedboukadida-lang/aws-ingestion"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself; thumbprint kept for provider compatibility.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = "eu-central-1"
  prefix      = "aws-ingestion-dev"
  state_arn   = aws_s3_bucket.tfstate.arn
  oidc_arn    = aws_iam_openid_connect_provider.github.arn
  oidc_issuer = "token.actions.githubusercontent.com"
}

# ---------- Trust policies: one per role, different `sub` ----------
data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

# ---------- Plan role: pull requests, read-only ----------
resource "aws_iam_role" "github_plan" {
  name                 = "${local.prefix}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

# Wildcard justified: AWS-managed ReadOnlyAccess lets `terraform plan` refresh every
# resource type. It cannot change anything, and PR code is the least trusted input.
resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${local.state_arn}/infra/*"]
  }
}

resource "aws_iam_role_policy" "github_plan_state" {
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ---------- Apply role: main branch only, scoped to the project's resources ----------
resource "aws_iam_role" "github_apply" {
  name                 = "${local.prefix}-github-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [local.state_arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_arn}/infra/*"]
  }

  # Wildcard actions below are scoped to this project's name prefix. Terraform needs
  # many Get/Put/Tag calls per resource type; enumerating them is brittle.
  statement {
    sid     = "ArchiveBucket"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.prefix}-archive-${local.account_id}",
      "arn:aws:s3:::${local.prefix}-archive-${local.account_id}/*",
    ]
  }
  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-*"]
  }
  # Wildcard resource justified: event source mappings are addressed by a UUID that
  # does not exist before creation, and List* actions do not support resource scoping.
  statement {
    sid = "LambdaEventSourceMappings"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "Sqs"
    actions   = ["sqs:*"]
    resources = ["arn:aws:sqs:${local.region}:${local.account_id}:${local.prefix}-*"]
  }
  statement {
    sid       = "DynamoDb"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.prefix}-*"]
  }
  statement {
    sid       = "LogGroups"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.prefix}-*"]
  }
  # Wildcard resource justified: DescribeLogGroups / DescribeAlarms do not support resource scoping.
  statement {
    sid       = "DescribeOnly"
    actions   = ["logs:DescribeLogGroups", "cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGateway"
    actions   = ["apigateway:*"]
    resources = ["arn:aws:apigateway:${local.region}::/apis", "arn:aws:apigateway:${local.region}::/apis/*", "arn:aws:apigateway:${local.region}::/tags/*"]
  }
  statement {
    sid       = "Cognito"
    actions   = ["cognito-idp:*"]
    resources = ["arn:aws:cognito-idp:${local.region}:${local.account_id}:userpool/*"]
  }
  statement {
    sid       = "EventBridge"
    actions   = ["events:*"]
    resources = ["arn:aws:events:${local.region}:${local.account_id}:rule/${local.prefix}-*"]
  }
  statement {
    sid       = "Alarms"
    actions   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
    resources = ["arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.prefix}-*"]
  }
  statement {
    sid       = "Sns"
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:${local.region}:${local.account_id}:${local.prefix}-*"]
  }

  # IAM: can only manage roles with the project prefix, and can only attach the
  # Lambda logging policy. This blocks creating an admin role to escalate privileges.
  statement {
    sid = "IamRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
  }
  statement {
    sid       = "IamAttachLoggingOnly"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
    }
  }
  statement {
    sid       = "IamPassRoleToLambda"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_apply" {
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.apply.json
}

output "github_plan_role_arn" {
  value = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  value = aws_iam_role.github_apply.arn
}
