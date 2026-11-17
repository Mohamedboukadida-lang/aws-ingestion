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

## 19. GSI `by_day` for the daily aggregation (Query, not Scan)
- **Choice:** Global secondary index on (`day`, `recorded_at`), projection ALL; the aggregator may only `Query` that index.
- **Alternatives:** Scan with a filter; day-prefixed partition key; a separate table.
- **Reason:** A Scan reads and bills the whole table every day and grows with history. The GSI reads only one day. Aggregate items have no `day` attribute, so they stay out of the index. The single-table design keeps events, idempotency markers and aggregates together.

## 20. EventBridge rule at 00:05 UTC for the previous day, with a `day` override
- **Choice:** `cron(5 0 * * ? *)` invokes the aggregator for yesterday (UTC); `{"day": "YYYY-MM-DD"}` reprocesses any day.
- **Alternatives:** EventBridge Scheduler; aggregating "today so far" hourly.
- **Reason:** Aggregating a complete day gives final numbers. The five-minute offset leaves room for in-flight messages. Output keys (`AGG#day`, `device#kind`) are deterministic, so reruns overwrite and never duplicate.

## 21. DLQ alarm and a manual redrive script
- **Choice:** CloudWatch alarm on DLQ `ApproximateNumberOfMessagesVisible > 0`, an encrypted SNS topic, and `scripts/redrive_dlq.sh` using `start-message-move-task`.
- **Alternatives:** Automatic redrive; no alarm until day 10.
- **Reason:** A DLQ message means a bug or bad data; blindly redriving loops it. A human fixes the cause, then replays. The SNS topic has no email subscription yet (it would need re-confirming after each daily destroy); subscriptions come with day 10.

## 22. GitHub OIDC provider and deploy roles live in `bootstrap/`
- **Choice:** OIDC provider, a read-only `github-plan` role and a scoped `github-apply` role are applied once from `bootstrap/`.
- **Alternatives:** Keep them in `infra/` (as the course first had them).
- **Reason:** `infra/` is destroyed every session, so CI would lose its own credentials and could never redeploy. Bootstrap is the one stack that is never destroyed.

## 23. Separate plan and apply roles, split by OIDC `sub`
- **Choice:** Pull requests assume `github-plan` (AWS `ReadOnlyAccess` plus read of the state file). Only `main` assumes `github-apply`.
- **Alternatives:** One deploy role for both.
- **Reason:** PR code is the least trusted input; a malicious PR can run arbitrary Terraform, so it must not hold write access. The `sub` claim is what AWS checks, so the split is enforced by AWS, not by workflow YAML.

## 24. Apply role: prefix-scoped, with an IAM escalation guard
- **Choice:** Every service statement is limited to `aws-ingestion-dev-*` resources. IAM can only manage `aws-ingestion-dev-*` roles, and `AttachRolePolicy` is allowed only for `AWSLambdaBasicExecutionRole` (condition `iam:PolicyARN`); `PassRole` only to Lambda.
- **Alternatives:** `AdministratorAccess`; a permissions boundary.
- **Reason:** A role that can create roles can otherwise make itself admin. The attach condition closes that path. Wildcard actions (`lambda:*`, `sqs:*`...) remain, scoped by resource, because Terraform makes dozens of Get/Put/Tag calls per resource type. Wildcard resources are limited to event source mappings (UUID known only after create) and Describe/List calls.

## 25. Immutable OIDC subject claims
- **Choice:** Trust `repo:<owner>@<id>/<repo>@<id>:<context>`, via `github_sub_prefix`.
- **Alternatives:** `repo:<owner>/<repo>:<context>` (what most guides show).
- **Reason:** The repo is configured for immutable subjects, so the classic format never matches. The IDs also stop a renamed or re-created repo from inheriting trust.

## 26. Apply workflow is manual unless `AUTO_APPLY=true`
- **Choice:** `workflow_dispatch` with `apply`/`destroy`; auto-apply on merge only if the repo variable is set.
- **Alternatives:** Always apply on merge (the course's default).
- **Reason:** The project is destroyed after each session; an unconditional apply on every push would silently recreate billable resources. The variable makes auto-deploy a deliberate switch.

## 27. Cognito `ADMIN_USER_PASSWORD_AUTH` instead of `USER_PASSWORD_AUTH`
- **Choice:** Client allows only the admin flow (`admin-initiate-auth`, which needs IAM credentials) and refresh tokens.
- **Alternatives:** Keep USER_PASSWORD_AUTH; SRP; Hosted UI.
- **Reason:** Verified `USER_PASSWORD_AUTH` is now rejected. Test tokens can still be minted by an IAM-authenticated operator, but a client cannot send a password directly to the pool.

## 28. Test pyramid: moto unit tests in CI, smoke test against the deployed stack
- **Choice:** 15 moto tests run on every PR and before every apply; `scripts/smoke_test.sh` checks the real deployment (401, 422, 202 twice, exactly one DynamoDB item).
- **Alternatives:** LocalStack; moto only; a Python integration suite.
- **Reason:** moto proves handler logic cheaply and fast. It cannot prove IAM, the JWT authorizer or the event source mapping, which is where the real bugs were (see WHAT_BROKE). A short shell smoke test covers those with a unique device id per run, so reruns never collide, and it deletes its own Cognito user. LocalStack was skipped: its IAM and API Gateway JWT behaviour is not faithful enough to trust, and the real stack costs cents.

## 29. checkov policy scan with a documented skip list
- **Choice:** `.checkov.yaml` runs in the PR workflow; 15 checks fixed or skipped, each skip has a one-line reason.
- **Alternatives:** Silence nothing and fix everything; tfsec/tflint; no scanner.
- **Reason:** 31 findings at first. Fixed what was cheap and correct (X-Ray on all Lambdas, abort incomplete multipart uploads). The rest are cost or scope trade-offs (VPC, CMKs, replication, 1-year logs). Skipping explicitly in a file reviewers can read is more honest than ignoring the scanner; CI now fails if a new finding appears.

## 30. Alarm set: errors per Lambda, API 5xx, queue age, DLQ depth
- **Choice:** Alarms on Lambda `Errors` (one per function), HTTP API `5xx`, SQS `ApproximateAgeOfOldestMessage` > 300 s for 3 minutes, and the DLQ-not-empty alarm; all notify one SNS topic. `treat_missing_data = notBreaching` so quiet periods stay `OK`.
- **Alternatives:** Alarm on every metric; percentage error rates; anomaly detection.
- **Reason:** Each alarm maps to a different failure: a code bug (Errors), a gateway or integration fault (5xx), a stuck or slow consumer before anything is lost (queue age), and a poison message (DLQ). Queue age is the early warning: it fires minutes before a message can reach the DLQ. Absolute thresholds are fine at this volume; rate-based alarms need traffic to be meaningful.

## 31. Dashboard and saved Logs Insights queries as code
- **Choice:** One dashboard (API, queue and DLQ, Lambda errors/throttles, p95 duration, alarm panel) and three saved queries, all in Terraform.
- **Alternatives:** Build in the console; Grafana.
- **Reason:** `infra/` is destroyed daily, so console-built dashboards would vanish. The queries read the JSON fields from day 4 (`msg`, `status`, `duration_ms`, `outcome`) with no parsing.

## 32. API access logs as JSON in a dedicated log group
- **Choice:** HTTP API stage writes JSON access logs (request id, route, status, latency, authorizer error) with 14-day retention.
- **Alternatives:** No access logs; plain format.
- **Reason:** Rejected requests (401) never reach the Lambda, so only the gateway log shows them. The same `requestId` appears in the Lambda log, so one request can be traced across both. This also removes a checkov skip.

## 33. Alert email is optional and set only locally
- **Choice:** `alert_email` defaults to empty; the SNS subscription is created only when passed (`-var alert_email=...`). CI applies leave it empty.
- **Alternatives:** Commit the address; store it in a repo variable; Secrets Manager.
- **Reason:** The repo is public. The stack is destroyed daily, and an email subscription must be re-confirmed after each recreate, so a permanent subscription would need a topic that is not destroyed (candidate for a later change).

## 34. Alert email in Secrets Manager, read by Terraform
- **Choice:** The address lives in the secret `aws-ingestion/alert-email` (created once with the CLI). `bootstrap/` reads it with a data source for the budget and the SNS subscription. The `alert_email` variable is gone.
- **Alternatives:** `-var` on every run; a gitignored tfvars file; SSM Parameter Store (free).
- **Reason:** One place for the value, nothing to remember or paste, and no `-var` flag that CI would have to know about. Cost is about 0.40 USD/month, inside the 10 USD budget. SSM would be free, but Secrets Manager is the service the project scope calls for, and rotation/audit features are the point of the exercise. Trade-off: the value still lands in the (private, encrypted, versioned) state file, which is acceptable for an email address, not for a real credential.

## 35. Persistent alert topic in `bootstrap/`, unencrypted on purpose
- **Choice:** SNS topic `aws-ingestion-alerts`, topic policy allowing `cloudwatch.amazonaws.com` (conditioned on this account), email subscription. `infra/` builds the topic ARN from the name.
- **Alternatives:** Keep the topic in `infra/` (destroyed daily, subscription re-confirmed each time); encrypt with a customer-managed KMS key.
- **Reason:** Moving it means the email is confirmed once. The topic is not encrypted with `alias/aws/sns` because CloudWatch alarms cannot publish to topics using the AWS-managed key; a CMK would cost about 1 USD/month for messages that hold only alarm names and numbers. The earlier topic in `infra/` was encrypted that way and would have failed silently.
- **Verified:** forcing an alarm with `set-alarm-state` produced "Successfully executed action ...aws-ingestion-alerts" in the alarm history.
