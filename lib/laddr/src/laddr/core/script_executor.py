"""Script execution engine for Laddr workers.

Provides async subprocess execution with workspace management, timeout handling,
metrics parsing, and artifact tracking.
"""
from __future__ import annotations

import asyncio
import dataclasses
import json
import os
import shutil
import signal
import uuid
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Environment variable constants
# ---------------------------------------------------------------------------

STDOUT_CAP = int(os.environ.get("LADDR_STDOUT_CAP", 1_048_576))
ARTIFACT_THRESHOLD = int(os.environ.get("LADDR_ARTIFACT_THRESHOLD", 10_485_760))
WORKSPACE_TTL_HOURS = int(os.environ.get("LADDR_WORKSPACE_TTL_HOURS", 24))
WORKSPACE_ROOT = Path.home() / ".laddr" / "workspaces"


# ---------------------------------------------------------------------------
# ScriptResult dataclass
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class ScriptResult:
    """Result of a script execution."""

    status: str  # "success", "failure", "timeout", "error"
    exit_code: int
    stdout: str
    stderr: str
    metrics: Optional[dict]
    artifacts: list[str]
    duration_seconds: float
    workspace_path: str

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)


# ---------------------------------------------------------------------------
# Workspace resolution
# ---------------------------------------------------------------------------


def _resolve_workspace(
    working_directory: Optional[str] = None,
    experiment_id: Optional[str] = None,
) -> tuple[Path, bool]:
    """Return (workspace_path, is_ephemeral).

    Priority:
    1. working_directory — use as-is, not ephemeral
    2. experiment_id — ~/.laddr/workspaces/{experiment_id}/, not ephemeral
    3. fallback — /tmp/laddr-script-{uuid[:12]}/, ephemeral
    """
    if working_directory is not None:
        return Path(working_directory), False

    if experiment_id is not None:
        return WORKSPACE_ROOT / experiment_id, False

    uid = uuid.uuid4().hex[:12]
    return Path(f"/tmp/laddr-script-{uid}"), True


# ---------------------------------------------------------------------------
# Metrics parsing
# ---------------------------------------------------------------------------


def _parse_metrics(workspace: Path) -> Optional[dict]:
    """Read metrics.json from workspace. Returns dict or None on any failure."""
    metrics_file = workspace / "metrics.json"
    if not metrics_file.exists():
        return None
    try:
        data = metrics_file.read_text(encoding="utf-8")
        parsed = json.loads(data)
        if not isinstance(parsed, dict):
            return None
        return parsed
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Main execution function
# ---------------------------------------------------------------------------


async def execute_script(
    command: str,
    *,
    working_directory: Optional[str] = None,
    experiment_id: Optional[str] = None,
    timeout_seconds: Optional[float] = None,
    env: Optional[dict[str, str]] = None,
) -> ScriptResult:
    """Execute a shell command asynchronously within a managed workspace.

    Args:
        command: Shell command to run.
        working_directory: Explicit workspace path (not ephemeral).
        experiment_id: Used to derive a persistent workspace under WORKSPACE_ROOT.
        timeout_seconds: Optional wall-clock timeout. On timeout, SIGTERM is sent
            and after 5 s a SIGKILL is issued. Returns status="timeout".
        env: Additional environment variables to merge into the process environment.

    Returns:
        ScriptResult with execution details.
    """
    workspace, is_ephemeral = _resolve_workspace(working_directory, experiment_id)
    workspace.mkdir(parents=True, exist_ok=True)

    # Write lockfile
    lockfile = workspace / ".active"
    lockfile.write_text(str(os.getpid()))

    # Build environment
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)

    import time

    start = time.monotonic()
    status = "success"
    exit_code = -1
    stdout_data = b""
    stderr_data = b""

    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(workspace),
            env=proc_env,
        )

        try:
            if timeout_seconds is not None:
                stdout_data, stderr_data = await asyncio.wait_for(
                    proc.communicate(),
                    timeout=timeout_seconds,
                )
            else:
                stdout_data, stderr_data = await proc.communicate()

            exit_code = proc.returncode if proc.returncode is not None else -1
            status = "success" if exit_code == 0 else "failure"

        except asyncio.TimeoutError:
            # SIGTERM first
            try:
                proc.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass

            try:
                await asyncio.wait_for(proc.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                try:
                    proc.send_signal(signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    await proc.wait()
                except Exception:
                    pass

            # Collect whatever output accumulated before timeout
            if proc.stdout:
                try:
                    stdout_data = await proc.stdout.read()
                except Exception:
                    stdout_data = b""
            if proc.stderr:
                try:
                    stderr_data = await proc.stderr.read()
                except Exception:
                    stderr_data = b""

            exit_code = proc.returncode if proc.returncode is not None else -1
            status = "timeout"

    except Exception as exc:
        status = "error"
        exit_code = -1
        stderr_data = str(exc).encode()
    finally:
        duration = time.monotonic() - start

    # Cap stdout/stderr
    stdout_str = stdout_data[:STDOUT_CAP].decode("utf-8", errors="replace")
    stderr_str = stderr_data[:STDOUT_CAP].decode("utf-8", errors="replace")

    # Parse metrics
    metrics = _parse_metrics(workspace)

    # Remove lockfile
    try:
        lockfile.unlink(missing_ok=True)
    except Exception:
        pass

    # Clean up ephemeral workspace
    if is_ephemeral:
        try:
            shutil.rmtree(workspace, ignore_errors=True)
        except Exception:
            pass

    return ScriptResult(
        status=status,
        exit_code=exit_code,
        stdout=stdout_str,
        stderr=stderr_str,
        metrics=metrics,
        artifacts=[],
        duration_seconds=duration,
        workspace_path=str(workspace),
    )
