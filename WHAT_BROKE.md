# What broke

Format: symptom, cause, fix, lesson.

## Day 1: `InvalidClientTokenId` from the AWS CLI
- **Symptom:** `aws sts get-caller-identity` failed with "The security token included in the request is invalid".
- **Cause:** The configured access key was not a valid AWS key (real long-term keys start with `AKIA`). Re-running `aws configure` and pressing Enter kept the bad value.
- **Fix:** Entered a valid key pair.
- **Lesson:** Verify with `aws sts get-caller-identity` after every credential change, and read the ARN in the output.

## Day 1: CLI was using root credentials
- **Symptom:** The caller ARN ended in `:root`.
- **Cause:** Keys had been created for the root user.
- **Fix:** Create an IAM admin user, enable MFA on root, delete the root access key, reconfigure the CLI with the IAM user's key.
- **Lesson:** Never run Terraform as root. This is the SAA "secure the root account" best practice in practice.

## Day 1: apt repo failed to match the distro (Kali)
- **Symptom:** `lsb_release -cs` returns `kali-rolling`, which HashiCorp's apt repo does not serve.
- **Fix:** Use the Debian codename (`bookworm`) in the repo line.

## Day 1: Cursor added a `Co-authored-by` trailer to commits
- **Symptom:** Commits carried `Co-authored-by: Cursor <cursoragent@cursor.com>`.
- **Cause:** The editor injects the trailer when it runs `git commit`.
- **Fix:** Local `commit-msg` hook strips the line; amended and force-pushed the first commit.
- **Lesson:** Check `git log --format=%B` before pushing to a public repo.

## Day 2: S3 lifecycle and SQS redrive policy resources were slow to create
- **Symptom:** `aws_s3_bucket_lifecycle_configuration` took ~56 s and `aws_sqs_queue_redrive_allow_policy` ~25 s to apply; destroying the queues took ~43 s.
- **Cause:** Eventual consistency in the AWS APIs; the provider polls until the setting is visible.
- **Fix:** None needed, just wait.
- **Lesson:** Slow is not stuck; check `Still creating...` output before interrupting an apply.

## Day 3: expected 401 with the access token, got 202
- **Symptom:** The course notes predicted Cognito access tokens would fail the JWT authorizer. Both the ID and access tokens returned 202.
- **Cause:** Access tokens have no `aud`, but the HTTP API JWT authorizer validates the `client_id` claim in that case.
- **Fix:** None needed. Documented the real behaviour in DECISIONS.
- **Lesson:** Verify claims from docs with a test. Choose the token type deliberately: access tokens are meant for API authorization, ID tokens for identity.

## Day 3: `eod.sh` failed with a pytest collection error
- **Symptom:** `python -m pytest` errored on import in the close script.
- **Cause:** System Python has none of the project's dependencies; they live in uv's `.venv`.
- **Fix:** `eod.sh` now runs `uv run pytest -q`.
- **Lesson:** Scripts should call the project's tool runner, not whichever Python is on PATH.
