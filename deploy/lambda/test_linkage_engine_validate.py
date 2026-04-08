"""
deploy/lambda/test_linkage_engine_validate.py

Sprint 3 — Validation Pipeline
Tests that simulate, detect, and verify fixes for every validation rule:
  1. JSON format check
  2. JSON schema validation
  3. Null disqualification
  4. Field format conversion
  5. Out-of-range rules
  + PII redaction
  + CloudWatch metric emission

Sprint 3b — Output Provenance
  Every output line (validated or quarantine) must carry three provenance fields
  so that any record can be traced back to its exact source line, even after a
  mid-file Lambda crash and replay:
    _sourceKey  — original S3 key in landing/  e.g. "landing/batch.ndjson"
    _sourceLine — 1-based line number in the source file
    _batchId    — UUID generated once per Lambda invocation (detects replays)

Sprint 3c — Quarantine Manifest
  When any lines are quarantined, a companion .manifest file is written to
  quarantine/<key>.manifest containing the lifecycle record for that file:
    quarantineKey, sourceKey, batchId, quarantinedAt, lineCount, reasons,
    replayStatus ("pending" until the ingest Lambda updates it)

Run:
    pytest deploy/lambda/test_linkage_engine_validate.py -v
"""

import importlib.util
import io
import json
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

LAMBDA_PATH = Path(__file__).parent / "linkage-engine-validate.py"

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
        spec = importlib.util.spec_from_file_location("linkage_engine_validate", LAMBDA_PATH)
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


# ══════════════════════════════════════════════════════════════════════════════
# Sprint 3b — Output Provenance
# Every output line must carry _sourceKey, _sourceLine, _batchId so that
# validated and quarantine records can always be paired back to their origin,
# and replayed invocations can be detected.
# ══════════════════════════════════════════════════════════════════════════════

class TestOutputProvenance:

    def test_validated_line_carries_provenance_fields(self):
        """
        SIMULATE: a clean record is written to validated/.
        DETECT:   the written JSON line must contain _sourceKey, _sourceLine,
                  and _batchId.
        MITIGATE: inject provenance fields into every output line before writing.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson(GOOD_RECORD))

        mod.process_object(BUCKET, LANDING_KEY)

        put_calls = fake_s3.put_object.call_args_list
        assert put_calls, "Expected put_object call for validated line"

        written_body = put_calls[0].kwargs.get("Body", b"")
        if isinstance(written_body, bytes):
            written_body = written_body.decode("utf-8")
        written = json.loads(written_body.strip().splitlines()[0])

        assert "_sourceKey"  in written, (
            "validated line missing _sourceKey\n"
            "Fix: add '_sourceKey': key to every output line"
        )
        assert "_sourceLine" in written, (
            "validated line missing _sourceLine\n"
            "Fix: add '_sourceLine': i (1-based) to every output line"
        )
        assert "_batchId"    in written, (
            "validated line missing _batchId\n"
            "Fix: generate uuid.uuid4() once per process_object call and embed in every line"
        )
        assert written["_sourceKey"]  == LANDING_KEY, \
            f"_sourceKey mismatch: {written['_sourceKey']}"
        assert written["_sourceLine"] == 1, \
            f"_sourceLine should be 1 for first line, got {written['_sourceLine']}"

    def test_quarantine_line_carries_provenance_fields(self):
        """
        SIMULATE: a bad record is written to quarantine/.
        DETECT:   the quarantine JSON line must also contain _sourceKey,
                  _sourceLine, and _batchId — same fields as validated.
        MITIGATE: provenance injection is applied to both output streams.
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        good = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00002")
        # line 1 = bad (quarantine), line 2 = good (validated)
        fake_s3.get_object.return_value = _s3_body(_ndjson(bad, good))

        mod.process_object(BUCKET, LANDING_KEY)

        # quarantine is the second put_object call (validated written first)
        put_calls = fake_s3.put_object.call_args_list
        assert len(put_calls) >= 2, (
            f"Expected 2 put_object calls (validated + quarantine), got {len(put_calls)}"
        )

        # find the quarantine call
        q_call = next(
            (c for c in put_calls if "quarantine/" in str(c.kwargs.get("Key", ""))),
            None
        )
        assert q_call is not None, "No put_object call targeting quarantine/ prefix"

        written_body = q_call.kwargs.get("Body", b"")
        if isinstance(written_body, bytes):
            written_body = written_body.decode("utf-8")
        written = json.loads(written_body.strip().splitlines()[0])

        assert "_sourceKey"  in written, "quarantine line missing _sourceKey"
        assert "_sourceLine" in written, "quarantine line missing _sourceLine"
        assert "_batchId"    in written, "quarantine line missing _batchId"
        assert written["_sourceKey"]  == LANDING_KEY
        assert written["_sourceLine"] == 1, \
            f"bad record was line 1, got _sourceLine={written['_sourceLine']}"

    def test_batch_id_is_consistent_within_invocation(self):
        """
        SIMULATE: a file with 2 good records and 1 bad record is processed.
        DETECT:   all three output lines (2 validated + 1 quarantine) share the
                  same _batchId — it is generated once per invocation, not per line.
        MITIGATE: generate uuid once at the top of process_object and pass it through.
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        good1 = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00001")
        good2 = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00002")
        fake_s3.get_object.return_value = _s3_body(_ndjson(good1, bad, good2))

        mod.process_object(BUCKET, LANDING_KEY)

        # Filter out the manifest write — only inspect data files
        put_calls = [
            c for c in fake_s3.put_object.call_args_list
            if not str(c.kwargs.get("Key", "")).endswith(".manifest")
        ]
        assert len(put_calls) == 2, \
            f"Expected 2 data put_object calls (validated + quarantine), got {len(put_calls)}"

        batch_ids = set()
        for c in put_calls:
            body = c.kwargs.get("Body", b"")
            if isinstance(body, bytes):
                body = body.decode("utf-8")
            for line in body.strip().splitlines():
                rec = json.loads(line)
                assert "_batchId" in rec, f"Output line missing _batchId: {rec}"
                batch_ids.add(rec["_batchId"])

        assert len(batch_ids) == 1, (
            f"Expected all output lines to share one _batchId, got {batch_ids}\n"
            "Fix: generate uuid.uuid4() once per process_object call, not per line"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Sprint 3c — Quarantine Manifest
# ══════════════════════════════════════════════════════════════════════════════

def _get_manifest_put_call(fake_s3):
    """Return the put_object call that wrote the .manifest file, or None."""
    return next(
        (c for c in fake_s3.put_object.call_args_list
         if str(c.kwargs.get("Key", "")).endswith(".manifest")),
        None,
    )


def _parse_manifest(call):
    """Parse the JSON body from a put_object call."""
    body = call.kwargs.get("Body", b"")
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    return json.loads(body)


class TestQuarantineManifestCreation:

    def test_manifest_written_alongside_quarantine_file(self):
        """
        SIMULATE: a file with one bad record is processed — one line goes to quarantine.
        DETECT:   no .manifest file is written next to the quarantine file.
        MITIGATE: after writing quarantine lines, write <quarantine-key>.manifest.
        VERIFY:   put_object is called with a Key ending in '.manifest' under quarantine/.
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        fake_s3.get_object.return_value = _s3_body(_ndjson(bad))

        mod.process_object(BUCKET, LANDING_KEY)

        manifest_call = _get_manifest_put_call(fake_s3)
        assert manifest_call is not None, (
            "No put_object call with a .manifest key was found.\n"
            "Fix: after writing quarantine lines, call s3.put_object with "
            "Key=f'{quarantine_key}.manifest' and the manifest JSON as Body."
        )
        manifest_key = manifest_call.kwargs.get("Key", "")
        assert manifest_key.startswith("quarantine/"), (
            f"Manifest key should be under quarantine/, got: {manifest_key}"
        )
        assert manifest_key.endswith(".manifest"), (
            f"Manifest key should end with .manifest, got: {manifest_key}"
        )

    def test_manifest_contains_required_fields(self):
        """
        SIMULATE: a file with one bad record is quarantined.
        DETECT:   the .manifest JSON is missing required lifecycle fields.
        MITIGATE: write a manifest with quarantineKey, sourceKey, batchId,
                  quarantinedAt, lineCount, reasons, replayStatus.
        VERIFY:   all required fields are present and replayStatus is "pending".
        """
        mod, fake_s3 = load_lambda()
        bad = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        fake_s3.get_object.return_value = _s3_body(_ndjson(bad))

        mod.process_object(BUCKET, LANDING_KEY)

        manifest_call = _get_manifest_put_call(fake_s3)
        assert manifest_call is not None, (
            "No .manifest written — implement manifest creation first."
        )
        manifest = _parse_manifest(manifest_call)

        required = ["quarantineKey", "sourceKey", "batchId",
                    "quarantinedAt", "lineCount", "reasons", "replayStatus"]
        missing = [f for f in required if f not in manifest]
        assert not missing, (
            f"Manifest is missing required fields: {missing}\n"
            f"Actual manifest: {json.dumps(manifest, indent=2)}"
        )
        assert manifest["replayStatus"] == "pending", (
            f"Expected replayStatus='pending' on initial write, "
            f"got '{manifest['replayStatus']}'"
        )
        assert manifest["sourceKey"] == LANDING_KEY, (
            f"sourceKey should be '{LANDING_KEY}', got '{manifest['sourceKey']}'"
        )
        assert manifest["quarantineKey"].startswith("quarantine/"), (
            f"quarantineKey should start with 'quarantine/', "
            f"got '{manifest['quarantineKey']}'"
        )

    def test_manifest_line_count_matches_quarantine_output(self):
        """
        SIMULATE: a file with 2 bad records and 1 good record is processed.
        DETECT:   manifest lineCount does not match the number of quarantined lines.
        MITIGATE: count quarantined lines and write that count to the manifest.
        VERIFY:   manifest lineCount == 2 (the number of quarantined lines).
        """
        mod, fake_s3 = load_lambda()
        bad1 = {k: v for k, v in GOOD_RECORD.items() if k != "familyName"}
        bad2 = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00002", eventYear=2099)
        good = dict(GOOD_RECORD, recordId="SYN-20260406-s0-00003")
        fake_s3.get_object.return_value = _s3_body(_ndjson(bad1, bad2, good))

        mod.process_object(BUCKET, LANDING_KEY)

        manifest_call = _get_manifest_put_call(fake_s3)
        assert manifest_call is not None, (
            "No .manifest written — implement manifest creation first."
        )
        manifest = _parse_manifest(manifest_call)

        assert manifest.get("lineCount") == 2, (
            f"Expected lineCount=2 (two quarantined lines), "
            f"got lineCount={manifest.get('lineCount')}\n"
            "Fix: set lineCount to the number of lines written to the quarantine file."
        )
