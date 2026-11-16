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

## Day 4: nothing broke on deploy
- Verified live: the real API Gateway request id appears in the JSON log line, and an X-Ray trace was recorded. First request took ~950 ms (cold start with a large zip), which is worth revisiting in the day 12 load test.

## Day 5: `terraform destroy` failed with BucketNotEmpty
- **Symptom:** `DeleteBucket` returned 409 `BucketNotEmpty`; every other resource was already destroyed.
- **Cause:** The consumer had archived an object under `raw/`. Terraform will not delete a non-empty bucket by default.
- **Fix:** Added `force_destroy = true` to the dev archive bucket, applied it, then destroyed.
- **Lesson:** Anything that writes into a bucket makes destroy fail. Decide per environment: force_destroy in dev, never in prod.

## Day 5: DLQ redrive takes ~9 minutes, not seconds
- **Symptom:** A poison message sat in the main queue for about 9 minutes before reaching the DLQ.
- **Cause:** `maxReceiveCount = 3` and a 180 s visibility timeout: each failed attempt is retried only after the timeout expires.
- **Fix:** None; this is the intended trade-off.
- **Lesson:** Visibility timeout sets retry cadence. The doc's "DLQ in minutes" is really 2 x visibility timeout plus processing.

## Day 6: provider deprecation warning on the DynamoDB table
- **Symptom:** `hash_key is deprecated. Use key_schema instead.` on validate.
- **Cause:** AWS provider 6.x is moving DynamoDB keys to a `key_schema` block.
- **Fix:** Left as is (works, warning only). Revisit when pinning provider versions in CI.
- **Lesson:** Warnings in CI will become errors eventually; track them.

## Day 6: not verified live
- The DLQ alarm only showed state `OK` (no failing message was sent) and `redrive_dlq.sh` was not run. The cron schedule was confirmed `ENABLED` but not waited on; the Lambda was invoked directly.

## Day 8: OIDC `AssumeRoleWithWebIdentity` denied from GitHub Actions
- **Symptom:** `Not authorized to perform sts:AssumeRoleWithWebIdentity` after many retries, though the trust policy looked right.
- **Cause:** The repo uses immutable subject claims, so the token `sub` is `repo:Owner@id/repo@id:pull_request`, not `repo:Owner/repo:pull_request`.
- **Fix:** Read the real prefix with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` and trust that.
- **Lesson:** Check the actual `sub` before debugging the rest. Retries with the same wrong claim just burn time.

## Day 8: first CI apply failed on `lambda:TagResource`
- **Symptom:** `CreateEventSourceMapping` returned 403 for `lambda:TagResource` on `event-source-mapping:*`.
- **Cause:** `default_tags` tags the mapping, and the apply role had only the Create/Update/Delete actions.
- **Fix:** Added `TagResource`, `UntagResource`, `ListTags` to the mapping statement.
- **Lesson:** Least privilege is discovered by running the pipeline. A real apply is the only complete test of the policy, and it also proves `destroy` works.

## Day 9: checkov reported 31 failures on a stack I considered clean
- **Symptom:** `uvx checkov -d infra` showed 31 failed checks across Lambda, S3, logs and API Gateway.
- **Cause:** Defaults I had not chosen deliberately: no X-Ray on two Lambdas, no multipart-upload abort rule, plus CMK/VPC/replication checks that do not fit a low-cost dev project.
- **Fix:** Fixed the two real gaps; skipped the rest in `.checkov.yaml` with a reason per line.
- **Lesson:** A scanner is useful for the conversation it forces: every skip is a trade-off I can now explain.

## Day 10: "Error acquiring the state lock" during a local apply
- **Symptom:** `terraform apply` failed with a 412 PreconditionFailed on the `.tflock` object; the lock was held by my own user.
- **Cause:** An earlier apply (started a second before, same command) was still running; native S3 locking correctly blocked the second. The state file grew while I checked, then the lock cleared.
- **Fix:** Waited for the lock to clear and confirmed with `terraform plan` (No changes) instead of forcing an unlock.
- **Lesson:** Do not `force-unlock` a lock that is actively held; check that no terraform process is running and that the state is changing first. This is the S3 `use_lockfile` behaviour working as designed.

## Day 10: alarm for a failed invocation took ~2 minutes to reach ALARM
- **Symptom:** Right after a deliberately bad Lambda invoke, the alarm showed `INSUFFICIENT_DATA`, then `OK`, then `ALARM`.
- **Cause:** Lambda metrics are published with a delay and alarms evaluate on 5-minute periods.
- **Fix:** None; expected. Verified the alarm fires.
- **Lesson:** Alarms are not instant. Do not use a 5-minute-period alarm as a readiness check right after a deploy.

## Day 10: `terraform destroy` hit a state lock held by another process
- **Symptom:** `Error acquiring the state lock` (S3 `PreconditionFailed`) right after the previous commands.
- **Cause:** Another destroy of the same stack was already running (its lock file and `terraform-provider-aws` child process were visible). It finished on its own, so the state ended empty.
- **Fix:** Did not force-unlock. Inspected the `.tflock` object (who, when, operation), confirmed the process was alive, waited for it to finish, then verified the state and the account were empty.
- **Lesson:** A lock is protection, not an error to bypass. Read who holds it first; `force-unlock` on a live operation can corrupt state.

## Day 10: access log group looked empty at first
- **Symptom:** No lines in the API access log group right after the smoke test.
- **Cause:** Log delivery lag of about a minute.
- **Fix:** Re-queried after a short wait; JSON lines (including the 401 with `authorizerErr`) appeared.
- **Lesson:** Wait before concluding logging is broken.
