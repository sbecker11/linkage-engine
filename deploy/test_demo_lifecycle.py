"""
deploy/test_demo_lifecycle.py

Sprint 11 — Demo Lifecycle

Tests that simulate, detect, and verify fixes for:
  - demo-stop.sh not being idempotent (fails on second run)
  - demo-start.sh not detecting a healthy service

These tests run the actual shell scripts in a subprocess with a fake `aws`
and `curl` on PATH, so no real AWS credentials are required.

demo-start.sh honours the DEMO_CHECKLIST env var to point at a fake checklist
script, making the checklist step fully testable without a live ALB.

Run:
    pytest deploy/test_demo_lifecycle.py -v
"""

import os
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

DEPLOY_DIR   = Path(__file__).parent
STOP_SCRIPT  = DEPLOY_DIR / "demo-stop.sh"
START_SCRIPT = DEPLOY_DIR / "demo-start.sh"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_executable(path: Path) -> Path:
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _write_fake_aws(tmp_path: Path, script_body: str) -> Path:
    """Write a fake `aws` CLI to tmp_path/bin/aws and return the bin dir."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    p = bin_dir / "aws"
    p.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(script_body))
    _make_executable(p)
    return bin_dir


def _write_fake_curl(bin_dir: Path, script_body: str) -> None:
    p = bin_dir / "curl"
    p.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(script_body))
    _make_executable(p)


def _write_fake_checklist(tmp_path: Path, exit_code: int = 0) -> Path:
    """Write a fake demo-checklist.sh that exits with exit_code."""
    p = tmp_path / "fake_checklist.sh"
    msg = "  ✅  All 5 checks passed — ready for demo" if exit_code == 0 \
          else "  ⚠️   1/5 checks failed"
    p.write_text(f"#!/usr/bin/env bash\necho '{msg}'\nexit {exit_code}\n")
    _make_executable(p)
    return p


def _run(script: Path, bin_dir: Path, tmp_path: Path,
         extra_env: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["PATH"] = str(bin_dir) + ":" + env.get("PATH", "")
    env["AWS_REGION"] = "us-west-1"
    env.setdefault("HOME", str(tmp_path))
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(script)],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(DEPLOY_DIR),
    )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: demo-stop.sh fails on second run — operator can't safely re-run it
# ══════════════════════════════════════════════════════════════════════════════

class TestDemoStopIdempotent:

    def _already_stopped_bin(self, tmp_path: Path) -> Path:
        """Fake aws: ECS desiredCount=0, Aurora status=paused."""
        return _write_fake_aws(tmp_path, """\
            case "$*" in
              *"describe-services"*)  echo "0" ;;
              *"describe-db-clusters"*) echo "paused" ;;
              *"get-function"*)       echo "Active" ;;
              *)                      echo "" ;;
            esac
        """)

    def test_stop_exits_zero_when_already_stopped(self, tmp_path):
        """
        SIMULATE: demo-stop.sh has already run; ECS=0, Aurora=paused.
        DETECT:   second run exits non-zero or prints an error.
        MITIGATE: script checks current state before issuing AWS calls;
                  already-stopped resources are skipped with a ✓ message.
        VERIFY:   exit code is 0 on second run.
        """
        result = _run(STOP_SCRIPT, self._already_stopped_bin(tmp_path), tmp_path)
        assert result.returncode == 0, (
            f"demo-stop.sh exited {result.returncode} on second run.\n"
            f"stdout: {result.stdout[-500:]}\nstderr: {result.stderr[-300:]}\n"
            "Fix: check current ECS desiredCount / Aurora status before "
            "issuing update calls; skip if already in target state."
        )

    def test_stop_reports_already_stopped(self, tmp_path):
        """
        VERIFY: when resources are already stopped, output contains
                'already' — not silent.
        """
        result = _run(STOP_SCRIPT, self._already_stopped_bin(tmp_path), tmp_path)
        assert "already" in result.stdout.lower(), (
            "Expected 'already' in demo-stop.sh output when resources are "
            "already stopped.\nGot:\n" + result.stdout[-500:]
        )

    def test_stop_exits_zero_when_resources_running(self, tmp_path):
        """
        SIMULATE: ECS desiredCount=1, Aurora status=available — normal state.
        VERIFY:   demo-stop.sh exits 0 after issuing scale/pause commands.
        """
        bin_dir = _write_fake_aws(tmp_path, """\
            case "$*" in
              *"describe-services"*)    echo "1" ;;
              *"describe-db-clusters"*) echo "available" ;;
              *"update-service"*)       echo "" ;;
              *"modify-db-cluster"*)    echo "" ;;
              *"get-function"*)         echo "Active" ;;
              *)                        echo "" ;;
            esac
        """)
        result = _run(STOP_SCRIPT, bin_dir, tmp_path)
        assert result.returncode == 0, (
            f"demo-stop.sh exited {result.returncode} when resources were running.\n"
            f"stdout: {result.stdout[-500:]}\nstderr: {result.stderr[-300:]}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Threat: demo-start.sh doesn't detect a healthy service — operator goes live
#         with a broken app
# ══════════════════════════════════════════════════════════════════════════════

class TestDemoStartReachesHealthy:

    def _healthy_bin(self, tmp_path: Path) -> Path:
        """Fake aws + curl: ECS running=1, ALB returns 200."""
        bin_dir = _write_fake_aws(tmp_path, """\
            case "$*" in
              *"describe-db-clusters"*)  echo "available" ;;
              *"describe-services"*)     echo "1" ;;
              *"describe-load-balancers"*) echo "fake-alb.us-west-1.elb.amazonaws.com" ;;
              *"modify-db-cluster"*)     echo "" ;;
              *"update-service"*)        echo "" ;;
              *)                         echo "" ;;
            esac
        """)
        _write_fake_curl(bin_dir, """\
            echo "200"
        """)
        return bin_dir

    def test_start_exits_zero_when_healthy(self, tmp_path):
        """
        SIMULATE: ECS task comes up immediately, ALB returns 200.
        DETECT:   demo-start.sh exits non-zero even when everything is healthy.
        MITIGATE: script waits for runningCount=1 and HTTP 200 before exiting.
        VERIFY:   exit code is 0.
        """
        bin_dir   = self._healthy_bin(tmp_path)
        checklist = _write_fake_checklist(tmp_path, exit_code=0)
        result = _run(START_SCRIPT, bin_dir, tmp_path,
                      extra_env={"DEMO_CHECKLIST": str(checklist),
                                 "SKIP_SEED": "true"})
        assert result.returncode == 0, (
            f"demo-start.sh exited {result.returncode} with a healthy stack.\n"
            f"stdout: {result.stdout[-600:]}\nstderr: {result.stderr[-300:]}"
        )

    def test_start_prints_app_url(self, tmp_path):
        """
        VERIFY: demo-start.sh prints the ALB URL so the operator knows
                where to point the browser.
        """
        bin_dir   = self._healthy_bin(tmp_path)
        checklist = _write_fake_checklist(tmp_path, exit_code=0)
        result = _run(START_SCRIPT, bin_dir, tmp_path,
                      extra_env={"DEMO_CHECKLIST": str(checklist),
                                 "SKIP_SEED": "true"})
        assert "chord-diagram.html" in result.stdout, (
            "Expected demo-start.sh to print the chord-diagram URL.\nGot:\n"
            + result.stdout[-600:]
        )

    def test_start_exits_nonzero_when_aurora_missing(self, tmp_path):
        """
        SIMULATE: Aurora cluster does not exist (not provisioned yet).
        DETECT:   demo-start.sh proceeds anyway and hangs waiting for ECS.
        MITIGATE: script checks Aurora status first; exits 1 with a clear
                  message if cluster is not found.
        VERIFY:   exit code is non-zero and output mentions provision-aws.sh.
        """
        bin_dir = _write_fake_aws(tmp_path, """\
            case "$*" in
              *"describe-db-clusters"*) echo "not-found" ;;
              *)                        echo "" ;;
            esac
        """)
        result = _run(START_SCRIPT, bin_dir, tmp_path)
        assert result.returncode != 0, (
            "demo-start.sh should exit non-zero when Aurora cluster is missing, "
            f"but exited {result.returncode}."
        )
        combined = result.stdout + result.stderr
        assert "provision-aws.sh" in combined, (
            "Expected demo-start.sh to mention provision-aws.sh when Aurora "
            "is missing.\nGot:\n" + combined[-500:]
        )
