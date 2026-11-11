import json
import logging
import os
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse
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


def log(**fields):
    logger.info(json.dumps(fields))


@app.middleware("http")
async def request_logging(request: Request, call_next):
    """One structured log line per request, for CloudWatch Logs Insights."""
    start = time.perf_counter()
    # API Gateway HTTP API (payload v2) puts the request id in the Lambda event.
    aws_event = request.scope.get("aws.event") or {}
    request_id = aws_event.get("requestContext", {}).get("requestId")
    response = await call_next(request)
    log(
        msg="request",
        request_id=request_id,
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=round((time.perf_counter() - start) * 1000, 1),
    )
    return response


@app.exception_handler(BotoCoreError)
@app.exception_handler(ClientError)
async def aws_error_handler(request: Request, exc: Exception):
    # Do not leak AWS error details to the caller; log them instead.
    logger.error(json.dumps({"msg": "sqs_send_failed", "error": type(exc).__name__}))
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"accepted": False, "detail": "temporarily unavailable, retry"},
        headers={"Retry-After": "5"},
    )


@app.post("/events", status_code=status.HTTP_202_ACCEPTED)
def post_event(event: Event):
    key = event.idempotency_key()
    body = event.model_dump(mode="json") | {"idempotency_key": key}
    sqs().send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(body),
    )
    log(msg="enqueued", idempotency_key=key, device_id=event.device_id, kind=event.kind)
    return {"accepted": True, "idempotency_key": key}


handler = Mangum(app)
