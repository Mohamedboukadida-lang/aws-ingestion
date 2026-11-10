# Days 1–3: Foundation, IAM, Ingest API

This is the first module of the 14-day serverless ingestion project. Each day has
a goal, a "why" for every AWS choice (tied to an SAA exam domain), exact steps,
and a fixed commit schedule. Follow it top to bottom. Do not skip the destroy at
the end of each day.

Environment facts this course assumes (verified on 2026-11-10):

| Item | Value |
|---|---|
| AWS account | <ACCOUNT_ID> |
| Region | eu-central-1 |
| Local credentials | IAM user `testuser` (long-lived keys, dev only) |
| Terraform | 1.17 (supports S3-native state locking) |
| Python (local) | 3.14. Lambda runtime will be `python3.13`. |
| Container runtime | podman (aliased as docker) |

---

## Commit schedule (every day, no exceptions)

A portfolio repo is judged by its history as much as its code. Reviewers scroll
the log. Three anchored commits a day plus micro-commits in between give a
readable story.

| When | Name | What goes in | Message prefix |
|---|---|---|---|
| Start of session | **Scaffold** | New files, empty modules, variable declarations. Must pass `terraform validate`. | `feat(scope): scaffold …` |
| Midpoint | **Working** | First successful apply / test pass. | `feat(scope): …` |
| End of session | **Close** | Docs, `DECISIONS.md`, `WHAT_BROKE.md`, cleanup. Made **after** `terraform destroy`. | `docs: day N close …` |

Rules:
- Micro-commits between anchors are fine and encouraged (`fix:`, `chore:`, `test:`).
- Never commit `.tfstate`, `.tfvars`, `.terraform/`, build zips, or `.env`.
- Every commit must pass `terraform fmt -check` and `terraform validate`. The
  `scripts/eod.sh` helper (created on day 1) enforces this for the close commit.
- Push after every anchor commit. Unpushed work does not exist.

Conventional-commit scopes used in this project: `bootstrap`, `infra`, `iam`,
`sqs`, `ddb`, `s3`, `api`, `cognito`, `ingest`, `ci`, `docs`.

---

## Day 1: Terraform skeleton and remote state

**Goal:** `terraform plan` in `infra/` runs clean against an S3 backend, a budget
alert exists, and the repo is on GitHub with three commits.

### Why this comes first

Infrastructure as code without remote state is a demo, not engineering. Remote
state gives you locking (two applies cannot collide), versioning (you can roll
back a corrupted state file), and a single source of truth that CI will share
on day 8.

**Exam domain: resilience.** State corruption is the single most common way
teams lose a Terraform-managed environment. Versioned, locked state is the fix.

### Step 0: git identity and GitHub repo (15 min)

```bash
git config user.name "Mohamed Boukadida"
```

```bash
git config user.email "mohamed.boukadida@supcom.tn"
```

Create `.gitignore` at the repo root:

```gitignore
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!example.tfvars
.terraform.lock.hcl.bak
crash.log

# Python
__pycache__/
*.pyc
.venv/
build/
dist/
*.zip

# Local
.env
.DS_Store
```

Create the GitHub repo and push the empty skeleton:

```bash
gh repo create aws-ingestion --public --source=. --remote=origin --push
```

If the push fails because there are no commits yet, make the scaffold commit
first (next step) and rerun with `git push -u origin main`.

### Step 1: Bootstrap stack (45 min)

The main stack cannot store its own state in a bucket it manages. That is a
chicken-and-egg problem, so the state bucket lives in a separate, tiny stack
that uses local state and is applied exactly once.

Create `bootstrap/main.tf`:

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = {
      project   = "aws-ingestion"
      managed   = "terraform"
      component = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "aws-ingestion-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name
  # Protect against accidental destroy of the state bucket.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Monthly budget. Lives in bootstrap so it survives `destroy` of the main stack.
resource "aws_budgets_budget" "monthly" {
  name         = "aws-ingestion-monthly"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

variable "alert_email" {
  type        = string
  description = "Email that receives budget alerts"
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
```

Why no DynamoDB lock table: Terraform 1.10+ can lock using a `.tflock` object in
S3 itself (`use_lockfile = true`). One fewer resource, zero cost. Older guides
still show the DynamoDB table. Record this in `DECISIONS.md`.

Apply it:

```bash
cd bootstrap && terraform init && terraform apply -var alert_email=mohamed.boukadida@supcom.tn
```

Confirm the email subscription AWS Budgets sends you. Keep `bootstrap/terraform.tfstate`
**out of git** (the gitignore handles it). Back it up somewhere private; losing
it only means you'd have to `terraform import` the bucket, which is recoverable.

**Commit 1 (Scaffold):** `feat(bootstrap): state bucket, budget alert`

### Step 2: Main stack skeleton (45 min)

Create these files in `infra/`.

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
```

`backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "aws-ingestion-tfstate-<ACCOUNT_ID>"
    key          = "infra/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

`providers.tf`:

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = var.project
      env     = var.env
      managed = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

`variables.tf`:

```hcl
variable "project" {
  type    = string
  default = "aws-ingestion"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}
```

`locals.tf`:

```hcl
locals {
  name       = "${var.project}-${var.env}"
  account_id = data.aws_caller_identity.current.account_id
}
```

`outputs.tf` (empty for now, with a comment). Then:

```bash
cd infra && terraform init && terraform validate && terraform plan
```

Expected: `No changes.` The point today is that init talks to S3 successfully.

**Why default_tags:** every resource gets `project` and `env` tags for free.
This is what cost allocation (SAA cost domain) and later the dashboard will
filter on.

**Commit 2 (Working):** `feat(infra): skeleton with S3 backend and default tags`

### Step 3: End-of-day helper and docs (30 min)

Create `scripts/eod.sh`:

```bash
#!/usr/bin/env bash
# End-of-day: format, validate, run tests, remind to destroy, commit and push.
set -euo pipefail
cd "$(dirname "$0")/.."

terraform -chdir=infra fmt -recursive
terraform -chdir=infra validate

if [ -d tests ]; then
  python -m pytest -q
fi

if terraform -chdir=infra state list 2>/dev/null | grep -q .; then
  echo "!! infra state is not empty. Run: terraform -chdir=infra destroy"
  echo "!! Aborting close commit. Destroy first, then rerun."
  exit 1
fi

day="${1:?usage: scripts/eod.sh <day-number> [message]}"
msg="${2:-close}"
git add -A
git commit -m "docs: day ${day} close – ${msg}"
git push
```

```bash
chmod +x scripts/eod.sh
```

Now write the first `DECISIONS.md` entry. Use this format for every entry:

```markdown
## 2026-11-10 — Remote state in S3 with native locking

**Choice:** S3 backend, `use_lockfile = true`, versioning + SSE-S3, created in a
separate `bootstrap/` stack.

**Alternatives:** local state; S3 + DynamoDB lock table; Terraform Cloud.

**Reason:** Local state cannot be shared with CI. DynamoDB locking is the legacy
pattern; Terraform ≥1.10 locks in S3 directly, which removes a resource and a
cost line. Terraform Cloud adds a vendor dependency the project does not need.
Bootstrap is separate because a stack cannot create the bucket that stores its
own state.
```

And a second entry for the budget (why in bootstrap, why 10 USD, why both
ACTUAL and FORECASTED thresholds).

**Commit 3 (Close):**

```bash
scripts/eod.sh 1 "state backend, budget, eod script"
```

Nothing to destroy today; the state bucket is meant to persist.

### Day 1 interview talking point

"Why is the state bucket in a separate stack?" Answer: self-reference. A stack
cannot create the bucket it needs to initialise. Follow-up: how you'd recover if
`bootstrap/terraform.tfstate` were lost (import, because the bucket name is
deterministic).

---

## Day 2: Data plane stubs and least-privilege IAM

**Goal:** SQS + DLQ, DynamoDB table, S3 archive bucket, one IAM role per
function, and GitHub OIDC trust. Apply, verify, destroy.

### Why this comes before any application code

IAM is the part of this project reviewers will read most carefully. Writing the
policies before the Lambdas forces you to decide exactly which actions each
function needs, instead of starting broad and "tightening later" (which never
happens).

**Exam domain: security.** The SAA exam repeatedly tests: one role per workload,
resource-scoped ARNs, no long-lived keys, and federation for CI.

### Step 1: Queues (30 min)

`infra/sqs.tf`:

```hcl
resource "aws_sqs_queue" "events_dlq" {
  name                      = "${local.name}-events-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.name}-events"
  visibility_timeout_seconds = 180 # must be >= 6x consumer Lambda timeout (day 5)
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events.arn]
  })
}
```

Why standard, not FIFO: FIFO costs more, caps throughput per message group, and
you will handle ordering and duplicates with an idempotency key in DynamoDB
anyway (day 5). Why `maxReceiveCount = 3`: enough retries to survive a transient
DynamoDB throttle, few enough that a poison message hits the DLQ in minutes.
Why visibility timeout 6× the Lambda timeout: AWS's own recommendation so the
Lambda SQS poller never sees the same batch twice while a previous invocation
is still running.

### Step 2: Table and archive bucket (30 min)

`infra/dynamodb.tf`:

```hcl
resource "aws_dynamodb_table" "events" {
  name         = "${local.name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
```

Generic `pk`/`sk` keys let the same table hold events, idempotency markers, and
daily aggregates (day 5–7) without extra tables. On-demand billing because the
load profile is spiky and unknown.

`infra/s3.tf`:

```hcl
resource "aws_s3_bucket" "archive" {
  bucket = "${local.name}-archive-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    id     = "tier-down"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
  }
}
```

Lifecycle tiers are an SAA cost-domain staple. Raw payloads are write-once,
read-rarely, so they move to IA then Glacier Instant Retrieval.

**Commit 1 (Scaffold):** `feat(infra): sqs with dlq, dynamodb table, s3 archive`

### Step 3: IAM roles (60 min)

`infra/iam.tf`. Use `aws_iam_policy_document` data sources, never inline JSON
strings; the data source catches typos at plan time.

```hcl
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
```

Audit rule for the whole project: grep for `"*"` in `resources` and in
`actions`. The only acceptable wildcard is inside the AWS-managed
`AWSLambdaBasicExecutionRole` (log group creation), and you should be able to
explain why.

### Step 4: GitHub OIDC (45 min)

`infra/github_oidc.tf`:

```hcl
variable "github_repo" {
  type        = string
  description = "owner/name of the GitHub repository"
  default     = "CHANGE_ME/aws-ingestion"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS now validates GitHub's cert chain itself; thumbprint is kept for older provider versions.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${local.name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}
```

Leave the deploy role's permissions policy for day 8; today only the trust
relationship matters. The `sub` condition is what stops any other GitHub repo
on earth from assuming this role. Set `github_repo` to your real `owner/name`.

**Exam domain: security.** "No stored AWS keys" is the headline. OIDC gives CI a
15-minute STS session scoped to one repo and one branch.

### Step 5: Apply, verify, destroy (30 min)

```bash
cd infra && terraform apply
```

Verify in the console or CLI: both queues exist, the table is on-demand, the
bucket blocks public access, the two roles have exactly the statements above.

**Commit 2 (Working):** `feat(iam): per-function roles and GitHub OIDC trust`

Then:

```bash
cd infra && terraform destroy
```

Note: destroying the OIDC provider and recreating it daily is fine. Nothing
depends on its ID.

### Step 6: Docs (20 min)

`DECISIONS.md` entries: SQS standard vs FIFO; one role per function vs a shared
role; S3-native lock vs DynamoDB (if not already written); lifecycle tiers.

`WHAT_BROKE.md`: anything that failed today. Common candidates: bucket name
already taken (names are global), `redrive_allow_policy` ordering, OIDC
thumbprint warnings.

**Commit 3 (Close):**

```bash
scripts/eod.sh 2 "data plane stubs and iam"
```

### Day 2 interview talking point

"Why one role per Lambda?" Blast radius. If the producer is compromised through
the public API, the attacker can only enqueue messages, never read the table
or the archive.

---

## Day 3: Ingest API with Cognito

**Goal:** an authenticated `POST /events` reaches a Lambda that validates the
payload and enqueues it to SQS. Tested locally with moto first, then deployed
and hit with curl.

### Why this order

Handler first, with tests, then wiring. If the handler is proven with moto,
every failure during deployment is an infrastructure problem, not a code
problem. That halves your debugging surface.

**Exam domains: security (JWT authorizer), performance (HTTP API vs REST API).**

### Step 1: Python project (30 min)

Install `uv`. It replaces pip/venv and gives a lockfile for free:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

This also fixes the `aws-mcp` server, which needs `uvx` on your PATH. Restart
your shell afterwards.

Create `pyproject.toml` at the repo root:

```toml
[project]
name = "aws-ingestion"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
  "fastapi>=0.115",
  "mangum>=0.19",
  "boto3>=1.35",
  "pydantic>=2.9",
]

[dependency-groups]
dev = [
  "pytest>=8",
  "moto[sqs]>=5",
  "httpx>=0.27",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
```

```bash
uv python install 3.13 && uv sync
```

Pin 3.13 because that is the Lambda runtime. Packaging 3.14-built wheels for a
3.13 runtime is a classic `WHAT_BROKE.md` entry; avoid it.

### Step 2: Handler with tests (60 min)

`src/ingest/models.py`:

```python
import hashlib
import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class Event(BaseModel):
    device_id: str = Field(min_length=1, max_length=64)
    kind: Literal["heart_rate", "steps", "temperature"]
    value: float
    recorded_at: datetime

    def idempotency_key(self) -> str:
        """Deterministic key so the consumer can drop duplicates.

        Uses the fields that define 'the same observation'. Two submissions with
        identical device, kind, and timestamp are the same event even if a retry
        changed nothing else.
        """
        canonical = json.dumps(
            {
                "device_id": self.device_id,
                "kind": self.kind,
                "recorded_at": self.recorded_at.isoformat(),
            },
            sort_keys=True,
        )
        return hashlib.sha256(canonical.encode()).hexdigest()
```

`src/ingest/app.py`:

```python
import json
import logging
import os

import boto3
from fastapi import FastAPI, status
from mangum import Mangum

from ingest.models import Event

logger = logging.getLogger()
logger.setLevel(logging.INFO)

app = FastAPI(title="ingest")
_sqs = None


def sqs():
    global _sqs
    if _sqs is None:
        _sqs = boto3.client("sqs")
    return _sqs


@app.post("/events", status_code=status.HTTP_202_ACCEPTED)
def post_event(event: Event):
    key = event.idempotency_key()
    body = event.model_dump(mode="json") | {"idempotency_key": key}
    sqs().send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(body),
    )
    logger.info(json.dumps({"msg": "enqueued", "idempotency_key": key}))
    return {"accepted": True, "idempotency_key": key}


handler = Mangum(app)
```

Logging as JSON from day one so day 10's Logs Insights queries work without
refactoring.

`tests/test_ingest.py`:

```python
import json
import os

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-central-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    with mock_aws():
        q = boto3.client("sqs").create_queue(QueueName="events")
        monkeypatch.setenv("QUEUE_URL", q["QueueUrl"])
        import ingest.app as app_module
        app_module._sqs = None
        yield TestClient(app_module.app), q["QueueUrl"]


VALID = {
    "device_id": "dev-1",
    "kind": "heart_rate",
    "value": 72,
    "recorded_at": "2026-11-10T10:00:00Z",
}


def test_valid_event_is_enqueued(client):
    tc, url = client
    r = tc.post("/events", json=VALID)
    assert r.status_code == 202
    msgs = boto3.client("sqs").receive_message(QueueUrl=url)["Messages"]
    assert json.loads(msgs[0]["Body"])["idempotency_key"] == r.json()["idempotency_key"]


def test_same_event_twice_has_same_key(client):
    tc, _ = client
    a = tc.post("/events", json=VALID).json()["idempotency_key"]
    b = tc.post("/events", json=VALID).json()["idempotency_key"]
    assert a == b


def test_invalid_kind_rejected(client):
    tc, _ = client
    r = tc.post("/events", json=VALID | {"kind": "blood_pressure"})
    assert r.status_code == 422
```

```bash
uv run pytest -q
```

All three must pass before touching Terraform.

**Commit 1 (Scaffold):** `feat(ingest): fastapi handler with idempotency key and moto tests`

### Step 3: Packaging and Lambda (45 min)

`scripts/build_lambda.sh`:

```bash
#!/usr/bin/env bash
# Build a Lambda zip for the given package under src/ using the Lambda runtime's Python.
set -euo pipefail
cd "$(dirname "$0")/.."
pkg="${1:?usage: build_lambda.sh <package>}"
out="build/${pkg}"
rm -rf "$out" && mkdir -p "$out"
uv export --no-dev --no-hashes > "build/${pkg}.requirements.txt"
uv pip install --python 3.13 --target "$out" -r "build/${pkg}.requirements.txt" --quiet
cp -r "src/${pkg}" "$out/"
echo "built $out"
```

`infra/lambda_ingest.tf`:

```hcl
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

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.events.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}
```

Explicit log group with retention: without it Lambda creates one with infinite
retention, which is a small but real cost leak and a reviewer red flag.

### Step 4: Cognito and HTTP API (60 min)

`infra/cognito.tf`:

```hcl
resource "aws_cognito_user_pool" "users" {
  name = "${local.name}-users"

  password_policy {
    minimum_length = 12
  }
}

resource "aws_cognito_user_pool_client" "api" {
  name            = "${local.name}-api-client"
  user_pool_id    = aws_cognito_user_pool.users.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH", # for curl testing only; remove on day 8
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
```

`infra/api.tf`:

```hcl
resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name}-http"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.http.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.api.id]
    issuer   = "https://${aws_cognito_user_pool.users.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "ingest" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingest.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = "POST /events"
  target             = "integrations/${aws_apigatewayv2_integration.ingest.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
```

Add to `infra/outputs.tf`:

```hcl
output "api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}
output "user_pool_id" {
  value = aws_cognito_user_pool.users.id
}
output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.api.id
}
```

**HTTP API vs REST API:** HTTP API is roughly 70 % cheaper per request, has a
built-in JWT authorizer, and lower latency. You give up usage plans, API keys,
request validation and WAF integration. For an ingest endpoint behind Cognito,
that trade is correct. Record it.

### Step 5: Deploy and curl (45 min)

```bash
scripts/build_lambda.sh ingest && terraform -chdir=infra apply
```

Create a test user and get a token:

```bash
aws cognito-idp admin-create-user --user-pool-id $(terraform -chdir=infra output -raw user_pool_id) --username tester --message-action SUPPRESS
```

```bash
aws cognito-idp admin-set-user-password --user-pool-id $(terraform -chdir=infra output -raw user_pool_id) --username tester --password 'Testing-Pass-123!' --permanent
```

```bash
aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id $(terraform -chdir=infra output -raw user_pool_client_id) --auth-parameters USERNAME=tester,PASSWORD='Testing-Pass-123!' --query 'AuthenticationResult.IdToken' --output text > /tmp/idtoken
```

```bash
curl -s -X POST "$(terraform -chdir=infra output -raw api_url)/events" -H "Authorization: Bearer $(cat /tmp/idtoken)" -H "Content-Type: application/json" -d '{"device_id":"dev-1","kind":"heart_rate","value":72,"recorded_at":"2026-11-10T10:00:00Z"}'
```

Expected: `{"accepted":true,"idempotency_key":"..."}`. Confirm with:

```bash
aws sqs get-queue-attributes --queue-url $(aws sqs get-queue-url --queue-name aws-ingestion-dev-events --query QueueUrl --output text) --attribute-names ApproximateNumberOfMessages
```

Also test the negative path: no header should return 401, and a wrong `kind`
should return 422.

**The thing that will probably break:** using the **access** token instead of
the **ID** token. The HTTP API JWT authorizer checks `aud` against the client
ID. Cognito access tokens carry `client_id`, not `aud`, so they fail with 401.
If you hit this, that is your `WHAT_BROKE.md` entry and a great interview story.

**Commit 2 (Working):** `feat(api): http api with cognito jwt authorizer wired to ingest lambda`

Then:

```bash
terraform -chdir=infra destroy
```

### Step 6: Docs and close (20 min)

`DECISIONS.md`: HTTP API vs REST API; ID token vs access token; idempotency key
derived from (device, kind, timestamp) rather than a client-supplied UUID
(reason: clients retrying a failed request will not change the timestamp, so
the key stays stable with no client cooperation).

**Commit 3 (Close):**

```bash
scripts/eod.sh 3 "ingest api live and tested"
```

### Day 3 interview talking point

"How does the API stay idempotent if the client retries?" The key is derived
from the observation itself, not from the request. A retry produces the same
key, and on day 5 the consumer will use a conditional `PutItem` to drop it.

---

## What you will have after day 3

- A remote-state Terraform project with a budget guard and a bootstrap story.
- Four resource groups with least-privilege roles and no wildcards.
- CI trust via OIDC with no AWS keys anywhere.
- A tested, authenticated ingest endpoint that enqueues validated events.
- Nine anchored commits, pushed, plus two decision logs feeding the README.

Day 4 continues the ingest API (error handling, structured request logging,
X-Ray tracing flag), then days 5–7 build the consumer that reads the queue.
