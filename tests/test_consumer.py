import json

import boto3
import pytest
from moto import mock_aws

BUCKET = "archive"
TABLE = "events"

EVENT = {
    "device_id": "dev-1",
    "kind": "heart_rate",
    "value": 72.5,
    "recorded_at": "2026-11-10T10:00:00Z",
    "idempotency_key": "abc123",
}


def sqs_record(body, message_id="m1"):
    return {"messageId": message_id, "body": body if isinstance(body, str) else json.dumps(body)}


@pytest.fixture
def aws(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-central-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("ARCHIVE_BUCKET", BUCKET)
    monkeypatch.setenv("TABLE_NAME", TABLE)
    with mock_aws():
        boto3.client("s3").create_bucket(
            Bucket=BUCKET,
            CreateBucketConfiguration={"LocationConstraint": "eu-central-1"},
        )
        boto3.client("dynamodb").create_table(
            TableName=TABLE,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        import consumer.app as mod

        mod._s3 = None
        mod._ddb = None
        yield mod


def items():
    return boto3.resource("dynamodb").Table(TABLE).scan()["Items"]


def objects():
    return boto3.client("s3").list_objects_v2(Bucket=BUCKET).get("Contents", [])


def test_event_is_stored_and_archived(aws):
    out = aws.handler({"Records": [sqs_record(EVENT)]}, None)
    assert out == {"batchItemFailures": []}
    assert len(items()) == 1
    assert items()[0]["pk"] == "EVENT#abc123"
    assert [o["Key"] for o in objects()] == ["raw/2026-11-10/abc123.json"]


def test_same_event_twice_creates_no_duplicate(aws):
    aws.handler({"Records": [sqs_record(EVENT, "m1")]}, None)
    out = aws.handler({"Records": [sqs_record(EVENT, "m2")]}, None)
    assert out == {"batchItemFailures": []}
    assert len(items()) == 1
    assert len(objects()) == 1


def test_duplicate_within_one_batch(aws):
    out = aws.handler({"Records": [sqs_record(EVENT, "m1"), sqs_record(EVENT, "m2")]}, None)
    assert out == {"batchItemFailures": []}
    assert len(items()) == 1


def test_poison_message_fails_only_that_record(aws):
    good = EVENT | {"idempotency_key": "good"}
    out = aws.handler(
        {"Records": [sqs_record("not json", "bad"), sqs_record(good, "ok")]},
        None,
    )
    assert out == {"batchItemFailures": [{"itemIdentifier": "bad"}]}
    assert [i["pk"] for i in items()] == ["EVENT#good"]


def test_dynamodb_failure_is_retried_and_archive_survives(aws, monkeypatch):
    class Broken:
        def put_item(self, **_):
            raise RuntimeError("throttled")

    monkeypatch.setattr(aws, "_ddb", Broken())
    out = aws.handler({"Records": [sqs_record(EVENT, "m1")]}, None)
    assert out == {"batchItemFailures": [{"itemIdentifier": "m1"}]}
    assert len(objects()) == 1  # raw payload already archived

    monkeypatch.setattr(aws, "_ddb", None)  # recover; redelivery succeeds
    out = aws.handler({"Records": [sqs_record(EVENT, "m1")]}, None)
    assert out == {"batchItemFailures": []}
    assert len(items()) == 1
    assert len(objects()) == 1
