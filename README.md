# aws-ingestion

Serverless event ingestion pipeline on AWS, built with Terraform in `eu-central-1`.
Synthetic events only.

```
Client -> API Gateway (Cognito JWT) -> Lambda ingest -> SQS (+DLQ) -> Lambda consumer -> DynamoDB + S3
                                                        EventBridge (daily) -> aggregation Lambda
```

See `DECISIONS.md` for design choices and `WHAT_BROKE.md` for problems hit and fixes.
A full README with diagram and cost estimate comes on days 13-14.
