"""Integration tests for script execution — end-to-end flow through worker_process."""
from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path

import pytest

from laddr.core.worker_process import _execute_script_job


@pytest.mark.asyncio
class TestScriptJobIntegration:
    async def test_full_script_job_with_metrics(self):
        """Complete flow: run script, write metrics, verify result."""
        exp_id = f"integration-{uuid.uuid4().hex[:8]}"
        script = (
            "echo 'training started' && "
            'echo \'{"loss": 0.15, "accuracy": 0.95}\' > metrics.json && '
            "echo 'training complete'"
        )
        job = {
            "job_id": str(uuid.uuid4()),
            "task_type": "script",
            "command": script,
            "timeout_seconds": 30,
            "experiment_id": exp_id,
        }
        try:
            result = await _execute_script_job(job)
            assert result["status"] == "success"
            assert result["exit_code"] == 0
            assert "training started" in result["stdout"]
            assert "training complete" in result["stdout"]
            assert result["metrics"] is not None
            assert result["metrics"]["loss"] == 0.15
            assert result["metrics"]["accuracy"] == 0.95
        finally:
            shutil.rmtree(Path.home() / ".laddr" / "workspaces" / exp_id, ignore_errors=True)

    async def test_script_job_without_command_fails(self):
        """A script job missing 'command' returns error."""
        result = await _execute_script_job({"job_id": "no-cmd", "task_type": "script"})
        assert result["status"] == "error"
        assert "No command" in result["stderr"]

    async def test_script_job_workspace_reuse(self):
        """Two sequential script jobs share workspace via experiment_id."""
        exp_id = f"reuse-{uuid.uuid4().hex[:8]}"
        try:
            await _execute_script_job({
                "job_id": str(uuid.uuid4()), "task_type": "script",
                "command": "echo 'step1' > state.txt", "experiment_id": exp_id,
            })
            result = await _execute_script_job({
                "job_id": str(uuid.uuid4()), "task_type": "script",
                "command": "cat state.txt", "experiment_id": exp_id,
            })
            assert result["status"] == "success"
            assert "step1" in result["stdout"]
        finally:
            shutil.rmtree(Path.home() / ".laddr" / "workspaces" / exp_id, ignore_errors=True)
