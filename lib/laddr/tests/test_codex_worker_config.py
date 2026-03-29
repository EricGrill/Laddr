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


class TestCodexCapabilityBuilding:
    """Simulate WorkerProcess._build_capabilities with codex config."""

    def test_cloud_only_worker_has_no_local_models(self):
        config = _load_config("codex.yml")
        # WorkerProcess sets llm_endpoint from config.llm.endpoint
        llm_endpoint = config.get("llm", {}).get("endpoint")
        assert llm_endpoint is None
        # This means _models stays empty — no LM Studio discovery

    def test_build_capabilities_includes_cloud_models(self):
        config = _load_config("codex.yml")
        cloud_providers = config.get("cloud_providers", [])

        # Simulate _build_capabilities logic (worker_process.py:688-708)
        local_models = []  # no llm_endpoint means no local models
        all_models = list(local_models)
        for provider in cloud_providers:
            for m in provider.get("models", []):
                model_entry = dict(m)
                model_entry.setdefault("provider", provider.get("name", "cloud"))
                model_entry.setdefault("loaded", True)
                all_models.append(model_entry)

        capabilities = {
            "worker_id": config["worker_id"],
            "node": config["node"],
            "models": all_models,
            "mcps": config.get("mcps", []),
            "skills": config.get("skills", []),
            "max_concurrent": config.get("max_concurrent", 2),
            "active_jobs": 0,
        }

        assert capabilities["worker_id"] == "codex-01"
        assert len(capabilities["models"]) == 5
        model_ids = [m["id"] for m in capabilities["models"]]
        assert "gpt-5.4" in model_ids
        assert "o3" in model_ids
        assert all(m["provider"] == "openai" for m in capabilities["models"])
        assert "coding" in capabilities["skills"]

    def test_capability_matcher_accepts_codex_worker(self):
        """The existing capability matcher should match codex-01 for OpenAI model jobs."""
        from laddr.core.capability_matcher import matches_requirements

        config = _load_config("codex.yml")
        cloud_providers = config.get("cloud_providers", [])

        # Build models the same way WorkerProcess does
        all_models = []
        for provider in cloud_providers:
            for m in provider.get("models", []):
                model_entry = dict(m)
                model_entry.setdefault("provider", provider.get("name", "cloud"))
                model_entry.setdefault("loaded", True)
                all_models.append(model_entry)

        worker = {
            "worker_id": "codex-01",
            "capabilities": {
                "models": all_models,
                "mcps": [],
                "skills": config.get("skills", []),
                "max_concurrent": 5,
            },
            "active_jobs": 0,
        }

        # Should match a job requesting gpt-5.4
        assert matches_requirements(worker, {"models": ["gpt-5.4"]}) is True
        # Should match a job requesting coding skill
        assert matches_requirements(worker, {"skills": ["coding"]}) is True
        # Should NOT match a job requesting a model we don't have
        assert matches_requirements(worker, {"models": ["llama-3.3-70b"]}) is False
