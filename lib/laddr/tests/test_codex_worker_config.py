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
