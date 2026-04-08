"""
deploy/lambda/validate-and-route.py

Lambda function triggered by S3 ObjectCreated events on the landing/ prefix.
Validates each NDJSON file line by line and routes records to:
  - validated/<key>   — passed all rules; safe for the ingest Lambda to consume
  - quarantine/<key>  — failed one or more rules; preserved for audit and replay

Validation rules applied in order per line:
  1. JSON format check      — line must parse as a JSON object
  2. Schema validation      — required fields present with correct types
  3. Null disqualification  — required fields must not be null
  4. Field format conversion — title-case names, strip whitespace, coerce int strings
  5. Out-of-range rules     — eventYear 1800–1950; birthYear coherence; location non-empty
  + PII redaction           — SSN / email / phone removed from rawContent before validated/

CloudWatch metrics (via structured log lines, picked up by metric filters):
  ingress=N validated=N quarantined=N

Environment variables:
  VALIDATED_PREFIX   — destination prefix for clean records  (default: validated)
  QUARANTINE_PREFIX  — destination prefix for bad records    (default: quarantine)

Trigger:
  S3 ObjectCreated:* on landing/ prefix
"""

import json
import logging
import os
import re
import urllib.parse
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

VALIDATED_PREFIX  = os.environ.get("VALIDATED_PREFIX",  "validated")
QUARANTINE_PREFIX = os.environ.get("QUARANTINE_PREFIX", "quarantine")

# Required fields and their expected Python types
REQUIRED_FIELDS = {
    "recordId":   str,
    "givenName":  str,
    "familyName": str,
    "eventYear":  int,
    "location":   str,
}

EVENT_YEAR_MIN = 1800
EVENT_YEAR_MAX = 1950
AGE_MIN        = 1
AGE_MAX        = 110

# PII patterns — replaced with [REDACTED] in rawContent before writing to validated/
_PII_PATTERNS = [
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),                          # SSN
    re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"),  # email
    re.compile(r"\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}"),            # US phone
]


# ── Validation helpers ────────────────────────────────────────────────────────

def _redact_pii(text: str) -> str:
    for pattern in _PII_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text


def _convert_fields(record: dict) -> dict:
    """
    Apply field format conversions in-place (returns a new dict):
      - givenName / familyName → title-case
      - all string fields → strip leading/trailing whitespace
      - eventYear / birthYear → coerce numeric string to int
    """
    out = {}
    for k, v in record.items():
        if isinstance(v, str):
            v = v.strip()
            if k in ("givenName", "familyName"):
                v = v.title()
        if k in ("eventYear", "birthYear") and isinstance(v, str):
            try:
                v = int(v)
            except ValueError:
                pass  # leave as-is; schema check will catch it
        out[k] = v
    return out


def _validate_record(record: dict) -> list[str]:
    """
    Run rules 2–5 on a single already-parsed record.
    Returns a list of violation strings (empty = valid).
    """
    reasons = []

    # Rule 3 — null disqualification (before type check so error message is clear)
    for field in REQUIRED_FIELDS:
        if field in record and record[field] is None:
            reasons.append(f"null required field: {field}")

    if reasons:
        return reasons  # no point running further checks

    # Rule 2 — schema: required fields present and correct type
    for field, expected_type in REQUIRED_FIELDS.items():
        if field not in record:
            reasons.append(f"missing required field: {field}")
        elif not isinstance(record[field], expected_type):
            reasons.append(
                f"wrong type for {field}: expected {expected_type.__name__}, "
                f"got {type(record[field]).__name__}"
            )

    if reasons:
        return reasons

    # Rule 5 — out-of-range
    event_year = record["eventYear"]
    if not (EVENT_YEAR_MIN <= event_year <= EVENT_YEAR_MAX):
        reasons.append(
            f"eventYear {event_year} out of range [{EVENT_YEAR_MIN}–{EVENT_YEAR_MAX}]"
        )

    birth_year = record.get("birthYear")
    if birth_year is not None:
        if birth_year >= event_year:
            reasons.append(
                f"birthYear {birth_year} >= eventYear {event_year}"
            )
        elif not (AGE_MIN <= (event_year - birth_year) <= AGE_MAX):
            reasons.append(
                f"implied age {event_year - birth_year} outside [{AGE_MIN}–{AGE_MAX}]"
            )

    location = record.get("location", "")
    if not location.strip():
        reasons.append("location is empty after strip")

    return reasons


# ── Core processing ───────────────────────────────────────────────────────────

def _dest_key(prefix: str, original_key: str) -> str:
    """Replace the first path component (e.g. 'landing') with prefix."""
    parts = original_key.split("/", 1)
    rest  = parts[1] if len(parts) > 1 else parts[0]
    return f"{prefix}/{rest}"


def process_object(bucket: str, key: str) -> dict:
    """
    Download an NDJSON object from S3, validate each line, and route to
    validated/ or quarantine/ prefix.  Returns a summary dict.
    """
    logger.info("Validating s3://%s/%s", bucket, key)

    response = s3.get_object(Bucket=bucket, Key=key)
    body = response["Body"].read().decode("utf-8")

    # Pre-flight: empty file
    if not body.strip():
        q_key = _dest_key(QUARANTINE_PREFIX, key)
        s3.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": key},
            Key=q_key,
            Metadata={"quarantine-reason": "empty file"},
            MetadataDirective="REPLACE",
        )
        logger.warning("  QUARANTINE (whole file): empty — s3://%s/%s", bucket, q_key)
        return {"bucket": bucket, "key": key,
                "ingress": 0, "validated": 0, "quarantined": 0,
                "quarantined_file": True, "reason": "empty file"}

    lines = [l for l in body.splitlines() if l.strip()]

    # Pre-flight: JSON format check — count parseable lines
    json_ok = sum(1 for l in lines if _try_parse_json(l) is not None)
    if json_ok == 0:
        q_key = _dest_key(QUARANTINE_PREFIX, key)
        s3.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": key},
            Key=q_key,
            Metadata={"quarantine-reason": "no valid JSON lines"},
            MetadataDirective="REPLACE",
        )
        logger.warning("  QUARANTINE (whole file): no valid JSON — s3://%s/%s", bucket, q_key)
        return {"bucket": bucket, "key": key,
                "ingress": len(lines), "validated": 0, "quarantined": len(lines),
                "quarantined_file": True, "reason": "no valid JSON lines"}

    # Per-line processing
    # _batchId is generated once per invocation so that:
    #   - all output lines from this run share the same ID
    #   - a replay (Lambda re-invoked on the same S3 event) gets a different ID,
    #     making duplicate processing detectable in downstream systems
    batch_id = str(uuid.uuid4())

    validated_lines  = []
    quarantine_lines = []

    for i, line in enumerate(lines, 1):
        # Provenance fields added to every output line — both validated and quarantine.
        # This allows any record to be traced back to its exact source line even after
        # a mid-file Lambda crash and replay, and lets operators pair the two output
        # files without relying on recordId (which may be absent for parse failures).
        provenance = {
            "_sourceKey":  key,   # original landing/ S3 key
            "_sourceLine": i,     # 1-based line number in the source file
            "_batchId":    batch_id,
        }

        record = _try_parse_json(line)
        if record is None:
            quarantine_lines.append(
                json.dumps({"_reason": "invalid JSON", "_raw": line[:200], **provenance})
            )
            continue

        # Rule 4 — field format conversion (before validation so normalised values are checked)
        record = _convert_fields(record)

        # Rules 2, 3, 5
        reasons = _validate_record(record)
        if reasons:
            quarantine_lines.append(
                json.dumps({"_reasons": reasons, **provenance, **record})
            )
            continue

        # PII redaction on rawContent
        if "rawContent" in record and isinstance(record["rawContent"], str):
            record["rawContent"] = _redact_pii(record["rawContent"])

        validated_lines.append(json.dumps({**record, **provenance}))

    ingress    = len(lines)
    validated  = len(validated_lines)
    quarantined = len(quarantine_lines)

    # Write validated lines
    if validated_lines:
        v_key  = _dest_key(VALIDATED_PREFIX, key)
        v_body = "\n".join(validated_lines) + "\n"
        s3.put_object(Bucket=bucket, Key=v_key,
                      Body=v_body.encode("utf-8"),
                      ContentType="application/x-ndjson")

    # Write quarantine lines
    if quarantine_lines:
        q_key  = _dest_key(QUARANTINE_PREFIX, key)
        q_body = "\n".join(quarantine_lines) + "\n"
        s3.put_object(Bucket=bucket, Key=q_key,
                      Body=q_body.encode("utf-8"),
                      ContentType="application/x-ndjson")

    # Structured log line for CloudWatch metric filters
    logger.info(
        "  done: ingress=%d validated=%d quarantined=%d  key=%s",
        ingress, validated, quarantined, key,
    )

    return {
        "bucket":          bucket,
        "key":             key,
        "ingress":         ingress,
        "validated":       validated,
        "quarantined":     quarantined,
        "quarantined_file": False,
    }


def _try_parse_json(line: str):
    try:
        obj = json.loads(line)
        return obj if isinstance(obj, dict) else None
    except (json.JSONDecodeError, ValueError):
        return None


# ── Lambda entry point ────────────────────────────────────────────────────────

def handler(event, context):
    results = []
    for record in event.get("Records", []):
        if not record.get("eventName", "").startswith("ObjectCreated"):
            continue
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not (key.endswith(".ndjson") or key.endswith(".json") or key.endswith(".jsonl")):
            logger.info("Skipping non-NDJSON file: %s", key)
            continue
        results.append(process_object(bucket, key))

    return {
        "statusCode": 200,
        "body": json.dumps({"processed": len(results), "results": results}),
    }


if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if len(sys.argv) != 3:
        print("Usage: python3 validate-and-route.py <bucket> <key>")
        sys.exit(1)
    fake_event = {"Records": [{"eventName": "ObjectCreated:Put",
                                "s3": {"bucket": {"name": sys.argv[1]},
                                       "object": {"key": sys.argv[2]}}}]}
    print(json.dumps(handler(fake_event, None), indent=2))
