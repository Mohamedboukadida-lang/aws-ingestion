from datetime import datetime, timezone
from decimal import Decimal

import boto3
import pytest
from moto import mock_aws

TABLE = "events"


def put(ddb, key, device, kind, value, day):
    ddb.put_item(
        Item={
            "pk": f"EVENT#{key}",
            "sk": "v1",
            "device_id": device,
            "kind": kind,
            "value": Decimal(str(value)),
            "recorded_at": f"{day}T10:00:00Z",
            "day": day,
        }
    )


@pytest.fixture
def agg(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-central-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("TABLE_NAME", TABLE)
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName=TABLE,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
                {"AttributeName": "day", "AttributeType": "S"},
                {"AttributeName": "recorded_at", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "by_day",
                    "KeySchema": [
                        {"AttributeName": "day", "KeyType": "HASH"},
                        {"AttributeName": "recorded_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        import aggregate.app as mod

        mod._table = None
        yield mod, boto3.resource("dynamodb").Table(TABLE)


def aggs(tbl):
    return {i["sk"]: i for i in tbl.scan()["Items"] if i["pk"].startswith("AGG#")}


def test_target_day_defaults_to_yesterday_utc(agg):
    mod, _ = agg
    now = datetime(2026, 11, 15, 0, 5, tzinfo=timezone.utc)
    assert mod.target_day({}, now) == "2026-11-14"
    assert mod.target_day({"day": "2026-01-02"}, now) == "2026-01-02"
    with pytest.raises(ValueError):
        mod.target_day({"day": "not-a-day"}, now)


def test_computes_stats_per_device_and_kind(agg):
    mod, tbl = agg
    put(tbl, "a", "dev-1", "heart_rate", 60, "2026-11-14")
    put(tbl, "b", "dev-1", "heart_rate", 80, "2026-11-14")
    put(tbl, "c", "dev-1", "steps", 1000, "2026-11-14")
    put(tbl, "d", "dev-2", "heart_rate", 70, "2026-11-14")
    put(tbl, "e", "dev-1", "heart_rate", 200, "2026-11-13")  # other day, ignored
    out = mod.handler({"day": "2026-11-14"}, None)
    assert out == {"day": "2026-11-14", "groups": 3}
    hr = aggs(tbl)["dev-1#heart_rate"]
    assert (hr["count"], hr["min"], hr["max"], hr["avg"]) == (2, 60, 80, 70)


def test_rerun_is_idempotent(agg):
    mod, tbl = agg
    put(tbl, "a", "dev-1", "steps", 10, "2026-11-14")
    mod.handler({"day": "2026-11-14"}, None)
    mod.handler({"day": "2026-11-14"}, None)
    assert len(aggs(tbl)) == 1


def test_day_with_no_events_writes_nothing(agg):
    mod, tbl = agg
    assert mod.handler({"day": "2026-11-14"}, None) == {"day": "2026-11-14", "groups": 0}
    assert aggs(tbl) == {}
