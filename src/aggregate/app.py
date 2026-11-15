"""Daily aggregation: per (device, kind) count/min/max/avg for one UTC day.

Triggered by EventBridge Scheduler once a day for *yesterday*; an event of the
form {"day": "YYYY-MM-DD"} reprocesses any other day. Results are written with a
deterministic key, so re-running a day overwrites the same items (idempotent).
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

INDEX = "by_day"
_table = None


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def target_day(event: dict, now: datetime | None = None) -> str:
    if event.get("day"):
        datetime.strptime(event["day"], "%Y-%m-%d")  # validate
        return event["day"]
    now = now or datetime.now(timezone.utc)
    return (now - timedelta(days=1)).strftime("%Y-%m-%d")


def events_for_day(day: str):
    kwargs = {"IndexName": INDEX, "KeyConditionExpression": Key("day").eq(day)}
    while True:
        page = table().query(**kwargs)
        yield from page["Items"]
        if "LastEvaluatedKey" not in page:
            return
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def aggregate(items) -> dict:
    groups: dict[tuple[str, str], list[Decimal]] = {}
    for it in items:
        groups.setdefault((it["device_id"], it["kind"]), []).append(it["value"])
    return {
        k: {
            "count": len(v),
            "min": min(v),
            "max": max(v),
            "avg": (sum(v) / len(v)).quantize(Decimal("0.01")),
        }
        for k, v in groups.items()
    }


def handler(event, context):
    day = target_day(event or {})
    results = aggregate(events_for_day(day))
    for (device, kind), stats in results.items():
        table().put_item(Item={"pk": f"AGG#{day}", "sk": f"{device}#{kind}", "day_agg": day, **stats})
    logger.info(json.dumps({"msg": "aggregated", "day": day, "groups": len(results)}))
    return {"day": day, "groups": len(results)}
