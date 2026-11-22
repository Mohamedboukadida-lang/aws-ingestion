#!/usr/bin/env python3
"""Load test against a deployed stack.

Posts N unique events plus D duplicates (resends of earlier events) concurrently,
then waits for the queue to drain and checks that DynamoDB holds exactly N items
for this run (idempotency under load) and that nothing reached the DLQ.

Usage: uv run python scripts/load_test.py [--unique 800] [--dupes 200] [--workers 20]
Needs IAM credentials and a deployed infra/ (reads terraform outputs).
"""

import argparse
import json
import random
import secrets
import statistics
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import boto3
import httpx


def tf(name: str) -> str:
    return subprocess.check_output(["terraform", "-chdir=infra", "output", "-raw", name], text=True).strip()


def get_token(pool: str, client: str, user: str, password: str) -> str:
    idp = boto3.client("cognito-idp")
    idp.admin_create_user(UserPoolId=pool, Username=user, MessageAction="SUPPRESS")
    idp.admin_set_user_password(UserPoolId=pool, Username=user, Password=password, Permanent=True)
    res = idp.admin_initiate_auth(
        UserPoolId=pool, ClientId=client, AuthFlow="ADMIN_USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": user, "PASSWORD": password},
    )
    return res["AuthenticationResult"]["IdToken"]


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p / 100))]


def queue_depth(sqs, url):
    a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"])["Attributes"]
    return int(a["ApproximateNumberOfMessages"]), int(a["ApproximateNumberOfMessagesNotVisible"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unique", type=int, default=800)
    ap.add_argument("--dupes", type=int, default=200)
    ap.add_argument("--workers", type=int, default=20)
    ap.add_argument("--retries", type=int, default=0, help="retry 503/429 with jittered backoff (safe: events are idempotent)")
    args = ap.parse_args()

    run = uuid.uuid4().hex[:8]
    url, pool, client = tf("api_url"), tf("user_pool_id"), tf("user_pool_client_id")
    user, password = f"load-{run}", "Aa1!" + secrets.token_hex(12)  # throwaway user, random password
    idp = boto3.client("cognito-idp")
    sqs = boto3.client("sqs")
    ddb = boto3.client("dynamodb")
    cw = boto3.client("cloudwatch")
    events_q = sqs.get_queue_url(QueueName="aws-ingestion-dev-events")["QueueUrl"]
    dlq = sqs.get_queue_url(QueueName="aws-ingestion-dev-events-dlq")["QueueUrl"]

    token = get_token(pool, client, user, password)
    headers = {"Authorization": f"Bearer {token}"}
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    events = [
        {
            "device_id": f"load-{run}-{i % 20}",
            "kind": ["heart_rate", "steps", "temperature"][i % 3],
            "value": float(i % 100),
            "recorded_at": (base + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        for i in range(args.unique)
    ]
    posts = events + random.sample(events, args.dupes)
    random.shuffle(posts)

    results = []

    retried = [0]
    accepted = set()

    def send(ev):
        t0 = time.perf_counter()
        code = None
        for attempt in range(args.retries + 1):
            try:
                code = http.post(f"{url}/events", json=ev, headers=headers).status_code
            except httpx.HTTPError as exc:
                code = type(exc).__name__
            if code not in (503, 429) or attempt == args.retries:
                break
            retried[0] += 1
            time.sleep(min(8, 0.25 * 2**attempt) * random.uniform(0.5, 1.5))
        if code == 202:
            accepted.add((ev["device_id"], ev["recorded_at"]))
        return code, (time.perf_counter() - t0) * 1000

    start = time.time()
    t_start = datetime.now(timezone.utc)
    with httpx.Client(timeout=30, limits=httpx.Limits(max_connections=args.workers)) as http:
        first = send(events[0])  # likely a cold start; reported separately
        with ThreadPoolExecutor(args.workers) as pool_ex:
            results = list(pool_ex.map(send, posts))
    wall = time.time() - start

    codes = {}
    for c, _ in results:
        codes[c] = codes.get(c, 0) + 1
    lat = [ms for c, ms in results if c == 202]
    print(f"run {run}: {len(posts)} posts ({args.unique} unique + {args.dupes} dupes), {args.workers} workers, {wall:.1f}s, {len(posts)/wall:.0f} req/s")
    print(f"status codes: {codes}  (client retries: {retried[0]})")
    print(f"first request (cold): {first[1]:.0f} ms -> {first[0]}")
    if lat:
        print(f"latency ms  p50={pct(lat,50):.0f} p95={pct(lat,95):.0f} p99={pct(lat,99):.0f} max={max(lat):.0f} mean={statistics.mean(lat):.0f}")

    expected = len(accepted)

    def count_stored():
        total = 0
        kwargs = {"TableName": "aws-ingestion-dev-events", "Select": "COUNT",
                  "FilterExpression": "begins_with(device_id, :p)",
                  "ExpressionAttributeValues": {":p": {"S": f"load-{run}-"}}}
        while True:
            page = ddb.scan(**kwargs)
            total += page["Count"]
            if "LastEvaluatedKey" not in page:
                return total
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    # Queue attribute counts are approximate and lag, so converge on the table itself.
    drain_start = time.time()
    stored = 0
    while time.time() - drain_start < 240:
        stored = count_stored()
        visible, in_flight = queue_depth(sqs, events_q)
        print(f"  stored={stored}/{expected} queue visible={visible} in_flight={in_flight}")
        if stored >= expected and visible == 0 and in_flight == 0:
            break
        time.sleep(5)
    print(f"all accepted events stored {time.time() - drain_start:.0f}s after the last POST")
    time.sleep(10)  # a wrongly duplicated write would show up here
    stored = count_stored()
    dlq_visible, _ = queue_depth(sqs, dlq)

    end = datetime.now(timezone.utc)
    def metric(fn, name, stat="Sum"):
        r = cw.get_metric_statistics(Namespace="AWS/Lambda", MetricName=name, Dimensions=[{"Name": "FunctionName", "Value": fn}],
                                     StartTime=t_start.replace(second=0, microsecond=0), EndTime=end + timedelta(minutes=1), Period=60*60, Statistics=[stat])
        return r["Datapoints"][0][stat] if r["Datapoints"] else 0
    print("lambda: " + ", ".join(
        f"{f}: throttles={metric('aws-ingestion-dev-'+f,'Throttles'):.0f} errors={metric('aws-ingestion-dev-'+f,'Errors'):.0f} maxconc={metric('aws-ingestion-dev-'+f,'ConcurrentExecutions','Maximum'):.0f}"
        for f in ("ingest", "consumer")))

    ok = True
    if stored != expected:
        print(f"FAIL: {expected} unique events were accepted but {stored} are stored"); ok = False
    else:
        print(f"ok  exactly {stored} items stored for {expected} unique accepted events (no loss, no duplicates)")
    if dlq_visible:
        print(f"FAIL: {dlq_visible} message(s) in the DLQ"); ok = False
    else:
        print("ok  DLQ empty")
    if set(codes) - {202}:
        print(f"WARN: non-202 responses: {codes}")
    idp.admin_delete_user(UserPoolId=pool, Username=user)
    print("LOAD TEST PASSED" if ok else "LOAD TEST FAILED")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
