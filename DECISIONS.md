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
