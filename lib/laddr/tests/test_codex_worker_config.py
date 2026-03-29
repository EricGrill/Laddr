# lib/laddr/tests/test_codex_worker_config.py
"""Tests for worker config loading and capability building."""
from __future__ import annotations

import yaml
import pathlib

DEPLOY_DIR = pathlib.Path(__file__).resolve().parents[3] / "deploy" / "workers"


def _load_config(name: str) -> dict:
    """Load a worker YAML config by filename."""
    path = DEPLOY_DIR / name
    with open(path) as fh:
        return yaml.safe_load(fh)


class TestVeniceConfig:
    def test_venice_uses_cloud_providers(self):
        config = _load_config("venice.yml")
        assert "cloud_providers" in config, "venice.yml must use cloud_providers, not top-level models"
        providers = config["cloud_providers"]
        assert len(providers) >= 1
        models = providers[0].get("models", [])
        assert len(models) >= 1
        assert models[0]["id"] == "llama-3.3-70b"

    def test_venice_no_toplevel_models(self):
        config = _load_config("venice.yml")
        assert "models" not in config, "top-level models key is not read by WorkerProcess"


class TestCodexPushConfig:
    def test_codex_uses_cloud_providers(self):
        config = _load_config("codex.yml")
        assert "cloud_providers" in config
        providers = config["cloud_providers"]
        assert len(providers) >= 1
        assert providers[0]["name"] == "openai"

    def test_codex_no_llm_endpoint(self):
        """No llm.endpoint means LM Studio discovery is skipped."""
        config = _load_config("codex.yml")
        llm_endpoint = config.get("llm", {}).get("endpoint")
        assert llm_endpoint is None, "codex.yml should not have llm.endpoint — cloud-only worker"

    def test_codex_has_expected_models(self):
        config = _load_config("codex.yml")
        models = config["cloud_providers"][0]["models"]
        model_ids = [m["id"] for m in models]
        assert "gpt-5.4" in model_ids
        assert "o3" in model_ids
        assert "o4-mini" in model_ids
        assert "gpt-4.1" in model_ids
        assert "gpt-4.1-mini" in model_ids

    def test_codex_has_expected_skills(self):
        config = _load_config("codex.yml")
        skills = config.get("skills", [])
        for expected in ["coding", "code-review", "refactoring", "debugging", "testing", "devops"]:
            assert expected in skills, f"Missing skill: {expected}"

    def test_codex_worker_id(self):
        config = _load_config("codex.yml")
        assert config["worker_id"] == "codex-01"
        assert config["node"] == "snoke"
