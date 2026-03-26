"""Tests for script_executor — Tasks 1, 2, 3 & 4."""
from __future__ import annotations

import json
import os
import shutil
import time
from pathlib import Path

import pytest
import pytest_asyncio

from laddr.core.script_executor import (
    ARTIFACT_THRESHOLD,
    ScriptResult,
    WORKSPACE_ROOT,
    _parse_metrics,
    _resolve_workspace,
    _scan_for_artifacts,
    cleanup_workspaces,
    execute_script,
)


# ---------------------------------------------------------------------------
# TestExecuteScriptBasic
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestExecuteScriptBasic:
    async def test_successful_command(self):
        result = await execute_script("echo hello")
        assert result.status == "success"
        assert result.exit_code == 0
        assert "hello" in result.stdout
        assert isinstance(result.duration_seconds, float)
        assert result.duration_seconds >= 0

    async def test_failing_command(self):
        result = await execute_script("exit 42", )
        assert result.status == "failure"
        assert result.exit_code == 42

    async def test_command_not_found(self):
        result = await execute_script("this_command_does_not_exist_xyz_abc_123")
        # Shell will return non-zero; status is failure or error
        assert result.status in ("failure", "error")
        assert result.exit_code != 0


# ---------------------------------------------------------------------------
# TestExecuteScriptTimeout
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestExecuteScriptTimeout:
    async def test_timeout_kills_process(self):
        result = await execute_script("sleep 60", timeout_seconds=1)
        assert result.status == "timeout"
        assert result.duration_seconds < 10


# ---------------------------------------------------------------------------
# TestMetricsParsing
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestMetricsParsing:
    async def test_reads_metrics_json(self, tmp_path):
        metrics_data = {"loss": 0.42, "accuracy": 0.95}
        # Write metrics.json via the execute_script working_directory
        result = await execute_script(
            f"echo '{json.dumps(metrics_data)}' > metrics.json",
            working_directory=str(tmp_path),
        )
        assert result.status == "success"
        assert result.metrics is not None
        assert result.metrics["loss"] == pytest.approx(0.42)
        assert result.metrics["accuracy"] == pytest.approx(0.95)

    async def test_missing_metrics_returns_none(self, tmp_path):
        result = await execute_script("echo hello", working_directory=str(tmp_path))
        assert result.metrics is None

    async def test_malformed_metrics_returns_none(self, tmp_path):
        (tmp_path / "metrics.json").write_text("this is not json {{{")
        result = await execute_script("echo hello", working_directory=str(tmp_path))
        assert result.metrics is None


# ---------------------------------------------------------------------------
# TestWorkspacePersistence
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestWorkspacePersistence:
    async def test_experiment_id_creates_persistent_workspace(self):
        experiment_id = "test-exp-persist-001"
        workspace = WORKSPACE_ROOT / experiment_id
        try:
            result = await execute_script("echo persistent", experiment_id=experiment_id)
            assert result.status == "success"
            # Workspace should still exist (not ephemeral)
            assert workspace.exists()
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    async def test_workspace_reuse_across_calls(self):
        experiment_id = "test-exp-reuse-002"
        workspace = WORKSPACE_ROOT / experiment_id
        try:
            # First call: create a file
            await execute_script(
                "echo 'first run' > run1.txt",
                experiment_id=experiment_id,
            )
            # Second call: the file should still be there
            result = await execute_script(
                "cat run1.txt",
                experiment_id=experiment_id,
            )
            assert result.status == "success"
            assert "first run" in result.stdout
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    async def test_ephemeral_workspace_cleaned(self):
        result = await execute_script("echo ephemeral")
        # No experiment_id and no working_directory → ephemeral
        workspace = Path(result.workspace_path)
        assert not workspace.exists(), f"Ephemeral workspace was not cleaned up: {workspace}"

    async def test_lockfile_removed_after_execution(self, tmp_path):
        result = await execute_script("echo hello", working_directory=str(tmp_path))
        lockfile = tmp_path / ".active"
        assert not lockfile.exists(), "Lockfile should be removed after execution"


# ---------------------------------------------------------------------------
# TestScriptResultDataclass
# ---------------------------------------------------------------------------


class TestScriptResultDataclass:
    def test_to_dict_returns_all_fields(self):
        r = ScriptResult(
            status="success",
            exit_code=0,
            stdout="hello\n",
            stderr="",
            metrics={"loss": 0.1},
            artifacts=["output.csv"],
            duration_seconds=1.23,
            workspace_path="/tmp/test",
        )
        d = r.to_dict()
        assert d["status"] == "success"
        assert d["exit_code"] == 0
        assert d["stdout"] == "hello\n"
        assert d["stderr"] == ""
        assert d["metrics"] == {"loss": 0.1}
        assert d["artifacts"] == ["output.csv"]
        assert d["duration_seconds"] == pytest.approx(1.23)
        assert d["workspace_path"] == "/tmp/test"

    def test_to_dict_none_metrics(self):
        r = ScriptResult(
            status="failure",
            exit_code=1,
            stdout="",
            stderr="error",
            metrics=None,
            artifacts=[],
            duration_seconds=0.5,
            workspace_path="/tmp/x",
        )
        d = r.to_dict()
        assert d["metrics"] is None
        assert d["artifacts"] == []


# ---------------------------------------------------------------------------
# TestResolveWorkspace
# ---------------------------------------------------------------------------


class TestResolveWorkspace:
    def test_explicit_working_directory(self, tmp_path):
        path, ephemeral = _resolve_workspace(working_directory=str(tmp_path))
        assert path == tmp_path
        assert ephemeral is False

    def test_experiment_id(self):
        path, ephemeral = _resolve_workspace(experiment_id="my-exp-123")
        assert path == WORKSPACE_ROOT / "my-exp-123"
        assert ephemeral is False

    def test_fallback_is_ephemeral(self):
        path, ephemeral = _resolve_workspace()
        assert ephemeral is True
        assert "laddr-script-" in str(path)

    def test_working_directory_takes_priority_over_experiment_id(self, tmp_path):
        path, ephemeral = _resolve_workspace(
            working_directory=str(tmp_path),
            experiment_id="should-be-ignored",
        )
        assert path == tmp_path
        assert ephemeral is False


# ---------------------------------------------------------------------------
# TestParseMetrics
# ---------------------------------------------------------------------------


class TestParseMetrics:
    def test_reads_valid_json(self, tmp_path):
        (tmp_path / "metrics.json").write_text('{"a": 1, "b": 2}')
        result = _parse_metrics(tmp_path)
        assert result == {"a": 1, "b": 2}

    def test_missing_file(self, tmp_path):
        result = _parse_metrics(tmp_path)
        assert result is None

    def test_malformed_json(self, tmp_path):
        (tmp_path / "metrics.json").write_text("not json")
        result = _parse_metrics(tmp_path)
        assert result is None

    def test_non_dict_json(self, tmp_path):
        (tmp_path / "metrics.json").write_text("[1, 2, 3]")
        result = _parse_metrics(tmp_path)
        assert result is None


# ---------------------------------------------------------------------------
# TestArtifactScanning
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestArtifactScanning:
    async def test_detects_large_files(self, tmp_path):
        big_file = tmp_path / "model.pt"
        big_file.write_bytes(b"x" * (ARTIFACT_THRESHOLD + 1))
        small_file = tmp_path / "config.json"
        small_file.write_text('{"lr": 0.01}')
        artifacts = _scan_for_artifacts(tmp_path)
        assert len(artifacts) == 1
        assert artifacts[0].name == "model.pt"

    async def test_no_large_files_returns_empty(self, tmp_path):
        (tmp_path / "small.txt").write_text("tiny")
        artifacts = _scan_for_artifacts(tmp_path)
        assert artifacts == []


# ---------------------------------------------------------------------------
# TestWorkspaceCleanup
# ---------------------------------------------------------------------------


class TestWorkspaceCleanup:
    def test_removes_expired_workspaces(self, tmp_path, monkeypatch):
        monkeypatch.setattr("laddr.core.script_executor.WORKSPACE_ROOT", tmp_path)
        old_ws = tmp_path / "old-experiment"
        old_ws.mkdir()
        (old_ws / "data.txt").write_text("old data")
        os.utime(old_ws, (time.time() - 48 * 3600, time.time() - 48 * 3600))
        assert cleanup_workspaces(ttl_hours=24) == 1
        assert not old_ws.exists()

    def test_skips_active_workspaces(self, tmp_path, monkeypatch):
        monkeypatch.setattr("laddr.core.script_executor.WORKSPACE_ROOT", tmp_path)
        ws = tmp_path / "active-exp"
        ws.mkdir()
        (ws / ".active").touch()
        os.utime(ws, (time.time() - 48 * 3600, time.time() - 48 * 3600))
        assert cleanup_workspaces(ttl_hours=24) == 0
        assert ws.exists()

    def test_skips_recent_workspaces(self, tmp_path, monkeypatch):
        monkeypatch.setattr("laddr.core.script_executor.WORKSPACE_ROOT", tmp_path)
        ws = tmp_path / "recent-exp"
        ws.mkdir()
        (ws / "data.txt").write_text("recent")
        assert cleanup_workspaces(ttl_hours=24) == 0
        assert ws.exists()
