"""
deploy/lambda/test_ingest_from_s3.py

Sprint 2 — Lambda Idempotency and Retry
Sprint 3 — Provenance field stripping on quarantine replay
Sprint 3c — Quarantine manifest updated after replay

Tests that simulate, detect, and verify fixes for:
  - Double S3 invocation producing duplicate DB writes
  - Aurora cold-start 503 not triggering retry
  - 503 exhaustion not routing failed record to DLQ
  - DLQ message missing context (bucket/key/line/recordId)
  - Provenance fields (_sourceKey, _sourceLine, _batchId, _reasons) in a
    quarantine file causing HTTP 400 when replayed through the ingest Lambda
  - Quarantine .manifest not updated after replay (replayStatus stays "pending")

Run:
    pytest deploy/lambda/test_ingest_from_s3.py -v
"""

import importlib.util
import io
import json
import sys
import types
import unittest.mock as mock
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

# ── Bootstrap: stub boto3 before importing the Lambda module ──────────────────

def _make_fake_boto3():
    """Return a minimal boto3 stub so the module-level boto3.client() succeeds."""
    fake_boto3 = types.ModuleType("boto3")
    fake_s3 = MagicMock()
    fake_sqs = MagicMock()
    fake_boto3.client = MagicMock(side_effect=lambda svc, **kw: fake_s3 if svc == "s3" else fake_sqs)
    return fake_boto3, fake_s3, fake_sqs


LAMBDA_PATH = Path(__file__).parent / "ingest-from-s3.py"


def load_lambda(api_url="http://test-alb", dry_run="false",
                fake_boto3=None, fake_s3=None, fake_sqs=None):
    """
    Import ingest-from-s3.py in isolation with controlled env vars and boto3 stub.
    Returns (module, fake_s3_client, fake_sqs_client).
    """
    if fake_boto3 is None:
        fake_boto3, fake_s3, fake_sqs = _make_fake_boto3()

    env_patch = {
        "LINKAGE_API_URL": api_url,
        "DRY_RUN": dry_run,
        "BATCH_SIZE": "50",
    }

    # Each load gets a fresh module object so state doesn't bleed between tests
    with patch.dict("os.environ", env_patch, clear=False), \
         patch.dict("sys.modules", {"boto3": fake_boto3}):
        spec = importlib.util.spec_from_file_location("ingest_lambda", LAMBDA_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

    return mod, fake_s3, fake_sqs


def _s3_event(bucket="test-bucket", key="landing/test.ndjson"):
    return {
        "Records": [{
            "eventName": "ObjectCreated:Put",
            "s3": {
                "bucket": {"name": bucket},
                "object": {"key": key},
            },
        }]
    }


def _ndjson_body(*records):
    """Encode a list of dicts as an NDJSON S3 body response."""
    body = "\n".join(json.dumps(r) for r in records) + "\n"
    return {"Body": io.BytesIO(body.encode("utf-8"))}


SAMPLE_RECORD = {
    "recordId": "SYN-20260406-s0-00001",
    "givenName": "William",
    "familyName": "Harper",
    "eventYear": 1850,
    "location": "Boston",
    "source": "1850 US Federal Census",
    "rawContent": "William Harper, age 30, farmer, born Massachusetts, residing Boston",
}


# ══════════════════════════════════════════════════════════════════════════════
# Threat: 409 must be treated as success (idempotency)
# ══════════════════════════════════════════════════════════════════════════════

class TestIdempotency:

    def test_409_treated_as_success(self):
        """
        SIMULATE: API returns 409 Conflict (record already exists).
        DETECT:   `ok` counter must increment, not `failed`.
        MITIGATE: existing code already handles 409 — this is a regression guard.
        """
        mod, fake_s3, _ = load_lambda()
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)

        with patch.object(mod, "post_record", return_value=(409, "conflict")) as mock_post:
            result = mod.process_object("test-bucket", "landing/test.ndjson")

        assert result["ok"] == 1,     f"expected ok=1, got ok={result['ok']}"
        assert result["failed"] == 0, f"expected failed=0, got failed={result['failed']}"

    def test_double_invocation_idempotent(self):
        """
        SIMULATE: S3 delivers the same ObjectCreated event twice (at-least-once delivery).
        DETECT:   second invocation must produce the same ok/failed counts as the first.
        MITIGATE: 409 on second call is treated as success — net result is identical.
        """
        mod, fake_s3, _ = load_lambda()

        # First call: 204 Created
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)
        with patch.object(mod, "post_record", return_value=(204, "")):
            result1 = mod.process_object("test-bucket", "landing/test.ndjson")

        # Second call (same event): 409 Conflict
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)
        with patch.object(mod, "post_record", return_value=(409, "conflict")):
            result2 = mod.process_object("test-bucket", "landing/test.ndjson")

        assert result1["ok"] == result2["ok"], (
            f"Double invocation produced different ok counts: "
            f"first={result1['ok']} second={result2['ok']}"
        )
        assert result1["failed"] == result2["failed"] == 0, (
            "Double invocation should never produce failures"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: Aurora cold-start 503 — must retry with exponential backoff
# ══════════════════════════════════════════════════════════════════════════════

class TestRetryBehavior:

    def test_503_triggers_retry_and_succeeds(self):
        """
        SIMULATE: Aurora is cold-starting; first POST returns 503, second returns 204.
        DETECT:   `ok` must be 1, `failed` must be 0 — the retry succeeded.
        MITIGATE: add retry loop with exponential backoff to post_record_with_retry().
        """
        mod, fake_s3, _ = load_lambda()
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)

        call_count = {"n": 0}

        def flaky_post(record):
            call_count["n"] += 1
            if call_count["n"] == 1:
                return (503, "Service Unavailable")
            return (204, "")

        with patch.object(mod, "post_record", side_effect=flaky_post), \
             patch("time.sleep"):   # skip real sleep in tests
            result = mod.process_object("test-bucket", "landing/test.ndjson")

        assert result["ok"] == 1, (
            f"Expected ok=1 after retry, got ok={result['ok']} failed={result['failed']}.\n"
            "Fix: wrap post_record in a retry loop that retries on 503."
        )
        assert result["failed"] == 0, (
            f"Expected failed=0 after retry, got failed={result['failed']}.\n"
            "Fix: only increment failed after all retries are exhausted."
        )
        assert call_count["n"] >= 2, (
            f"post_record was only called {call_count['n']} time(s) — no retry occurred.\n"
            "Fix: implement retry logic for 5xx responses."
        )

    def test_503_exhausted_sends_to_dlq(self):
        """
        SIMULATE: Aurora stays down; every POST returns 503 (all retries exhausted).
        DETECT:   after max retries, the record must be sent to the SQS DLQ.
        MITIGATE: after retry exhaustion, call sqs.send_message() with failure context.
        """
        mod, fake_s3, fake_sqs = load_lambda()
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)

        # Patch the module-level sqs client that the Lambda uses
        mod.sqs = fake_sqs
        mod.DLQ_URL = "https://sqs.us-west-1.amazonaws.com/123456789/linkage-engine-dlq"

        with patch.object(mod, "post_record", return_value=(503, "Service Unavailable")), \
             patch("time.sleep"):
            result = mod.process_object("test-bucket", "landing/test.ndjson")

        assert fake_sqs.send_message.called, (
            "Expected sqs.send_message() to be called after retry exhaustion, but it was not.\n"
            "Fix: call sqs.send_message(QueueUrl=DLQ_URL, MessageBody=...) when all retries fail."
        )
        assert result["failed"] == 1, (
            f"Expected failed=1 after DLQ send, got failed={result['failed']}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: DLQ message missing context for debugging
# ══════════════════════════════════════════════════════════════════════════════

class TestDlqMessageContent:

    def test_dlq_message_contains_context(self):
        """
        SIMULATE: a record fails all retries and is sent to the DLQ.
        DETECT:   the DLQ MessageBody must contain bucket, key, line number,
                  and recordId so an operator can replay or investigate.
        MITIGATE: build a structured DLQ payload in the retry-exhaustion path.
        """
        mod, fake_s3, fake_sqs = load_lambda()
        fake_s3.get_object.return_value = _ndjson_body(SAMPLE_RECORD)

        mod.sqs = fake_sqs
        mod.DLQ_URL = "https://sqs.us-west-1.amazonaws.com/123456789/linkage-engine-dlq"

        with patch.object(mod, "post_record", return_value=(503, "Service Unavailable")), \
             patch("time.sleep"):
            mod.process_object("test-bucket", "landing/test.ndjson")

        assert fake_sqs.send_message.called, (
            "sqs.send_message was never called — DLQ send not implemented."
        )

        call_kwargs = fake_sqs.send_message.call_args
        # send_message may be called positionally or as keyword args
        if call_kwargs.kwargs:
            msg_body_raw = call_kwargs.kwargs.get("MessageBody", "")
        else:
            # positional: send_message(QueueUrl=..., MessageBody=...)
            msg_body_raw = call_kwargs[1].get("MessageBody", "") if len(call_kwargs) > 1 else ""

        assert msg_body_raw, "DLQ MessageBody is empty"

        try:
            msg_body = json.loads(msg_body_raw)
        except json.JSONDecodeError:
            pytest.fail(f"DLQ MessageBody is not valid JSON: {msg_body_raw!r}")

        missing = []
        if "bucket" not in msg_body:
            missing.append("bucket")
        if "key" not in msg_body:
            missing.append("key")
        if "line" not in msg_body:
            missing.append("line")
        if "recordId" not in msg_body:
            missing.append("recordId")

        assert not missing, (
            f"DLQ message is missing required fields: {missing}\n"
            f"Actual payload: {json.dumps(msg_body, indent=2)}\n"
            "Fix: include bucket, key, line, and recordId in the DLQ MessageBody."
        )

        assert msg_body["bucket"] == "test-bucket",    f"bucket mismatch: {msg_body['bucket']}"
        assert msg_body["key"]    == "landing/test.ndjson", f"key mismatch: {msg_body['key']}"
        assert msg_body["recordId"] == SAMPLE_RECORD["recordId"], \
            f"recordId mismatch: {msg_body['recordId']}"


# ══════════════════════════════════════════════════════════════════════════════
# Threat: provenance fields in quarantine files cause HTTP 400 on replay
# ══════════════════════════════════════════════════════════════════════════════

class TestProvenanceFieldStripping:

    def test_quarantine_replay_strips_provenance_fields(self):
        """
        SIMULATE: a quarantine file (written by validate-and-route.py) is fed
                  to the ingest Lambda for replay.  Every line contains the
                  validator's provenance fields: _sourceKey, _sourceLine,
                  _batchId, _reasons.
        DETECT:   if the Lambda POSTs those fields verbatim, the strict Java
                  RecordIngestRequest DTO rejects them with HTTP 400 and the
                  record is never inserted.
        MITIGATE: strip all underscore-prefixed keys from each record dict
                  before calling post_record().
        VERIFY:   the body passed to post_record() contains none of the
                  provenance keys.
        """
        quarantine_record = {
            **SAMPLE_RECORD,
            "_sourceKey":  "landing/batch-20260406.ndjson",
            "_sourceLine": 7,
            "_batchId":    "a3f7c2d1-4b8e-4f2a-9c1d-0e5f6a7b8c9d",
            "_reasons":    ["eventYear out of range"],
        }

        mod, fake_s3, _ = load_lambda()
        fake_s3.get_object.return_value = _ndjson_body(quarantine_record)

        posted_bodies = []

        def capture_post(record):
            posted_bodies.append(dict(record))
            return (204, "")

        with patch.object(mod, "post_record", side_effect=capture_post):
            result = mod.process_object("test-bucket", "quarantine/batch-20260406.ndjson")

        assert result["ok"] == 1, (
            f"Expected ok=1, got ok={result['ok']} failed={result['failed']}.\n"
            "Fix: strip provenance fields before calling post_record()."
        )
        assert len(posted_bodies) == 1, "Expected exactly one POST"

        provenance_keys = {k for k in posted_bodies[0] if k.startswith("_")}
        assert not provenance_keys, (
            f"POST body still contains provenance fields: {provenance_keys}\n"
            "Fix: filter out all underscore-prefixed keys before POSTing.\n"
            f"Full body sent: {json.dumps(posted_bodies[0], indent=2)}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Sprint 3c — Quarantine manifest updated after replay
# ══════════════════════════════════════════════════════════════════════════════

QUARANTINE_KEY = "quarantine/batch-20260406.ndjson"
MANIFEST_KEY   = f"{QUARANTINE_KEY}.manifest"

INITIAL_MANIFEST = {
    "quarantineKey": QUARANTINE_KEY,
    "sourceKey":     "landing/batch-20260406.ndjson",
    "batchId":       "a3f7c2d1-4b8e-4f2a-9c1d-0e5f6a7b8c9d",
    "quarantinedAt": "2026-04-06T14:23:00Z",
    "lineCount":     1,
    "reasons":       ["eventYear out of range"],
    "replayStatus":  "pending",
}

QUARANTINE_RECORD = {
    **SAMPLE_RECORD,
    "_sourceKey":  "landing/batch-20260406.ndjson",
    "_sourceLine": 7,
    "_batchId":    "a3f7c2d1-4b8e-4f2a-9c1d-0e5f6a7b8c9d",
    "_reasons":    ["eventYear out of range"],
}


def _manifest_s3_body(manifest: dict):
    """Return a fake S3 get_object response containing the manifest JSON."""
    import io as _io
    body = json.dumps(manifest).encode("utf-8")
    return {"Body": _io.BytesIO(body)}


class TestQuarantineManifestReplay:

    def _setup_s3(self, fake_s3, manifest=None):
        """Configure fake_s3 to serve the quarantine file and optionally a manifest."""
        ndjson_response = _ndjson_body(QUARANTINE_RECORD)
        if manifest is None:
            manifest = INITIAL_MANIFEST

        def get_object_side_effect(Bucket, Key):
            if Key == MANIFEST_KEY:
                return _manifest_s3_body(manifest)
            return ndjson_response

        fake_s3.get_object.side_effect = get_object_side_effect

    def test_manifest_updated_after_successful_replay(self):
        """
        SIMULATE: a quarantine file with a companion .manifest (replayStatus="pending")
                  is fed to the ingest Lambda and all records succeed (204).
        DETECT:   after processing, the manifest is not updated — replayStatus stays
                  "pending" and no replay entry is appended.
        MITIGATE: when source key starts with quarantine/, read existing manifest,
                  append replay entry, set replayStatus="replayed", write back.
        VERIFY:   put_object is called with MANIFEST_KEY; parsed manifest has
                  replayStatus="replayed" and replays[0].ok == 1.
        """
        mod, fake_s3, _ = load_lambda()
        self._setup_s3(fake_s3)

        with patch.object(mod, "post_record", return_value=(204, "")):
            mod.process_object("test-bucket", QUARANTINE_KEY)

        # Find the put_object call that wrote the manifest back
        manifest_put = next(
            (c for c in fake_s3.put_object.call_args_list
             if c.kwargs.get("Key") == MANIFEST_KEY),
            None,
        )
        assert manifest_put is not None, (
            f"Expected put_object(Key='{MANIFEST_KEY}') after replay, but it was not called.\n"
            "Fix: detect quarantine/ source key and write updated manifest after ingest."
        )

        body = manifest_put.kwargs.get("Body", b"")
        if isinstance(body, bytes):
            body = body.decode("utf-8")
        updated = json.loads(body)

        assert updated.get("replayStatus") == "replayed", (
            f"Expected replayStatus='replayed' after full success, "
            f"got '{updated.get('replayStatus')}'"
        )
        assert "replays" in updated and len(updated["replays"]) >= 1, (
            "Expected at least one entry in 'replays' list after replay"
        )
        replay_entry = updated["replays"][-1]
        assert replay_entry.get("ok") == 1, (
            f"Expected replays[-1].ok=1, got {replay_entry.get('ok')}"
        )
        assert replay_entry.get("failed") == 0, (
            f"Expected replays[-1].failed=0, got {replay_entry.get('failed')}"
        )
        assert "replayedAt" in replay_entry, (
            "Expected 'replayedAt' timestamp in replay entry"
        )

    def test_manifest_status_partial_when_some_lines_fail(self):
        """
        SIMULATE: a quarantine file with 2 records is replayed; one succeeds (204),
                  one fails (400 — not retryable).
        DETECT:   manifest replayStatus is set to "replayed" even though one line failed.
        MITIGATE: set replayStatus="partial" when failed > 0 after replay.
        VERIFY:   updated manifest has replayStatus="partial" and replays[-1].failed==1.
        """
        two_record_manifest = dict(INITIAL_MANIFEST, lineCount=2)
        record2 = dict(QUARANTINE_RECORD, recordId="SYN-20260406-s0-00002")

        mod, fake_s3, _ = load_lambda()

        ndjson_response = _ndjson_body(QUARANTINE_RECORD, record2)
        import io as _io

        def get_object_side_effect(Bucket, Key):
            if Key == MANIFEST_KEY:
                return _manifest_s3_body(two_record_manifest)
            return ndjson_response

        fake_s3.get_object.side_effect = get_object_side_effect

        call_count = {"n": 0}

        def mixed_post(record):
            call_count["n"] += 1
            return (204, "") if call_count["n"] == 1 else (400, "Bad Request")

        with patch.object(mod, "post_record", side_effect=mixed_post):
            mod.process_object("test-bucket", QUARANTINE_KEY)

        manifest_put = next(
            (c for c in fake_s3.put_object.call_args_list
             if c.kwargs.get("Key") == MANIFEST_KEY),
            None,
        )
        assert manifest_put is not None, (
            f"Expected put_object(Key='{MANIFEST_KEY}') after partial replay."
        )

        body = manifest_put.kwargs.get("Body", b"")
        if isinstance(body, bytes):
            body = body.decode("utf-8")
        updated = json.loads(body)

        assert updated.get("replayStatus") == "partial", (
            f"Expected replayStatus='partial' when some lines fail, "
            f"got '{updated.get('replayStatus')}'\n"
            "Fix: set replayStatus='partial' when failed > 0."
        )
        replay_entry = updated["replays"][-1]
        assert replay_entry.get("failed") == 1, (
            f"Expected replays[-1].failed=1, got {replay_entry.get('failed')}"
        )
