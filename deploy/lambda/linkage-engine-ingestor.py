"""
deploy/lambda/linkage-engine-ingestor.py

Lambda function triggered by S3 ObjectCreated events on the raw bucket
(linkage-engine-raw-<account>). Splits large NDJSON files into CHUNK_SIZE-line
chunks, writes each chunk to the landing bucket, then archives the original.

This is the entry point for external-party uploads. The raw bucket is the only
bucket the uploader role can write to — the landing bucket is never exposed
to external parties.

Pipeline position:
    linkage-engine-raw-<account>   (external party uploads here)
          │  S3 ObjectCreated → linkage-engine-ingestor  (this Lambda)
          ▼
    linkage-engine-landing-<account>  (chunks written here)
          │  S3 ObjectCreated → linkage-engine-validate
          ▼
    validated/ + quarantine/

Environment variables (set by deploy/provision-lambda.sh):
    LANDING_BUCKET  — destination bucket for chunk files
    CHUNK_SIZE      — max lines per chunk (default: 200)
                      Tune: CHUNK_SIZE = floor(600 / p99_latency_per_record)
                      where 600s = half the 15-min Lambda TTL

Trigger:
    S3 ObjectCreated:* on linkage-engine-raw-<account>
"""

import json
import logging
import math
import os
import urllib.parse
from pathlib import PurePosixPath

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

LANDING_BUCKET = os.environ.get("LANDING_BUCKET", "")
CHUNK_SIZE     = int(os.environ.get("CHUNK_SIZE", "200"))


# ── Core processing ───────────────────────────────────────────────────────────

def process_object(raw_bucket: str, key: str,
                   landing_bucket: str, chunk_size: int) -> dict:
    """
    Read an NDJSON file from the raw bucket, split into chunk_size-line chunks,
    write each chunk to the landing bucket, then archive the original.
    Returns a summary dict.
    """
    logger.info("Ingestor: s3://%s/%s → %s (chunk_size=%d)",
                raw_bucket, key, landing_bucket, chunk_size)

    response = s3.get_object(Bucket=raw_bucket, Key=key)
    body     = response["Body"].read().decode("utf-8")
    lines    = [l for l in body.splitlines() if l.strip()]
    total    = len(lines)

    if total == 0:
        logger.warning("  Empty file — nothing to split")
        _archive_original(raw_bucket, key)
        return {"raw_bucket": raw_bucket, "key": key,
                "total": 0, "chunks": 0, "chunk_keys": []}

    # Split into chunks
    num_chunks = math.ceil(total / chunk_size)
    stem   = PurePosixPath(key).stem
    suffix = PurePosixPath(key).suffix or ".ndjson"

    chunk_keys = []
    for idx in range(num_chunks):
        chunk_lines = lines[idx * chunk_size : (idx + 1) * chunk_size]
        chunk_key   = f"{stem}-chunk-{idx + 1:03d}{suffix}"
        chunk_body  = "\n".join(chunk_lines) + "\n"

        s3.put_object(
            Bucket=landing_bucket,
            Key=chunk_key,
            Body=chunk_body.encode("utf-8"),
            ContentType="application/x-ndjson",
        )
        chunk_keys.append(chunk_key)
        logger.info("  chunk %d/%d → s3://%s/%s  (%d lines)",
                    idx + 1, num_chunks, landing_bucket, chunk_key, len(chunk_lines))

    # Archive original then delete from raw bucket
    _archive_original(raw_bucket, key)

    result = {
        "raw_bucket":     raw_bucket,
        "key":            key,
        "landing_bucket": landing_bucket,
        "total":          total,
        "chunks":         num_chunks,
        "chunk_keys":     chunk_keys,
    }
    logger.info("  done: total=%d chunks=%d", total, num_chunks)
    return result


def _archive_original(raw_bucket: str, key: str) -> None:
    """Copy original to archive/<key> in the raw bucket, then delete the original."""
    archive_key = f"archive/{key}"
    try:
        s3.copy_object(
            Bucket=raw_bucket,
            CopySource={"Bucket": raw_bucket, "Key": key},
            Key=archive_key,
        )
        s3.delete_object(Bucket=raw_bucket, Key=key)
        logger.info("  archived: s3://%s/%s", raw_bucket, archive_key)
    except Exception as e:
        logger.error("  Failed to archive %s: %s", key, e)


# ── Lambda entry point ────────────────────────────────────────────────────────

def handler(event, context):
    if not LANDING_BUCKET:
        raise RuntimeError("LANDING_BUCKET environment variable is not set")

    results = []
    for record in event.get("Records", []):
        if not record.get("eventName", "").startswith("ObjectCreated"):
            continue
        raw_bucket = record["s3"]["bucket"]["name"]
        key        = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        # Skip archive/ prefix to avoid re-processing archived originals
        if key.startswith("archive/"):
            logger.info("Skipping archived file: %s", key)
            continue

        if not (key.endswith(".ndjson") or key.endswith(".json") or key.endswith(".jsonl")):
            logger.info("Skipping non-NDJSON file: %s", key)
            continue

        results.append(process_object(raw_bucket, key, LANDING_BUCKET, CHUNK_SIZE))

    return {
        "statusCode": 200,
        "body": json.dumps({"processed": len(results), "results": results}),
    }


if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if len(sys.argv) != 3:
        print("Usage: python3 linkage-engine-ingestor.py <raw-bucket> <key>")
        sys.exit(1)
    fake_event = {"Records": [{"eventName": "ObjectCreated:Put",
                                "s3": {"bucket": {"name": sys.argv[1]},
                                       "object": {"key": sys.argv[2]}}}]}
    print(json.dumps(handler(fake_event, None), indent=2))
