#!/usr/bin/env bash
# End-to-end check against a deployed stack: auth, validation, idempotency, storage.
# Needs IAM credentials (admin-initiate-auth, DynamoDB read) and a deployed infra/.
set -euo pipefail
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
pool=$(out user_pool_id); client=$(out user_pool_client_id); url=$(out api_url)
table="aws-ingestion-dev-events"
user="smoke-$$"; pass='Smoke-Test-Pass-123!'
fail() { echo "FAIL: $*" >&2; cleanup; exit 1; }
cleanup() { aws cognito-idp admin-delete-user --user-pool-id "$pool" --username "$user" 2>/dev/null || true; }
trap cleanup EXIT

aws cognito-idp admin-create-user --user-pool-id "$pool" --username "$user" --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$pool" --username "$user" --password "$pass" --permanent
token=$(aws cognito-idp admin-initiate-auth --user-pool-id "$pool" --client-id "$client" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH --auth-parameters "USERNAME=$user,PASSWORD=$pass" \
  --query AuthenticationResult.IdToken --output text)

post() { # post <auth-header-or-none> <json>  -> prints "<status> <body>"
  local hdr=()
  [ "$1" != none ] && hdr=(-H "Authorization: Bearer $1")
  curl -s -w ' %{http_code}' -X POST "$url/events" "${hdr[@]}" -H 'Content-Type: application/json' -d "$2"
}
status() { echo "${1##* }"; }

# unique per run so reruns never collide with earlier data
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dev="smoke-$$-$RANDOM"
good="{\"device_id\":\"$dev\",\"kind\":\"steps\",\"value\":42,\"recorded_at\":\"$ts\"}"

[ "$(status "$(post none "$good")")" = 401 ] || fail "no token should be 401"
echo "ok  401 without token"
[ "$(status "$(post "$token" "${good/steps/blood_pressure}")")" = 422 ] || fail "bad kind should be 422"
echo "ok  422 on invalid kind"

r1=$(post "$token" "$good"); r2=$(post "$token" "$good")
[ "$(status "$r1")" = 202 ] && [ "$(status "$r2")" = 202 ] || fail "valid event should be 202 (got: $r1 / $r2)"
key=$(echo "${r1% *}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["idempotency_key"])')
echo "ok  202 twice, key ${key:0:12}..."

for _ in $(seq 1 20); do
  n=$(aws dynamodb query --table-name "$table" --key-condition-expression 'pk = :p' \
    --expression-attribute-values "{\":p\":{\"S\":\"EVENT#$key\"}}" --select COUNT --query Count --output text)
  [ "$n" -ge 1 ] && break
  sleep 3
done
sleep 5  # give a (wrongly) duplicated write time to show up
n=$(aws dynamodb query --table-name "$table" --key-condition-expression 'pk = :p' \
  --expression-attribute-values "{\":p\":{\"S\":\"EVENT#$key\"}}" --select COUNT --query Count --output text)
[ "$n" = 1 ] || fail "expected exactly 1 stored item for a duplicated event, found $n"
echo "ok  exactly 1 DynamoDB item for 2 submissions"
echo "SMOKE TEST PASSED"
