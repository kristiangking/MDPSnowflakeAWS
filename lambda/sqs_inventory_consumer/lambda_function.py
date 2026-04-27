import json
import os
import uuid
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["RAW_BUCKET"]


def lambda_handler(event, context):
    records = event.get("Records", [])
    if not records:
        return {"statusCode": 200, "body": "No records"}

    # Parse each SQS message body as a JSON object
    events = [json.loads(r["body"]) for r in records]

    # Write the batch as a single JSON array file partitioned by date
    now = datetime.now(timezone.utc)
    key = f"events/inventory/{now.strftime('%Y/%m/%d')}/{uuid.uuid4()}.json"

    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=json.dumps(events),
        ContentType="application/json",
    )

    print(f"Written {len(events)} events to s3://{BUCKET}/{key}")
    return {"statusCode": 200, "body": f"Processed {len(events)} records"}
