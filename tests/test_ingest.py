import json

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-central-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    with mock_aws():
        q = boto3.client("sqs").create_queue(QueueName="events")
        monkeypatch.setenv("QUEUE_URL", q["QueueUrl"])
        import ingest.app as app_module

        app_module._sqs = None
        yield TestClient(app_module.app), q["QueueUrl"]


VALID = {
    "device_id": "dev-1",
    "kind": "heart_rate",
    "value": 72,
    "recorded_at": "2026-11-10T10:00:00Z",
}


def test_valid_event_is_enqueued(client):
    tc, url = client
    r = tc.post("/events", json=VALID)
    assert r.status_code == 202
    msgs = boto3.client("sqs").receive_message(QueueUrl=url)["Messages"]
    assert json.loads(msgs[0]["Body"])["idempotency_key"] == r.json()["idempotency_key"]


def test_same_event_twice_has_same_key(client):
    tc, _ = client
    a = tc.post("/events", json=VALID).json()["idempotency_key"]
    b = tc.post("/events", json=VALID).json()["idempotency_key"]
    assert a == b


def test_invalid_kind_rejected(client):
    tc, _ = client
    r = tc.post("/events", json=VALID | {"kind": "blood_pressure"})
    assert r.status_code == 422


def test_missing_field_rejected(client):
    tc, _ = client
    bad = {k: v for k, v in VALID.items() if k != "device_id"}
    assert tc.post("/events", json=bad).status_code == 422


def test_queue_failure_returns_503_without_leaking_details(client, monkeypatch):
    tc, _ = client
    monkeypatch.setenv("QUEUE_URL", "https://sqs.eu-central-1.amazonaws.com/000000000000/missing")
    r = tc.post("/events", json=VALID)
    assert r.status_code == 503
    assert r.headers["retry-after"] == "5"
    assert "missing" not in r.text and "000000000000" not in r.text


def test_request_is_logged_as_json(client, caplog):
    tc, _ = client
    with caplog.at_level("INFO"):
        tc.post("/events", json=VALID)
    lines = [json.loads(r.message) for r in caplog.records if r.message.startswith("{")]
    req = next(line for line in lines if line["msg"] == "request")
    assert req["method"] == "POST" and req["path"] == "/events" and req["status"] == 202
    assert "duration_ms" in req
