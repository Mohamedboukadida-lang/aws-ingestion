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
