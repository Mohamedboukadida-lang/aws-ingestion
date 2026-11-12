# Decisions

Format: choice, alternatives, reason.

## 1. Remote state in S3 with native locking
- **Choice:** S3 backend with `use_lockfile = true` (Terraform >= 1.10)
- **Alternatives:** S3 + DynamoDB lock table; Terraform Cloud
- **Reason:** One fewer resource to create, secure and pay for; no loss of locking safety for a single-developer project.

## 2. Separate `bootstrap/` config with local state
- **Choice:** A small config creates the state bucket using local state; everything else uses the remote backend.
- **Alternatives:** Create the bucket manually in the console; one config with a two-phase migration
- **Reason:** Breaks the chicken-and-egg problem reproducibly and keeps the bucket itself in code. `prevent_destroy` protects it.

## 3. Region eu-central-1
- **Choice:** Frankfurt
- **Alternatives:** eu-west-1, us-east-1
- **Reason:** Lowest latency from Germany and data stays in the EU (GDPR).

## 4. Monthly budget lives in `bootstrap/`, $10, ACTUAL and FORECASTED alerts
- **Choice:** `aws_budgets_budget` of 10 USD/month in the bootstrap stack, alerting at 50% actual and 100% forecasted.
- **Alternatives:** Budget in `infra/`; a single threshold; CloudWatch billing alarm.
- **Reason:** `infra/` is destroyed after every session, which would delete the guard when it is needed most. 10 USD is well above expected spend for this project but low enough to catch a runaway resource. ACTUAL at 50% is an early warning; FORECASTED at 100% warns before the limit is crossed, not after.

## 5. Backend bucket name passed via gitignored `backend.hcl`
- **Choice:** `backend.tf` holds only non-sensitive settings; the bucket name (contains the account ID) is supplied with `terraform init -backend-config=backend.hcl`.
- **Alternatives:** Hard-code the bucket name; env vars.
- **Reason:** The repo is public and account IDs must not be committed. Backend blocks cannot use variables, so partial configuration is the supported mechanism. `backend.hcl.example` documents the format.

## 6. SQS standard queue, not FIFO
- **Choice:** Standard queue with a DLQ, `maxReceiveCount = 3`, visibility timeout 180 s.
- **Alternatives:** FIFO queue.
- **Reason:** FIFO costs more and caps throughput per message group. Duplicates and ordering are handled by an idempotency key and a conditional PutItem in the consumer (day 5). Three receives survive a transient DynamoDB throttle, while a poison message still reaches the DLQ within minutes. Visibility timeout is 6x the planned consumer timeout, per AWS guidance.

## 7. One IAM role per function
- **Choice:** Separate `producer` and `consumer` roles with resource-scoped inline policies.
- **Alternatives:** One shared Lambda role.
- **Reason:** Blast radius. A compromised public-facing producer can only enqueue, never read the table or the archive. Policies use `aws_iam_policy_document` so typos fail at plan time.

## 8. S3 archive lifecycle tiers
- **Choice:** Standard, then Standard-IA at 30 days, Glacier Instant Retrieval at 90, expire at 365.
- **Alternatives:** Stay in Standard; Intelligent-Tiering.
- **Reason:** Raw payloads are write-once, read-rarely, and the access pattern is known, so fixed tiers are cheaper than Intelligent-Tiering monitoring fees.

## 9. GitHub OIDC trust scoped by `sub`
- **Choice:** Deploy role trusts only this repo, on `main` or pull requests; no permissions attached until day 8.
- **Alternatives:** IAM user with stored keys in GitHub secrets.
- **Reason:** No long-lived keys; CI gets a short STS session. The `sub` condition stops any other repository from assuming the role.

## 10. HTTP API (API Gateway v2) instead of REST API
- **Choice:** HTTP API with the built-in JWT authorizer against Cognito.
- **Alternatives:** REST API with a Cognito authorizer.
- **Reason:** Roughly 70% cheaper per request, lower latency, native JWT support. Gives up usage plans, API keys, request validation and WAF integration, none of which this Cognito-protected ingest endpoint needs.

## 11. Idempotency key derived from the observation
- **Choice:** SHA-256 of (device_id, kind, recorded_at), computed server-side.
- **Alternatives:** Client-supplied UUID; hash of the whole body.
- **Reason:** A client retrying a failed request resends the same observation, so the key is stable with no client cooperation. Hashing the whole body would let a changed `value` create a duplicate. The consumer (day 5) will drop repeats with a conditional PutItem.

## 12. ID token vs access token at the JWT authorizer
- **Choice:** Test with the ID token (`aud` = client ID).
- **Alternatives:** Access token.
- **Reason:** In practice both were accepted (see WHAT_BROKE). The ID token matches the documented `aud` check; access tokens work because the HTTP API authorizer falls back to the `client_id` claim.

## 13. Structured JSON request log via middleware
- **Choice:** One JSON line per request (request_id, method, path, status, duration_ms) emitted by a FastAPI middleware, plus an `enqueued` line with idempotency key.
- **Alternatives:** Plain-text logs; API Gateway access logs only; Powertools for Lambda.
- **Reason:** JSON fields are directly queryable in CloudWatch Logs Insights (day 10) with no parsing. Powertools is a good option but adds a dependency for what ~20 lines do. API Gateway access logs can be added later for the edge view.

## 14. 503 with Retry-After on queue failure, no AWS details to the client
- **Choice:** Map boto errors to `503` + `Retry-After: 5`; log the exception class server-side.
- **Alternatives:** Let FastAPI return a generic 500; return the AWS message.
- **Reason:** 503 tells clients the request is safe to retry, which is true because the idempotency key makes retries harmless. Raw AWS errors can leak queue URLs and account IDs.

## 15. X-Ray active tracing with a justified wildcard
- **Choice:** `tracing_config { mode = "Active" }` on the ingest Lambda; `xray:PutTraceSegments` and `PutTelemetryRecords` on `*`.
- **Alternatives:** No tracing until day 10; Powertools tracer.
- **Reason:** Enabling it now means traces exist when dashboards are built. X-Ray write actions do not support resource-level permissions, so `*` is unavoidable. HTTP APIs do not emit X-Ray segments, so traces start at the Lambda.

## 16. Consumer writes S3 first, then a conditional DynamoDB put
- **Choice:** Archive the raw payload to `raw/<day>/<idempotency_key>.json`, then `PutItem` with `attribute_not_exists(pk)`; a failed condition means "duplicate, success".
- **Alternatives:** DynamoDB first; a separate idempotency marker item; DynamoDB transactions.
- **Reason:** S3 overwrites are harmless, so doing it first means a crash between steps loses nothing on retry. Doing DynamoDB first would mark the event done and skip the archive on redelivery. A conditional put is one atomic call, cheaper than transactions.

## 17. Partial batch responses (`ReportBatchItemFailures`)
- **Choice:** Return `batchItemFailures`; process each record in its own try/except.
- **Alternatives:** Raise on any failure (whole batch retried); batch size 1.
- **Reason:** Without it one poison message forces the 9 good ones to be reprocessed and inflates their receive count toward the DLQ. Batch size 10 keeps throughput.

## 18. `force_destroy` on the dev archive bucket
- **Choice:** `force_destroy = true` on `aws_s3_bucket.archive`.
- **Alternatives:** Empty the bucket manually before every destroy; no force_destroy.
- **Reason:** Data is synthetic and the stack is destroyed daily. Must be removed for any real environment.
