"""
deploy/lambda/test_linkage_engine_ingestor.py

Sprint 3d-ii — Ingestor Lambda
Tests that simulate, detect, and verify fixes for:
  - Large file from external party not being split before reaching validate Lambda
  - Original raw file not being archived after splitting
  - Chunk files exceeding CHUNK_SIZE lines
  - Chunk recordIds not being unique across chunks
  - Split producing wrong total record count

Run:
    pytest deploy/lambda/test_linkage_engine_ingestor.py -v
"""

import importlib.util
import io
import json
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

LAMBDA_PATH = Path(__file__).parent / "linkage-engine-ingestor.py"

RAW_BUCKET     = "linkage-engine-raw-123456789"
LANDING_BUCKET = "linkage-engine-landing-123456789"
RAW_KEY        = "batch-20260408.ndjson"
ARCHIVE_KEY    = f"archive/{RAW_KEY}"
CHUNK_SIZE     = 200


# ── Bootstrap helpers ─────────────────────────────────────────────────────────

def _make_fake_boto3():
    fake_boto3 = types.ModuleType("boto3")
    fake_s3    = MagicMock()
    fake_boto3.client = MagicMock(return_value=fake_s3)
    return fake_boto3, fake_s3


def load_lambda(fake_boto3=None, fake_s3=None,
                landing_bucket=LANDING_BUCKET, chunk_size=CHUNK_SIZE):
    if fake_boto3 is None:
        fake_boto3, fake_s3 = _make_fake_boto3()
    env = {
        "LANDING_BUCKET": landing_bucket,
        "CHUNK_SIZE":     str(chunk_size),
    }
    with patch.dict("os.environ", env, clear=False), \
         patch.dict("sys.modules", {"boto3": fake_boto3}):
        spec = importlib.util.spec_from_file_location("linkage_engine_ingestor", LAMBDA_PATH)
        mod  = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    mod.s3 = fake_s3
    return mod, fake_s3


def _s3_body(lines):
    """Return a fake S3 get_object response for a list of text lines."""
    body = "\n".join(lines) + "\n"
    return {"Body": io.BytesIO(body.encode("utf-8"))}


def _ndjson_lines(count, prefix="REC"):
    """Generate count minimal NDJSON lines."""
    return [json.dumps({"recordId": f"{prefix}-{i:05d}", "data": f"record {i}"})
            for i in range(1, count + 1)]


def _s3_event(bucket=RAW_BUCKET, key=RAW_KEY):
    return {
        "Records": [{
            "eventName": "ObjectCreated:Put",
            "s3": {
                "bucket": {"name": bucket},
                "object": {"key": key},
            },
        }]
    }


def _get_put_calls(fake_s3, bucket=None):
    """Return all put_object calls, optionally filtered by bucket."""
    calls = fake_s3.put_object.call_args_list
    if bucket:
        calls = [c for c in calls if c.kwargs.get("Bucket") == bucket]
    return calls


def _get_copy_calls(fake_s3):
    return fake_s3.copy_object.call_args_list


def _parse_ndjson_body(call):
    body = call.kwargs.get("Body", b"")
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    return [json.loads(l) for l in body.strip().splitlines() if l.strip()]


# ══════════════════════════════════════════════════════════════════════════════
# Threat: large file reaches validate Lambda without splitting → TTL exhaustion
# ══════════════════════════════════════════════════════════════════════════════

class TestChunkSplitting:

    def test_large_file_split_into_multiple_chunks(self):
        """
        SIMULATE: a 500-line file arrives in the raw bucket.
        DETECT:   ingestor writes a single 500-line file to landing — validate
                  Lambda would time out processing it.
        MITIGATE: split into ceil(500/200) = 3 chunk files, each ≤ CHUNK_SIZE lines.
        VERIFY:   put_object called 3 times on the landing bucket.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        assert len(landing_puts) == 3, (
            f"Expected 3 chunk files for 500 lines with CHUNK_SIZE=200, "
            f"got {len(landing_puts)}.\n"
            "Fix: split lines into ceil(total/CHUNK_SIZE) chunks and write each separately."
        )

    def test_each_chunk_within_chunk_size(self):
        """
        SIMULATE: ingestor splits 500 lines but one chunk has 300 lines.
        DETECT:   that chunk would still risk TTL exhaustion in validate Lambda.
        MITIGATE: each chunk written to landing must contain ≤ CHUNK_SIZE lines.
        VERIFY:   every put_object Body has ≤ CHUNK_SIZE non-empty lines.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        assert landing_puts, "No chunks written to landing bucket"

        oversized = []
        for c in landing_puts:
            records = _parse_ndjson_body(c)
            if len(records) > CHUNK_SIZE:
                oversized.append((c.kwargs.get("Key"), len(records)))

        assert not oversized, (
            f"Chunks exceeding CHUNK_SIZE={CHUNK_SIZE}:\n" +
            "\n".join(f"  {k}: {n} lines" for k, n in oversized) +
            "\nFix: slice lines[i:i+CHUNK_SIZE] for each chunk."
        )

    def test_total_records_preserved_across_chunks(self):
        """
        SIMULATE: ingestor splits 500 lines but drops some during chunking.
        DETECT:   total lines across all chunks ≠ 500 — records silently lost.
        MITIGATE: sum of all chunk line counts must equal the original line count.
        VERIFY:   total lines across all put_object calls == 500.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        total = sum(len(_parse_ndjson_body(c)) for c in landing_puts)
        assert total == 500, (
            f"Expected 500 total records across all chunks, got {total}.\n"
            "Fix: ensure no lines are dropped or duplicated during chunking."
        )

    def test_small_file_produces_single_chunk(self):
        """
        SIMULATE: a 50-line file (well within CHUNK_SIZE) arrives.
        DETECT:   ingestor unnecessarily splits it into multiple files.
        MITIGATE: files ≤ CHUNK_SIZE lines should produce exactly one chunk.
        VERIFY:   exactly one put_object call on the landing bucket.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(50))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        assert len(landing_puts) == 1, (
            f"Expected 1 chunk for 50-line file, got {len(landing_puts)}.\n"
            "Fix: only split when len(lines) > CHUNK_SIZE."
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: original raw file not archived — no audit trail of what was received
# ══════════════════════════════════════════════════════════════════════════════

class TestArchiving:

    def test_original_file_archived_after_splitting(self):
        """
        SIMULATE: ingestor splits the file but leaves the original in place.
        DETECT:   raw bucket still has the original — no record of when it was
                  processed; re-trigger risk if S3 event fires again.
        MITIGATE: copy original to archive/<key> in raw bucket, then delete original.
        VERIFY:   copy_object called with destination key starting with 'archive/'.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        copy_calls = _get_copy_calls(fake_s3)
        archive_calls = [
            c for c in copy_calls
            if str(c.kwargs.get("Key", "")).startswith("archive/")
        ]
        assert archive_calls, (
            "No copy_object call with destination Key starting with 'archive/'.\n"
            "Fix: after writing chunks, call s3.copy_object to archive/<key> "
            "in the raw bucket."
        )

    def test_original_file_deleted_after_archiving(self):
        """
        SIMULATE: ingestor archives the original but does not delete it.
        DETECT:   original still triggers S3 events on re-upload or listing.
        MITIGATE: delete original from raw bucket after archiving.
        VERIFY:   delete_object called with the original key.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        delete_calls = fake_s3.delete_object.call_args_list
        deleted_keys = [c.kwargs.get("Key") for c in delete_calls]
        assert RAW_KEY in deleted_keys, (
            f"Expected delete_object(Key='{RAW_KEY}') after archiving, "
            f"but deleted keys were: {deleted_keys}\n"
            "Fix: call s3.delete_object(Bucket=raw_bucket, Key=key) after archiving."
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: chunk key naming collision — two chunks overwrite each other
# ══════════════════════════════════════════════════════════════════════════════

class TestChunkKeyNaming:

    def test_chunk_keys_are_unique(self):
        """
        SIMULATE: ingestor writes all chunks with the same key — each overwrites
                  the previous, leaving only the last chunk in landing.
        DETECT:   duplicate put_object Key values on the landing bucket.
        MITIGATE: name chunks <stem>-chunk-NNN<ext> with a zero-padded index.
        VERIFY:   all put_object Key values on landing bucket are distinct.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(500))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        keys = [c.kwargs.get("Key") for c in landing_puts]
        assert len(keys) == len(set(keys)), (
            f"Duplicate chunk keys: {[k for k in keys if keys.count(k) > 1]}\n"
            "Fix: include a zero-padded chunk index in the key, "
            "e.g. batch-chunk-001.ndjson, batch-chunk-002.ndjson."
        )

    def test_chunk_keys_derived_from_original_key(self):
        """
        VERIFY: chunk keys include the original filename stem so the source
                file is traceable from the landing bucket.
        """
        mod, fake_s3 = load_lambda()
        fake_s3.get_object.return_value = _s3_body(_ndjson_lines(300))

        mod.process_object(RAW_BUCKET, RAW_KEY, LANDING_BUCKET, CHUNK_SIZE)

        landing_puts = _get_put_calls(fake_s3, bucket=LANDING_BUCKET)
        stem = RAW_KEY.replace(".ndjson", "")
        for c in landing_puts:
            key = c.kwargs.get("Key", "")
            assert stem in key, (
                f"Chunk key '{key}' does not contain original stem '{stem}'.\n"
                "Fix: derive chunk key from original key stem."
            )
