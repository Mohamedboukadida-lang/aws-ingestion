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
