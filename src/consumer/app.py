"""SQS consumer: archive raw payload to S3, then write a processed item to DynamoDB.

Idempotency: the S3 key and the DynamoDB primary key both derive from the
event's idempotency key. S3 is written first (overwriting is harmless); the
DynamoDB write is conditional, so a redelivered event is detected and skipped.
Writing S3 first means a crash between the two steps loses nothing on retry.
"""

import json
import logging
import os
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_s3 = None
_ddb = None


def s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def table():
    global _ddb
    if _ddb is None:
        _ddb = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _ddb


def log(**fields):
    logger.info(json.dumps(fields))


def process(body: str) -> str:
    """Process one message body. Returns 'stored' or 'duplicate'."""
    event = json.loads(body)
    key = event["idempotency_key"]
    day = event["recorded_at"][:10]

    s3().put_object(
        Bucket=os.environ["ARCHIVE_BUCKET"],
        Key=f"raw/{day}/{key}.json",
        Body=body.encode(),
        ContentType="application/json",
    )

    item = {
        "pk": f"EVENT#{key}",
        "sk": "v1",
        "device_id": event["device_id"],
        "kind": event["kind"],
        "value": Decimal(str(event["value"])),
        "recorded_at": event["recorded_at"],
        "day": day,
    }
    try:
        table().put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return "duplicate"
        raise
    return "stored"


def handler(event, context):
    """Partial batch response: only failed records are retried (then DLQ'd)."""
    failures = []
    for record in event["Records"]:
        message_id = record["messageId"]
        try:
            outcome = process(record["body"])
            log(msg="processed", message_id=message_id, outcome=outcome)
        except Exception as exc:  # noqa: BLE001 - any failure means retry this record
            log(msg="record_failed", message_id=message_id, error=type(exc).__name__)
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
