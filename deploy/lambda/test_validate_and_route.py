"""
deploy/lambda/test_validate_and_route.py

Sprint 3 — Validation Pipeline
Tests that simulate, detect, and verify fixes for every validation rule:
  1. JSON format check
  2. JSON schema validation
  3. Null disqualification
  4. Field format conversion
  5. Out-of-range rules
  + PII redaction
  + CloudWatch metric emission

Run:
    pytest deploy/lambda/test_validate_and_route.py -v
"""

import importlib.util
import io
import json
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

LAMBDA_PATH = Path(__file__).parent / "validate-and-route.py"

BUCKET = "test-bucket"
LANDING_KEY = "landing/batch.ndjson"
VALIDATED_KEY = "validated/batch.ndjson"
QUARANTINE_KEY = "quarantine/batch.ndjson"


# ── Bootstrap helpers ─────────────────────────────────────────────────────────

def _make_fake_boto3():
    fake_boto3 = types.ModuleType("boto3")
    fake_s3 = MagicMock()
    fake_boto3.client = MagicMock(return_value=fake_s3)
    return fake_boto3, fake_s3


def load_lambda(fake_boto3=None, fake_s3=None):
    if fake_boto3 is None:
        fake_boto3, fake_s3 = _make_fake_boto3()
    with patch.dict("sys.modules", {"boto3": fake_boto3}):
        spec = importlib.util.spec_from_file_location("validate_lambda", LAMBDA_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    mod.s3 = fake_s3
    return mod, fake_s3


def _s3_body(content: str):
    return {"Body": io.BytesIO(content.encode("utf-8")),
            "ContentLength": len(content.encode("utf-8"))}


def _s3_event(bucket=BUCKET, key=LANDING_KEY):
    return {"Records": [{"eventName": "ObjectCreated:Put",
                         "s3": {"bucket": {"name": bucket},
                                "object": {"key": key}}}]}


GOOD_RECORD = {
    "recordId":   "SYN-20260406-s0-00001",
    "givenName":  "William",
    "familyName": "Harper",
    "eventYear":  1850,
    "location":   "Boston",
    "source":     "1850 US Federal Census",
    "rawContent": "William Harper, age 30, farmer",
}


def _ndjson(*records):
    return "\n".join(json.dumps(r) for r in records) + "\n"


# ══════════════════════════════════════════════════════════════════════════════
# Rule 1 — JSON format check
# ══════════════════════════════════════════════════════════════════════════════

class TestJsonFormatCheck:

    def test_non_json_file_quarantined(self):
        """
        SIMULATE: external party drops a CSV or binary file in landing/.
        DETECT:   file must be copied to quarantine/, never to validated/.
        MITIGATE: pre-flight check counts valid JSON lines; if 0, quarantine whole file.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(
            "name,year\nWilliam Harper,1850\nJames Smith,1860\n"
        )

        result = mod.process_object(BUCKET, LANDING_KEY)

        validated_calls = [
            c for c in fake_s3.copy_object.call_args_list
            if "validated/" in str(c)
        ]
        quarantine_calls = [
            c for c in fake_s3.copy_object.call_args_list
            if "quarantine/" in str(c)
        ]

        assert len(validated_calls) == 0, (
            "Non-JSON file must never reach validated/\n"
            "Fix: pre-flight check — if 0 valid JSON lines, copy whole file to quarantine/"
        )
        assert len(quarantine_calls) >= 1, (
            "Non-JSON file must be copied to quarantine/\n"
            "Fix: copy_object to quarantine/<key> when file has no valid JSON lines"
        )

    def test_empty_file_quarantined(self):
        """
        SIMULATE: zero-byte file uploaded (truncated transfer).
        DETECT:   file copied to quarantine/ with reason; validated/ untouched.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body("")

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["quarantined_file"] is True, (
            "Empty file must set quarantined_file=True in result\n"
            "Fix: check ContentLength==0 or empty body in pre-flight"
        )
        validated_calls = [
            c for c in fake_s3.copy_object.call_args_list
            if "validated/" in str(c)
        ]
        assert len(validated_calls) == 0, "Empty file must never reach validated/"


# ══════════════════════════════════════════════════════════════════════════════
# Happy path
# ══════════════════════════════════════════════════════════════════════════════

class TestHappyPath:

    def test_valid_file_routed_to_validated(self):
        """
        SIMULATE: clean NDJSON file with 3 good records.
        DETECT:   all 3 lines written to validated/, none to quarantine/.
        """
        mod, fake_s3 = load_lambda()
        records = [dict(GOOD_RECORD, recordId=f"SYN-20260406-s0-{i:05d}") for i in range(1, 4)]
        fake_s3.get_object.return_value = _s3_body(_ndjson(*records))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["validated"] == 3, (
            f"Expected validated=3, got {result['validated']}\n"
            "Fix: route all passing lines to validated/"
        )
        assert result["quarantined"] == 0, (
            f"Expected quarantined=0, got {result['quarantined']}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Rule 2 — JSON schema validation
# ══════════════════════════════════════════════════════════════════════════════

class TestSchemaValidation:

    def test_schema_violation_quarantines_line(self):
        """
        SIMULATE: one record missing familyName in a 3-record file.
        DETECT:   2 lines → validated/, 1 line → quarantine/.
        MITIGATE: per-line schema check; route bad line to quarantine, continue.
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        good1 = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00001")
        good2 = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00002")
        fake_s3.get_object.return_value = _s3_body(_ndjson(good1, bad, good2))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["validated"] == 2,   f"Expected validated=2, got {result['validated']}"
        assert result["quarantined"] == 1, f"Expected quarantined=1, got {result['quarantined']}"


# ══════════════════════════════════════════════════════════════════════════════
# Rule 3 — Null disqualification
# ══════════════════════════════════════════════════════════════════════════════

class TestNullDisqualification:

    def test_null_required_field_quarantines_line(self):
        """
        SIMULATE: record with recordId=null.
        DETECT:   that line quarantined; others validated.
        """
        mod, fake_s3 = load_lambda()
        null_id = dict(GOOD_RECORD, recordId=None)
        good = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00002")
        fake_s3.get_object.return_value = _s3_body(_ndjson(null_id, good))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["quarantined"] == 1, (
            f"Expected quarantined=1 for null recordId, got {result['quarantined']}\n"
            "Fix: null check on required fields before schema validation"
        )
        assert result["validated"] == 1, f"Expected validated=1, got {result['validated']}"


# ══════════════════════════════════════════════════════════════════════════════
# Rule 4 — Field format conversion
# ══════════════════════════════════════════════════════════════════════════════

class TestFieldFormatConversion:

    def test_field_format_conversion_applied(self):
        """
        SIMULATE: givenName in lowercase, location with surrounding whitespace,
                  eventYear as a numeric string.
        DETECT:   validated copy has title-cased name, stripped location, int eventYear.
        MITIGATE: normalise fields before writing to validated/.
        """
        mod, fake_s3 = load_lambda()
        messy = dict(GOOD_RECORD,
                     recordId="SYN-20260406-s0-00001",
                     givenName="william",
                     familyName="harper",
                     location="  Boston  ",
                     eventYear="1850")   # string instead of int
        fake_s3.get_object.return_value = _s3_body(_ndjson(messy))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["validated"] == 1, (
            f"Expected validated=1 after conversion, got {result['validated']}\n"
            "Fix: apply format conversion before schema/range checks"
        )

        # Inspect what was actually written to validated/
        put_calls = fake_s3.put_object.call_args_list
        assert put_calls, "Expected put_object call for validated lines"

        written_body = put_calls[0].kwargs.get("Body", b"")
        if isinstance(written_body, bytes):
            written_body = written_body.decode("utf-8")
        written_record = json.loads(written_body.strip().splitlines()[0])

        assert written_record["givenName"]  == "William", \
            f"givenName not title-cased: {written_record['givenName']}"
        assert written_record["familyName"] == "Harper", \
            f"familyName not title-cased: {written_record['familyName']}"
        assert written_record["location"]   == "Boston", \
            f"location not stripped: {repr(written_record['location'])}"
        assert written_record["eventYear"]  == 1850, \
            f"eventYear not coerced to int: {written_record['eventYear']}"


# ══════════════════════════════════════════════════════════════════════════════
# Rule 5 — Out-of-range rules
# ══════════════════════════════════════════════════════════════════════════════

class TestOutOfRangeRules:

    def test_out_of_range_event_year_quarantined(self):
        """
        SIMULATE: eventYear=2099 (future date — impossible for 19th-century records).
        DETECT:   line quarantined.
        """
        mod, fake_s3 = load_lambda()
        future = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00001", eventYear=2099)
        fake_s3.get_object.return_value = _s3_body(_ndjson(future))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["quarantined"] == 1, (
            f"Expected quarantined=1 for eventYear=2099, got {result['quarantined']}\n"
            "Fix: reject eventYear outside 1800–1950"
        )

    def test_birth_year_incoherence_quarantined(self):
        """
        SIMULATE: birthYear >= eventYear (person not yet born at event time).
        DETECT:   line quarantined.
        """
        mod, fake_s3 = load_lambda()
        incoherent = dict(GOOD_RECORD,
                          recordId="SYN-20260406-s0-00001",
                          eventYear=1850,
                          birthYear=1860)   # born after the event
        fake_s3.get_object.return_value = _s3_body(_ndjson(incoherent))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["quarantined"] == 1, (
            f"Expected quarantined=1 for birthYear>=eventYear, got {result['quarantined']}\n"
            "Fix: reject records where birthYear >= eventYear"
        )


# ══════════════════════════════════════════════════════════════════════════════
# PII redaction
# ══════════════════════════════════════════════════════════════════════════════

class TestPiiRedaction:

    def test_pii_redacted_before_validated(self):
        """
        SIMULATE: rawContent contains SSN, email address, and US phone number.
        DETECT:   validated copy has PII replaced with [REDACTED]; record still validated.
        MITIGATE: apply PII regex redaction to rawContent before writing to validated/.
        """
        mod, fake_s3 = load_lambda()
        pii_record = dict(GOOD_RECORD,
                          recordId="SYN-20260406-s0-00001",
                          rawContent=(
                              "William Harper, SSN 123-45-6789, "
                              "email william@example.com, "
                              "phone (555) 867-5309"
                          ))
        fake_s3.get_object.return_value = _s3_body(_ndjson(pii_record))

        result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["validated"] == 1, (
            f"PII record should still be validated (after redaction), got validated={result['validated']}\n"
            "Fix: redact PII then route to validated/, don't quarantine for PII alone"
        )

        put_calls = fake_s3.put_object.call_args_list
        assert put_calls, "Expected put_object call for validated line"

        written_body = put_calls[0].kwargs.get("Body", b"")
        if isinstance(written_body, bytes):
            written_body = written_body.decode("utf-8")
        written_record = json.loads(written_body.strip().splitlines()[0])

        raw = written_record.get("rawContent", "")
        assert "123-45-6789"        not in raw, "SSN not redacted"
        assert "william@example.com" not in raw, "email not redacted"
        assert "867-5309"           not in raw, "phone not redacted"
        assert "[REDACTED]"         in raw,     "expected [REDACTED] placeholder in rawContent"


# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch metric emission
# ══════════════════════════════════════════════════════════════════════════════

class TestCloudWatchMetrics:

    def test_cloudwatch_metrics_emitted(self):
        """
        SIMULATE: normal invocation with 3 good and 1 bad record.
        DETECT:   result dict contains ingress, validated, quarantined counts;
                  log output contains structured metric line for CloudWatch filter.
        MITIGATE: emit `ingress=N validated=N quarantined=N` in every invocation log.
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        records = [dict(GOOD_RECORD, recordId=f"SYN-20260406-s0-{i:05d}") for i in range(1, 4)]
        fake_s3.get_object.return_value = _s3_body(_ndjson(*records, bad))

        import logging
        with patch.object(mod.logger, "info") as mock_log:
            result = mod.process_object(BUCKET, LANDING_KEY)

        assert result["ingress"]    == 4, f"Expected ingress=4, got {result['ingress']}"
        assert result["validated"]  == 3, f"Expected validated=3, got {result['validated']}"
        assert result["quarantined"]== 1, f"Expected quarantined=1, got {result['quarantined']}"

        # At least one log call must contain the structured metric line
        log_messages = " ".join(str(c) for c in mock_log.call_args_list)
        assert "ingress=" in log_messages, (
            "Expected structured log line containing 'ingress=' for CloudWatch metric filter\n"
            "Fix: logger.info('... ingress=%d validated=%d quarantined=%d', ...)"
        )
        assert "quarantined=" in log_messages, (
            "Expected 'quarantined=' in log output for CloudWatch metric filter"
        )
