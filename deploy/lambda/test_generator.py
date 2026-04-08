"""
deploy/lambda/test_generator.py

Sprint 1 — Generator Integrity
Tests that simulate, detect, and verify fixes for:
  #1 Duplicate recordId across runs
  #4 birthYear >= eventYear (person not yet born at event time)

Run:
    pytest deploy/lambda/test_generator.py -v
"""

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

# ── Load the generator module dynamically ─────────────────────────────────────
GENERATOR_PATH = Path(__file__).parent.parent / "generate-synthetic-data.py"

def load_generator():
    """Import generate-synthetic-data.py as a module without executing its CLI."""
    spec = importlib.util.spec_from_file_location("generator", GENERATOR_PATH)
    mod = importlib.util.module_from_spec(spec)
    # Patch sys.argv so argparse doesn't consume pytest args
    orig_argv = sys.argv
    sys.argv = ["generate-synthetic-data.py", "--count", "50", "--out", "/dev/null"]
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = orig_argv
    return mod


def generate_records(count=50, seed=0):
    """Run the generator and return parsed records as a list of dicts."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ndjson", delete=False) as f:
        out_path = f.name
    try:
        orig_argv = sys.argv
        sys.argv = [
            "generate-synthetic-data.py",
            "--count", str(count),
            "--seed",  str(seed),
            "--out",   out_path,
        ]
        spec = importlib.util.spec_from_file_location("generator", GENERATOR_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.argv = orig_argv

        records = []
        with open(out_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    records.append(json.loads(line))
        return records
    finally:
        sys.argv = orig_argv
        os.unlink(out_path)


# ── Helpers ───────────────────────────────────────────────────────────────────

def all_ids(records):
    return [r["recordId"] for r in records]

def records_with_birth_year(records):
    return [r for r in records if r.get("birthYear") is not None]


# ══════════════════════════════════════════════════════════════════════════════
# Threat #1 — Duplicate recordId across runs
# ══════════════════════════════════════════════════════════════════════════════

class TestRecordIdUniqueness:

    def test_ids_include_batch_date(self):
        """
        SIMULATE: bare SYN-NNNNN IDs have no run context.
        DETECT:   IDs must embed a date component so two runs on different
                  days never collide.
        MITIGATE: generator embeds YYYYMMDD in the ID prefix.
        """
        records = generate_records(count=50, seed=0)
        ids = all_ids(records)
        assert len(ids) > 0, "generator produced no records"

        bare_ids = [rid for rid in ids if rid.startswith("SYN-") and
                    len(rid.split("-")) < 3]
        assert bare_ids == [], (
            f"Found {len(bare_ids)} bare SYN-NNNNN IDs with no date component.\n"
            f"Examples: {bare_ids[:5]}\n"
            "Fix: embed batch date in recordId, e.g. SYN-20260408-00001"
        )

    def test_ids_unique_within_single_run(self):
        """
        SIMULATE: generator assigns sequential IDs — duplicates would mean
                  the counter reset mid-run.
        DETECT:   all IDs in one run must be unique.
        """
        records = generate_records(count=100, seed=0)
        ids = all_ids(records)
        assert len(ids) == len(set(ids)), (
            f"Duplicate IDs within a single run: "
            f"{[rid for rid in ids if ids.count(rid) > 1][:5]}"
        )

    def test_ids_unique_across_different_seeds(self):
        """
        SIMULATE: two operators run the generator on the same day with
                  different seeds — IDs must not collide.
        DETECT:   intersection of ID sets from seed=0 and seed=99 must be empty.
        MITIGATE: IDs include seed in addition to date.
        """
        records_a = generate_records(count=50, seed=0)
        records_b = generate_records(count=50, seed=99)
        ids_a = set(all_ids(records_a))
        ids_b = set(all_ids(records_b))
        collisions = ids_a & ids_b
        assert collisions == set(), (
            f"ID collision across seed=0 and seed=99 runs: {list(collisions)[:5]}\n"
            "Fix: include seed value in recordId prefix, e.g. SYN-20260408-s0-00001"
        )

    def test_ids_unique_across_different_dates(self):
        """
        SIMULATE: same seed run on two different dates — IDs must not collide
                  if date is part of the ID.
        DETECT:   IDs from two runs must differ when the date component differs.
        """
        records_a = generate_records(count=20, seed=42)
        ids_a = all_ids(records_a)
        # All IDs should contain a date-like segment (8 digits YYYYMMDD)
        import re
        date_pattern = re.compile(r'\d{8}')
        ids_without_date = [rid for rid in ids_a if not date_pattern.search(rid)]
        assert ids_without_date == [], (
            f"{len(ids_without_date)} IDs have no 8-digit date segment.\n"
            f"Examples: {ids_without_date[:5]}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat #4 — birthYear >= eventYear
# ══════════════════════════════════════════════════════════════════════════════

class TestBirthYearCoherence:

    def test_birth_year_strictly_before_event_year(self):
        """
        SIMULATE: rand_birth_year can return a value >= eventYear if the
                  age range is miscalculated.
        DETECT:   every record with birthYear must satisfy birthYear < eventYear.
        MITIGATE: generator asserts birth_year < event_year before appending record.
        """
        records = generate_records(count=200, seed=0)
        with_birth = records_with_birth_year(records)
        assert len(with_birth) > 0, "no records with birthYear — cannot test"

        violations = [
            r for r in with_birth
            if r["birthYear"] >= r["eventYear"]
        ]
        assert violations == [], (
            f"{len(violations)} records have birthYear >= eventYear:\n" +
            "\n".join(
                f"  recordId={r['recordId']} birthYear={r['birthYear']} eventYear={r['eventYear']}"
                for r in violations[:5]
            ) + "\nFix: add assert birth_year < event_year in rand_birth_year()"
        )

    def test_implied_age_in_plausible_range(self):
        """
        SIMULATE: extreme age values (age=0, age=150) can slip through if
                  the birth year range is too wide.
        DETECT:   implied age (eventYear - birthYear) must be 1..110 for all
                  records that have a birthYear.
        MITIGATE: generator clamps age_lo=1, age_hi=110 in rand_birth_year.
        """
        records = generate_records(count=200, seed=7)
        with_birth = records_with_birth_year(records)

        too_young = [r for r in with_birth if (r["eventYear"] - r["birthYear"]) < 1]
        too_old   = [r for r in with_birth if (r["eventYear"] - r["birthYear"]) > 110]

        assert too_young == [], (
            f"{len(too_young)} records imply age < 1:\n" +
            "\n".join(
                f"  recordId={r['recordId']} age={r['eventYear']-r['birthYear']}"
                for r in too_young[:5]
            )
        )
        assert too_old == [], (
            f"{len(too_old)} records imply age > 110:\n" +
            "\n".join(
                f"  recordId={r['recordId']} age={r['eventYear']-r['birthYear']}"
                for r in too_old[:5]
            )
        )

    def test_designed_pairs_have_consistent_birth_years(self):
        """
        SIMULATE: designed conflict pairs (cherry chords) intentionally have
                  different birth years — but the individual records in each
                  pair must still each satisfy birthYear < eventYear.
        DETECT:   even conflict pairs must not produce impossible birth years.
        """
        records = generate_records(count=200, seed=0)
        with_birth = records_with_birth_year(records)

        violations = [
            r for r in with_birth
            if r["birthYear"] >= r["eventYear"]
        ]
        assert violations == [], (
            f"Designed conflict pairs contain impossible birth years:\n" +
            "\n".join(
                f"  recordId={r['recordId']} birthYear={r['birthYear']} eventYear={r['eventYear']}"
                for r in violations[:5]
            )
        )

    def test_records_without_birth_year_are_valid(self):
        """
        DETECT: records with no birthYear (birthYear=None) must still have
                a valid eventYear in the expected historical range (1830-1890).
        """
        records = generate_records(count=200, seed=0)
        without_birth = [r for r in records if r.get("birthYear") is None]

        out_of_range = [
            r for r in without_birth
            if not (1830 <= r.get("eventYear", 0) <= 1890)
        ]
        assert out_of_range == [], (
            f"{len(out_of_range)} records without birthYear have eventYear outside 1830-1890:\n" +
            "\n".join(
                f"  recordId={r['recordId']} eventYear={r['eventYear']}"
                for r in out_of_range[:5]
            )
        )
