#!/usr/bin/env python3
"""
Test harness — simulate a supplier posting a PO change request to the
platform API ingest endpoint.

Usage (values from SSM — recommended):
    python post_po_change.py --region ap-southeast-2

Usage (values explicit):
    python post_po_change.py \
        --endpoint https://<api-id>.execute-api.ap-southeast-2.amazonaws.com/v1/events \
        --api-key  <key-value>

The script posts a single sample payload and prints the HTTP response.
Edit SAMPLE_PAYLOAD below to test different change types.
"""

import argparse
import json
import sys
from datetime import datetime, timezone

import boto3
import requests


# ── Sample payload ─────────────────────────────────────────────────────────────
# Edit this to test different scenarios.
#
# change_type options:
#   QUANTITY_CHANGE  — supplier can no longer fulfil the original qty
#   PRICE_CHANGE     — agreed unit price has changed
#   DATE_CHANGE      — delivery date needs to move
#   CANCELLATION     — supplier cannot fulfil the PO at all

SAMPLE_PAYLOAD = {
    "po_id":            "PO-2024-001",
    "supplier_id":      "SUP-001",
    "change_type":      "QUANTITY_CHANGE",
    "line_id":          "POL-001",
    "original_value":   "100",
    "requested_value":  "80",
    "reason":           "Component shortage due to Q3 supplier disruption — can only fulfil 80 units",
    "requested_by":     "procurement@acmesupplies.com.au",
    "requested_at":     datetime.now(timezone.utc).isoformat(),
}


def get_endpoint_and_key_from_ssm(region: str) -> tuple[str, str]:
    """Read the endpoint URL and API key value from SSM + API Gateway."""
    ssm = boto3.client("ssm", region_name=region)
    apigw = boto3.client("apigateway", region_name=region)

    endpoint = ssm.get_parameter(
        Name="/mdp/platform/api_ingest_endpoint"
    )["Parameter"]["Value"]

    key_id = ssm.get_parameter(
        Name="/mdp/platform/api_ingest_key_id"
    )["Parameter"]["Value"]

    # Retrieve the actual secret key value from API Gateway
    key_value = apigw.get_api_key(
        apiKey=key_id,
        includeValue=True,
    )["value"]

    return endpoint, key_value


def post_event(endpoint: str, api_key: str, payload: dict) -> None:
    headers = {
        "Content-Type":   "application/json",
        "X-Api-Key":      api_key,
        "X-Data-Product": "whitegoods_inventory",
        "X-Event-Type":   "po_changes",
    }

    print("── Request ────────────────────────────────────────────────")
    print(f"POST {endpoint}")
    print(f"X-Data-Product: whitegoods_inventory")
    print(f"X-Event-Type:   po_changes")
    print(f"\nPayload:\n{json.dumps(payload, indent=2)}")
    print()

    resp = requests.post(endpoint, json=payload, headers=headers, timeout=15)

    print("── Response ───────────────────────────────────────────────")
    print(f"Status : {resp.status_code} {resp.reason}")
    try:
        print(f"Body   : {json.dumps(resp.json(), indent=2)}")
    except Exception:
        print(f"Body   : {resp.text}")

    if resp.status_code == 202:
        event_id = resp.json().get("event_id", "<unknown>")
        print(f"\n✓ Event accepted — event_id: {event_id}")
        print(f"\nVerify in Snowflake (after Snowpipe processes, ~30–60s):")
        print(f"  SELECT * FROM WHITEGOODS_RAW.API_EVENTS.PO_CHANGE_REQUESTS")
        print(f"  WHERE EVENT_ID = '{event_id}';")
    else:
        print(f"\n✗ Request failed — check endpoint, API key, and payload")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Post a sample PO change request to the platform API ingest endpoint."
    )
    parser.add_argument(
        "--endpoint",
        help="Full HTTPS URL of the /events endpoint. If omitted, read from SSM.",
    )
    parser.add_argument(
        "--api-key",
        dest="api_key",
        help="API Gateway key value. If omitted, read from SSM + API Gateway.",
    )
    parser.add_argument(
        "--region",
        default="ap-southeast-2",
        help="AWS region — used when reading from SSM (default: ap-southeast-2)",
    )
    args = parser.parse_args()

    if args.endpoint and args.api_key:
        endpoint = args.endpoint
        api_key  = args.api_key
    else:
        print(f"Reading endpoint and API key from SSM (region: {args.region})...")
        endpoint, api_key = get_endpoint_and_key_from_ssm(args.region)
        print(f"Endpoint: {endpoint}\n")

    post_event(endpoint, api_key, SAMPLE_PAYLOAD)


if __name__ == "__main__":
    main()
