"""
deploy/test_archive_records.py

Sprint 6 — Storage and Archival

Tests that simulate, detect, and verify fixes for:
  - archive-records.sh mutating the DB in dry-run mode
  - archive-records.sh not reporting eligible record count in dry-run
  - archive-records.sh failing when there is nothing to archive

Uses a fake `psql` and `aws` on PATH — no live DB or AWS required.

Run:
    pytest deploy/test_archive_records.py -v
"""

import os
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

DEPLOY_DIR    = Path(__file__).parent
ARCHIVE_SCRIPT = DEPLOY_DIR / "archive-records.sh"


def _make_executable(p: Path) -> Path:
    p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p


def _write_fake_psql(tmp_path: Path, record_count: int = 5) -> Path:
    """
    Fake psql that:
    - Returns record_count for COUNT queries
    - Returns sample record_ids for SELECT record_id queries
    - Returns nothing (simulating COPY TO STDOUT) for export queries
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    p = bin_dir / "psql"
    p.write_text(textwrap.dedent(f"""\
        #!/usr/bin/env bash
        # Fake psql — reads -c argument and returns canned responses
        CMD=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -c) CMD="$2"; shift 2 ;;
            *)  shift ;;
          esac
        done
        case "$CMD" in
          *"count(*)"*)
            echo "{record_count}" ;;
          *"record_id"*"LIMIT"*)
            for i in $(seq 1 3); do echo "REC-0000$i"; done ;;
          *"COPY"*"TO STDOUT"*)
            for i in $(seq 1 {record_count}); do
              echo '{{"record_id":"REC-'$i'","given_name":"Test","family_name":"User"}}';
            done ;;
          *"DELETE"*)
            for i in $(seq 1 {record_count}); do echo "REC-$i"; done ;;
          *)
            echo "" ;;
        esac
    """))
    _make_executable(p)
    return bin_dir


def _write_fake_aws(bin_dir: Path) -> None:
    p = bin_dir / "aws"
    p.write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        case "$*" in
          *"get-caller-identity"*) echo "123456789" ;;
          *"head-bucket"*)         exit 0 ;;
          *"s3 cp"*)               echo "upload ok" ;;
          *"s3api"*)               echo "" ;;
          *)                       echo "" ;;
        esac
    """))
    _make_executable(p)


def _write_fake_python3(bin_dir: Path) -> None:
    """Fake python3 for the manifest generation snippet."""
    p = bin_dir / "python3"
    p.write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        # Pass through to real python3 for manifest generation
        /usr/local/bin/python3 "$@" 2>/dev/null || \
        /usr/bin/python3 "$@" 2>/dev/null || \
        echo '{"archivedAt":"2026-04-08T00:00:00Z","recordCount":5}'
    """))
    _make_executable(p)


def _run(args: list[str], bin_dir: Path, tmp_path: Path,
         extra_env: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["PATH"] = str(bin_dir) + ":" + env.get("PATH", "")
    env["AWS_REGION"]  = "us-west-1"
    env["DB_HOST"]     = "localhost"
    env["DB_USER"]     = "test"
    env["DB_PASSWORD"] = "test"
    env["DB_NAME"]     = "test_db"
    env["ARCHIVE_BUCKET"] = "test-archive-bucket"
    env.setdefault("HOME", str(tmp_path))
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(ARCHIVE_SCRIPT)] + args,
        env=env,
        capture_output=True,
        text=True,
        cwd=str(DEPLOY_DIR),
    )


# ══════════════════════════════════════════════════════════════════════════════
# Sprint 6 — archive-records.sh dry-run tests
# ══════════════════════════════════════════════════════════════════════════════

class TestArchiveScriptDryRun:

    def test_dry_run_exits_zero(self, tmp_path):
        """
        SIMULATE: operator runs archive-records.sh --dry-run.
        VERIFY:   script exits 0 — dry-run should never fail.
        """
        bin_dir = _write_fake_psql(tmp_path, record_count=5)
        _write_fake_aws(bin_dir)
        _write_fake_python3(bin_dir)
        result = _run(["--dry-run"], bin_dir, tmp_path)
        assert result.returncode == 0, (
            f"archive-records.sh --dry-run exited {result.returncode}.\n"
            f"stdout: {result.stdout[-500:]}\nstderr: {result.stderr[-300:]}"
        )

    def test_dry_run_reports_eligible_count(self, tmp_path):
        """
        SIMULATE: 5 records are older than RETENTION_DAYS.
        DETECT:   dry-run output does not mention how many records would be archived.
        VERIFY:   output contains the eligible count so the operator can decide
                  whether to proceed.
        """
        bin_dir = _write_fake_psql(tmp_path, record_count=5)
        _write_fake_aws(bin_dir)
        _write_fake_python3(bin_dir)
        result = _run(["--dry-run"], bin_dir, tmp_path)
        assert "5" in result.stdout, (
            "Expected eligible record count (5) in dry-run output.\n"
            "Got:\n" + result.stdout[-500:]
        )

    def test_dry_run_does_not_call_delete(self, tmp_path):
        """
        SIMULATE: operator runs --dry-run expecting no DB mutations.
        DETECT:   psql DELETE is called anyway — records are pruned prematurely.
        VERIFY:   output does not contain 'Pruning' or 'deleted' (live-mode words).
        """
        bin_dir = _write_fake_psql(tmp_path, record_count=5)
        _write_fake_aws(bin_dir)
        _write_fake_python3(bin_dir)
        result = _run(["--dry-run"], bin_dir, tmp_path)
        assert "Pruning" not in result.stdout, (
            "dry-run output contained 'Pruning' — DELETE was called.\n"
            "Fix: check DRY_RUN=true before step 4 (pruning)."
        )
        assert "deleted" not in result.stdout.lower(), (
            "dry-run output contained 'deleted' — DB was mutated.\n"
            "Fix: return after printing dry-run summary."
        )

    def test_dry_run_mentions_dry_run(self, tmp_path):
        """
        VERIFY: output clearly states this was a dry run so the operator
                doesn't mistake it for a live archival.
        """
        bin_dir = _write_fake_psql(tmp_path, record_count=5)
        _write_fake_aws(bin_dir)
        _write_fake_python3(bin_dir)
        result = _run(["--dry-run"], bin_dir, tmp_path)
        assert "DRY RUN" in result.stdout.upper(), (
            "Expected 'DRY RUN' in output to make the mode explicit.\n"
            "Got:\n" + result.stdout[-500:]
        )

    def test_exits_zero_when_nothing_to_archive(self, tmp_path):
        """
        SIMULATE: all records are recent — none eligible for archival.
        DETECT:   script exits non-zero or errors when count=0.
        VERIFY:   exits 0 with a 'Nothing to archive' message.
        """
        bin_dir = _write_fake_psql(tmp_path, record_count=0)
        _write_fake_aws(bin_dir)
        _write_fake_python3(bin_dir)
        result = _run(["--dry-run"], bin_dir, tmp_path)
        assert result.returncode == 0, (
            f"archive-records.sh exited {result.returncode} when count=0.\n"
            f"stdout: {result.stdout[-400:]}"
        )
        assert "nothing" in result.stdout.lower() or "0" in result.stdout, (
            "Expected 'Nothing to archive' or '0' when no records are eligible."
        )
