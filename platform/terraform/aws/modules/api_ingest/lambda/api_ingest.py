"""
Platform API ingest Lambda.

Receives HTTP POST events from external systems (suppliers, retailers, portals),
resolves the target data product's raw S3 bucket from SSM, and writes a
JSON file for Snowpipe ingestion.

Required headers:
  X-Data-Product  — registered data product ID, e.g. whitegoods_inventory
  X-Event-Type    — event type / sub-prefix, e.g. po_changes
  X-Api-Key       — API Gateway API key (enforced by API Gateway, not this code)

S3 key written:
  api_events/{event_type}/{YYYY}/{MM}/{DD}/{uuid}.json

Each file is a single JSON object enriched with a _meta block:
  {
    ...original payload fields...,
    "_meta": {
      "event_id":    "<uuid>",
      "event_type":  "po_changes",
      "data_product": "whitegoods_inventory",
      "received_at": "2026-05-01T10:00:05.123456+00:00",
      "source":      "api_ingest"
    }
  }
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

_ssm = None
_s3 = None


def _get_ssm():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION_NAME", "ap-southeast-2"))
    return _ssm


def _get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    # ── Normalise headers (API GW passes them with original casing) ────────────
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    data_product = (headers.get("x-data-product") or "").strip()
    event_type   = (headers.get("x-event-type") or "").strip()

    if not data_product:
        return _response(400, {"error": "X-Data-Product header is required"})
    if not event_type:
        return _response(400, {"error": "X-Event-Type header is required"})

    # ── Resolve raw bucket from SSM ────────────────────────────────────────────
    ssm_param = f"/mdp/data_products/{data_product}/raw_bucket_name"
    try:
        bucket = _get_ssm().get_parameter(Name=ssm_param)["Parameter"]["Value"]
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "ParameterNotFound":
            return _response(404, {"error": f"Unknown data product: {data_product}"})
        raise  # unexpected AWS error — let Lambda retry

    # ── Parse and validate JSON body ───────────────────────────────────────────
    raw_body = event.get("body") or "{}"
    try:
        payload = json.loads(raw_body)
    except (json.JSONDecodeError, ValueError):
        return _response(400, {"error": "Request body must be valid JSON"})

    if not isinstance(payload, dict):
        return _response(400, {"error": "Request body must be a JSON object, not an array"})

    # ── Enrich payload with metadata ───────────────────────────────────────────
    now       = datetime.now(timezone.utc)
    event_id  = str(uuid.uuid4())

    payload["_meta"] = {
        "event_id":     event_id,
        "event_type":   event_type,
        "data_product": data_product,
        "received_at":  now.isoformat(),
        "source":       "api_ingest",
    }

    # ── Write to S3 ────────────────────────────────────────────────────────────
    key = f"api_events/{event_type}/{now.strftime('%Y/%m/%d')}/{event_id}.json"

    _get_s3().put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(payload, default=str),
        ContentType="application/json",
    )

    print(f"Wrote s3://{bucket}/{key}  data_product={data_product}  event_type={event_type}")

    return _response(202, {
        "event_id": event_id,
        "status":   "accepted",
        "message":  "Event queued for processing",
    })
