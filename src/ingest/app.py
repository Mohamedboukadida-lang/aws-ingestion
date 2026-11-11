import json
import logging
import os

import boto3
from fastapi import FastAPI, status
from mangum import Mangum

from ingest.models import Event

logger = logging.getLogger()
logger.setLevel(logging.INFO)

app = FastAPI(title="ingest")
_sqs = None


def sqs():
    global _sqs
    if _sqs is None:
        _sqs = boto3.client("sqs")
    return _sqs


@app.post("/events", status_code=status.HTTP_202_ACCEPTED)
def post_event(event: Event):
    key = event.idempotency_key()
    body = event.model_dump(mode="json") | {"idempotency_key": key}
    sqs().send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(body),
    )
    logger.info(json.dumps({"msg": "enqueued", "idempotency_key": key}))
    return {"accepted": True, "idempotency_key": key}


handler = Mangum(app)
