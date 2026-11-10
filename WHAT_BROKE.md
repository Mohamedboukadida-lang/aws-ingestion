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
