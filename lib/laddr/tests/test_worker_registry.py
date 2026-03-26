"""Tests for WorkerRegistry — registration, heartbeat, and queries."""
from __future__ import annotations

import time

import pytest

from laddr.core.worker_registry import WorkerRegistry


CAPABILITIES = {
    "models": [{"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True}],
    "mcps": ["holocron", "context7"],
    "skills": ["web-research", "code-gen"],
    "max_concurrent": 2,
}


class TestWorkerRegistry:
    def setup_method(self):
        self.registry = WorkerRegistry()

    # ------------------------------------------------------------------

    def test_register_worker(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        entry = self.registry.get("w-01")
        assert entry is not None
        assert entry["worker_id"] == "w-01"
        assert entry["node"] == "node-a"
        assert entry["capabilities"] == CAPABILITIES
        assert entry["status"] == "idle"
        assert entry["active_jobs"] == 0
        assert "last_heartbeat" in entry

    def test_heartbeat_updates_timestamp(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        before = self.registry.get("w-01")["last_heartbeat"]
        time.sleep(0.05)
        self.registry.heartbeat("w-01")
        after = self.registry.get("w-01")["last_heartbeat"]
        assert after > before

    def test_heartbeat_reconciles_active_jobs(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.heartbeat("w-01", active_jobs=3)
        entry = self.registry.get("w-01")
        assert entry["active_jobs"] == 3

    def test_list_alive_workers(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.register("w-02", "node-b", CAPABILITIES)
        alive = self.registry.list_alive(max_stale_seconds=60)
        ids = {w["worker_id"] for w in alive}
        assert "w-01" in ids
        assert "w-02" in ids

    def test_deregister(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.deregister("w-01")
        assert self.registry.get("w-01") is None

    def test_set_status(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.set_status("w-01", "draining")
        assert self.registry.get("w-01")["status"] == "draining"

    def test_heartbeat_sets_busy_when_at_max_concurrent(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        # max_concurrent is 2; sending active_jobs=2 should flip to "busy"
        self.registry.heartbeat("w-01", active_jobs=2)
        assert self.registry.get("w-01")["status"] == "busy"

    def test_heartbeat_sets_idle_when_below_max_concurrent(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.heartbeat("w-01", active_jobs=2)
        self.registry.heartbeat("w-01", active_jobs=1)
        assert self.registry.get("w-01")["status"] == "idle"

    def test_heartbeat_does_not_change_draining_status(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        self.registry.set_status("w-01", "draining")
        self.registry.heartbeat("w-01", active_jobs=0)
        assert self.registry.get("w-01")["status"] == "draining"

    def test_list_alive_excludes_stale_workers(self):
        self.registry.register("w-stale", "node-x", CAPABILITIES)
        # Manually backdate the heartbeat so it appears stale
        self.registry._store["w-stale"]["last_heartbeat"] -= 120
        alive = self.registry.list_alive(max_stale_seconds=60)
        ids = {w["worker_id"] for w in alive}
        assert "w-stale" not in ids

    def test_heartbeat_refreshes_models(self):
        self.registry.register("w-01", "node-a", CAPABILITIES)
        new_models = [{"id": "deepseek-r1-32b", "context_window": 32768, "loaded": True}]
        self.registry.heartbeat("w-01", models=new_models)
        entry = self.registry.get("w-01")
        assert entry["capabilities"]["models"] == new_models

    def test_get_unknown_worker_returns_none(self):
        assert self.registry.get("no-such-worker") is None
