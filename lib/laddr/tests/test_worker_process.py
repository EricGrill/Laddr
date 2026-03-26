"""Tests for worker_process — Part A: pure functions."""
from __future__ import annotations

import os
import tempfile

import pytest
import yaml

from laddr.core.worker_process import (
    build_agent_config,
    load_worker_config,
    select_model_for_job,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _model(
    id: str,
    loaded: bool = True,
    context_window: int = 131072,
    provider: str = "lmstudio",
) -> dict:
    return {
        "id": id,
        "provider": provider,
        "context_window": context_window,
        "loaded": loaded,
    }


# ---------------------------------------------------------------------------
# TestSelectModelForJob
# ---------------------------------------------------------------------------


class TestSelectModelForJob:
    def test_selects_required_model(self):
        """When requirements specify explicit model ids, pick a matching one."""
        models = [_model("llama-3.3-70b"), _model("qwen-2.5-coder")]
        reqs = {"models": ["qwen-2.5-coder"]}

        result = select_model_for_job(models, reqs)

        assert result is not None
        assert result["id"] == "qwen-2.5-coder"

    def test_prefers_loaded_model(self):
        """Among matching models, prefer the one that is loaded."""
        models = [
            _model("llama-3.3-70b", loaded=False),
            _model("llama-3.3-70b-alt", loaded=True),
        ]
        reqs = {"model_match": "llama"}

        result = select_model_for_job(models, reqs)

        assert result is not None
        assert result["loaded"] is True
        assert result["id"] == "llama-3.3-70b-alt"

    def test_generic_picks_first_loaded(self):
        """No requirements — picks first loaded model."""
        models = [
            _model("unloaded-model", loaded=False),
            _model("loaded-model", loaded=True),
        ]

        result = select_model_for_job(models, {})

        assert result is not None
        assert result["id"] == "loaded-model"

    def test_returns_none_when_no_models(self):
        """Empty list returns None."""
        result = select_model_for_job([], {})
        assert result is None

    def test_returns_none_when_no_match(self):
        """No model matches requirements → None."""
        models = [_model("llama-3.3-70b")]
        reqs = {"models": ["nonexistent-model"]}

        result = select_model_for_job(models, reqs)
        assert result is None

    def test_min_context_window_filter(self):
        """Models below min_context_window are excluded."""
        models = [
            _model("small", context_window=4096),
            _model("big", context_window=131072),
        ]
        reqs = {"min_context_window": 65536}

        result = select_model_for_job(models, reqs)

        assert result is not None
        assert result["id"] == "big"


# ---------------------------------------------------------------------------
# TestBuildAgentConfig
# ---------------------------------------------------------------------------


class TestBuildAgentConfig:
    def test_maps_job_fields(self):
        """Job payload maps correctly to agent config dict."""
        job = {
            "job_id": "abcdef1234567890",
            "system_prompt": "You are a code reviewer",
            "user_prompt": "Review this PR",
            "backstory": "Senior engineer",
            "max_iterations": 10,
        }

        config = build_agent_config(job, "snoke-01")

        assert config["name"] == "worker-snoke-01-abcdef12"
        assert config["role"] == "worker"
        assert config["goal"] == "You are a code reviewer"
        assert config["backstory"] == "Senior engineer"
        assert config["instructions"] == "Review this PR"
        assert config["max_iterations"] == 10
        assert config["is_coordinator"] is False

    def test_defaults(self):
        """Missing fields get sensible defaults."""
        job = {"job_id": "xyz12345"}

        config = build_agent_config(job, "w-02")

        assert config["name"] == "worker-w-02-xyz12345"
        assert config["role"] == "worker"
        assert config["goal"] == ""
        assert config["backstory"] == ""
        assert config["instructions"] == ""
        assert config["max_iterations"] == 5
        assert config["is_coordinator"] is False


# ---------------------------------------------------------------------------
# TestLoadWorkerConfig
# ---------------------------------------------------------------------------


class TestLoadWorkerConfig:
    def test_loads_yaml(self, tmp_path):
        """Config loads correctly from YAML file."""
        cfg = {
            "node": "snoke",
            "worker_id": "snoke-01",
            "llm": {"provider": "lmstudio", "endpoint": "http://localhost:1234/v1"},
            "max_concurrent": 2,
            "server": {"redis_url": "redis://localhost:6379"},
        }
        config_file = tmp_path / "worker.yml"
        config_file.write_text(yaml.dump(cfg))

        result = load_worker_config(str(config_file))

        assert result["worker_id"] == "snoke-01"
        assert result["llm"]["endpoint"] == "http://localhost:1234/v1"

    def test_missing_file_raises(self):
        """Non-existent path raises FileNotFoundError."""
        with pytest.raises(FileNotFoundError):
            load_worker_config("/tmp/nonexistent_worker_config.yml")
