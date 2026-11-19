# aws-ingestion

Serverless event ingestion pipeline on AWS, built with Terraform in `eu-central-1`.
Synthetic events only.

```
Client -> API Gateway (Cognito JWT) -> Lambda ingest -> SQS (+DLQ) -> Lambda consumer -> DynamoDB + S3
                                                        EventBridge (daily) -> aggregation Lambda
```

See `DECISIONS.md` for design choices and `WHAT_BROKE.md` for problems hit and fixes.
A full README with diagram and cost estimate comes on days 13-14.

## Layout

- `bootstrap/` state bucket, budget, alert topic and GitHub OIDC roles (applied once, never destroyed)
- `infra/` everything else (destroyed after each session)
- `src/` Lambda code: `ingest`, `consumer`, `aggregate`
- `scripts/` build, smoke test, DLQ redrive, end-of-day helper
