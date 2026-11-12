#!/usr/bin/env bash
# End-of-day: format, validate, run tests, remind to destroy, commit and push.
set -euo pipefail
cd "$(dirname "$0")/.."

terraform -chdir=infra fmt -recursive
terraform -chdir=infra validate

if [ -d tests ]; then
  uv run pytest -q
fi

if terraform -chdir=infra state list 2>/dev/null | grep -q .; then
  echo "!! infra state is not empty. Run: terraform -chdir=infra destroy"
  echo "!! Aborting close commit. Destroy first, then rerun."
  exit 1
fi

day="${1:?usage: scripts/eod.sh <day-number> [message]}"
msg="${2:-close}"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "docs: day ${day} close – ${msg}"
else
  echo "nothing new to commit; pushing existing commits"
fi
git push
