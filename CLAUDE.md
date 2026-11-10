# AWS serverless ingestion project

14-day portfolio project for the AWS Solutions Architect Associate exam. Public repo, so never commit secrets, account IDs, keys, or real data.

## Architecture
Client -> API Gateway (Cognito JWT) -> Lambda ingest (Python/FastAPI) -> SQS (+ DLQ) -> Lambda consumer -> DynamoDB (processed) + S3 (raw archive). EventBridge triggers a daily aggregation Lambda.

Cross-cutting: Secrets Manager, least-privilege IAM, GitHub Actions OIDC (no stored AWS keys), CloudWatch logs/alarms/dashboard, X-Ray. Synthetic events only.

## Layout
- `bootstrap/` creates the S3 state bucket (local state, never destroyed)
- `infra/` all other infrastructure (remote state in the bootstrap bucket)
- `DECISIONS.md` choice, alternatives, reason
- `WHAT_BROKE.md` problems hit and fixes

## Conventions
- Terraform only, region `eu-central-1`, Terraform >= 1.10 with S3-native state locking (`use_lockfile = true`)
- Least-privilege IAM; flag and justify any wildcard
- Idempotent consumer: the same event delivered twice creates no duplicate
- Tests for new logic before moving on
- Never run Terraform or the CLI with root credentials
- Run `terraform destroy` in `infra/` after sessions (never in `bootstrap/`)

## Working with Claude
Use the `aws-ingestion-project-coach` skill. Ask for one small step at a time, tied to the current day.

## Progress
- Day 1: repo created, AWS CLI and IAM identity set up; Terraform install and state bucket bootstrap in progress
