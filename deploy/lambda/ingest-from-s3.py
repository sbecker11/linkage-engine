"""
deploy/lambda/ingest-from-s3.py

Lambda function triggered by S3 ObjectCreated events on the landing bucket.
Reads each NDJSON file line by line and POSTs each record to the
linkage-engine /v1/records API via the internal ALB.

Environment variables (set by deploy/provision-lambda.sh):
    LINKAGE_API_URL   — ALB base URL, e.g. http://linkage-engine-alb-xxx.us-west-1.elb.amazonaws.com
    BATCH_SIZE        — records per batch pause (default: 50)
    DRY_RUN           — set to "true" to parse without POSTing (default: false)

Trigger:
    S3 event notification: s3:ObjectCreated:* on prefix landing/

Dead-letter queue:
    Any unprocessed event is sent to the Lambda DLQ (SQS) configured by
    deploy/provision-lambda.sh for manual inspection and replay.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

API_URL   = os.environ.get("LINKAGE_API_URL", "").rstrip("/")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "50"))
DRY_RUN   = os.environ.get("DRY_RUN", "false").lower() == "true"

INGEST_ENDPOINT = f"{API_URL}/v1/records"


def post_record(record: dict) -> tuple[int, str]:
    """POST a single record to /v1/records. Returns (status_code, body)."""
    payload = json.dumps(record).encode("utf-8")
    req = urllib.request.Request(
        INGEST_ENDPOINT,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")
    except Exception as e:
        return 0, str(e)


def process_object(bucket: str, key: str) -> dict:
    """Download an NDJSON object from S3 and ingest each line."""
    logger.info("Processing s3://%s/%s", bucket, key)

    response = s3.get_object(Bucket=bucket, Key=key)
    body = response["Body"].read().decode("utf-8")
    lines = [l.strip() for l in body.splitlines() if l.strip()]

    total   = len(lines)
    ok      = 0
    skipped = 0
    failed  = 0
    errors  = []

    logger.info("  %d records to ingest (dry_run=%s)", total, DRY_RUN)

    for i, line in enumerate(lines, 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as e:
            logger.warning("  line %d: invalid JSON — %s", i, e)
            failed += 1
            errors.append({"line": i, "error": f"invalid JSON: {e}", "raw": line[:120]})
            continue

        if not record.get("recordId") or not record.get("givenName") or not record.get("familyName"):
            logger.warning("  line %d: missing required fields (recordId/givenName/familyName)", i)
            skipped += 1
            continue

        if DRY_RUN:
            logger.debug("  [DRY RUN] would POST recordId=%s", record.get("recordId"))
            ok += 1
            continue

        status, body = post_record(record)

        if status in (200, 201, 204):
            ok += 1
        elif status == 409:
            # Conflict = already exists — treat as success (idempotent)
            ok += 1
            logger.debug("  recordId=%s already exists (409)", record.get("recordId"))
        else:
            failed += 1
            msg = f"recordId={record.get('recordId')} → HTTP {status}: {body[:200]}"
            logger.warning("  FAILED: %s", msg)
            errors.append({"line": i, "recordId": record.get("recordId"), "status": status, "body": body[:200]})

        # Brief pause every BATCH_SIZE records to avoid overwhelming the API
        if i % BATCH_SIZE == 0:
            logger.info("  progress: %d/%d  (ok=%d failed=%d)", i, total, ok, failed)
            time.sleep(0.1)

    result = {
        "bucket": bucket,
        "key": key,
        "total": total,
        "ok": ok,
        "skipped": skipped,
        "failed": failed,
        "errors": errors[:20],  # cap error list in response
    }
    logger.info("  done: total=%d ok=%d skipped=%d failed=%d", total, ok, skipped, failed)
    return result


def handler(event, context):
    """Lambda entry point. Handles S3 ObjectCreated events."""
    if not API_URL and not DRY_RUN:
        raise RuntimeError("LINKAGE_API_URL environment variable is not set")

    results = []

    for record in event.get("Records", []):
        event_name = record.get("eventName", "")
        if not event_name.startswith("ObjectCreated"):
            logger.info("Skipping non-create event: %s", event_name)
            continue

        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        # Only process NDJSON / JSON files
        if not (key.endswith(".ndjson") or key.endswith(".json") or key.endswith(".jsonl")):
            logger.info("Skipping non-NDJSON file: %s", key)
            continue

        result = process_object(bucket, key)
        results.append(result)

        if result["failed"] > 0:
            logger.warning(
                "s3://%s/%s — %d records failed to ingest",
                bucket, key, result["failed"]
            )

    return {
        "statusCode": 200,
        "body": json.dumps({"processed": len(results), "results": results}),
    }


# Allow local testing: python3 ingest-from-s3.py bucket key
if __name__ == "__main__":
    import sys
    import urllib.parse
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if len(sys.argv) != 3:
        print("Usage: python3 ingest-from-s3.py <bucket> <key>")
        sys.exit(1)
    fake_event = {"Records": [{"eventName": "ObjectCreated:Put",
                                "s3": {"bucket": {"name": sys.argv[1]},
                                       "object": {"key": sys.argv[2]}}}]}
    print(json.dumps(handler(fake_event, None), indent=2))
