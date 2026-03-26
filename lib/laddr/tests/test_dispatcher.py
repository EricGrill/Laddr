"""Tests for dispatcher — Part A: synchronous matching logic."""
from __future__ import annotations

import pytest

from laddr.core.dispatcher import Dispatcher
from laddr.core.job_templates import TemplateRegistry
from laddr.core.worker_registry import WorkerRegistry


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_capabilities(
    models: list[dict] | None = None,
    mcps: list[str] | None = None,
    skills: list[str] | None = None,
    max_concurrent: int = 4,
) -> dict:
    if models is None:
        models = [
            {"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True},
        ]
    return {
        "models": models,
        "mcps": mcps or [],
        "skills": skills or [],
        "max_concurrent": max_concurrent,
    }


def _register_worker(
    registry: WorkerRegistry,
    worker_id: str = "w-01",
    node: str = "node-a",
    active_jobs: int = 0,
    **cap_kwargs,
) -> None:
    caps = _make_capabilities(**cap_kwargs)
    registry.register(worker_id, node, caps)
    if active_jobs:
        registry.heartbeat(worker_id, active_jobs=active_jobs)


@pytest.fixture
def worker_registry() -> WorkerRegistry:
    return WorkerRegistry()


@pytest.fixture
def template_registry() -> TemplateRegistry:
    return TemplateRegistry()


@pytest.fixture
def dispatcher(worker_registry, template_registry) -> Dispatcher:
    return Dispatcher(worker_registry, template_registry)


# ---------------------------------------------------------------------------
# Part A tests
# ---------------------------------------------------------------------------


class TestRouteGenericJob:
    """test_route_generic_job — any available worker matches a generic job."""

    def test_generic_job_matches_any_worker(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01")
        job = {"requirements": {"mode": "generic"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-01"

    def test_generic_job_no_requirements_field(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01")
        job = {}  # no requirements at all
        result = dispatcher.find_worker_for_job(job)
        assert result is not None

    def test_generic_job_no_workers(self, dispatcher):
        job = {"requirements": {"mode": "generic"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is None


class TestRouteTemplateJob:
    """test_route_template_job — template requirements resolve and match."""

    def test_template_job_matches_qualified_worker(
        self, dispatcher, worker_registry, template_registry,
    ):
        template_registry.register({
            "name": "code-review",
            "requirements": {"models": ["deepseek-coder-v2"], "mcps": ["github"]},
            "defaults": {"temperature": 0.2},
        })
        _register_worker(
            worker_registry, "w-01",
            models=[{"id": "deepseek-coder-v2", "provider": "lmstudio", "context_window": 65536, "loaded": True}],
            mcps=["github", "filesystem"],
        )
        job = {"requirements": {"mode": "template", "template": "code-review"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-01"

    def test_template_with_overrides(
        self, dispatcher, worker_registry, template_registry,
    ):
        template_registry.register({
            "name": "basic",
            "requirements": {"models": ["llama-3.3-70b"]},
            "defaults": {},
        })
        # Override to require an MCP the worker has
        _register_worker(
            worker_registry, "w-01",
            models=[{"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True}],
            mcps=["filesystem"],
        )
        job = {
            "requirements": {
                "mode": "template",
                "template": "basic",
                "overrides": {"requirements": {"mcps": ["filesystem"]}},
            },
        }
        result = dispatcher.find_worker_for_job(job)
        assert result is not None


class TestRouteTemplateJobNoQualifiedWorker:
    """test_route_template_job_no_qualified_worker — returns None if no match."""

    def test_no_worker_has_required_model(
        self, dispatcher, worker_registry, template_registry,
    ):
        template_registry.register({
            "name": "vision",
            "requirements": {"models": ["llava-1.6"]},
            "defaults": {},
        })
        _register_worker(
            worker_registry, "w-01",
            models=[{"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True}],
        )
        job = {"requirements": {"mode": "template", "template": "vision"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is None

    def test_no_worker_has_required_mcp(
        self, dispatcher, worker_registry, template_registry,
    ):
        template_registry.register({
            "name": "deploy",
            "requirements": {"mcps": ["docker", "ssh"]},
            "defaults": {},
        })
        _register_worker(worker_registry, "w-01", mcps=["filesystem"])
        job = {"requirements": {"mode": "template", "template": "deploy"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is None


class TestRouteExplicitJob:
    """test_route_explicit_job — explicit model+mcp requirements match."""

    def test_explicit_model_and_mcp(self, dispatcher, worker_registry):
        _register_worker(
            worker_registry, "w-01",
            models=[{"id": "gpt-4o", "provider": "openai", "context_window": 128000, "loaded": False}],
            mcps=["browser"],
        )
        job = {
            "requirements": {
                "mode": "explicit",
                "models": ["gpt-4o"],
                "mcps": ["browser"],
            },
        }
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-01"

    def test_explicit_unmet_requirements(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01", mcps=["filesystem"])
        job = {
            "requirements": {
                "mode": "explicit",
                "models": ["claude-3.5-sonnet"],
            },
        }
        result = dispatcher.find_worker_for_job(job)
        assert result is None


class TestLoadBalancing:
    """test_load_balancing — prefers least loaded worker."""

    def test_prefers_least_loaded(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01", active_jobs=3)
        _register_worker(worker_registry, "w-02", active_jobs=1)
        _register_worker(worker_registry, "w-03", active_jobs=2)

        job = {"requirements": {"mode": "generic"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-02"

    def test_skips_fully_loaded_worker(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01", active_jobs=4, max_concurrent=4)
        _register_worker(worker_registry, "w-02", active_jobs=1, max_concurrent=4)

        job = {"requirements": {"mode": "generic"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-02"

    def test_all_workers_at_capacity(self, dispatcher, worker_registry):
        _register_worker(worker_registry, "w-01", active_jobs=4, max_concurrent=4)
        _register_worker(worker_registry, "w-02", active_jobs=4, max_concurrent=4)

        job = {"requirements": {"mode": "generic"}}
        result = dispatcher.find_worker_for_job(job)
        assert result is None

    def test_load_balancing_with_requirements(self, dispatcher, worker_registry):
        """Among qualified workers, still picks least loaded."""
        _register_worker(
            worker_registry, "w-01", active_jobs=3,
            models=[{"id": "deepseek-coder-v2", "provider": "lmstudio", "context_window": 65536, "loaded": True}],
            mcps=["github"],
        )
        _register_worker(
            worker_registry, "w-02", active_jobs=0,
            models=[{"id": "deepseek-coder-v2", "provider": "lmstudio", "context_window": 65536, "loaded": True}],
            mcps=["github"],
        )
        _register_worker(
            worker_registry, "w-03", active_jobs=0,
            models=[{"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True}],
        )

        job = {
            "requirements": {
                "mode": "explicit",
                "models": ["deepseek-coder-v2"],
                "mcps": ["github"],
            },
        }
        result = dispatcher.find_worker_for_job(job)
        assert result is not None
        assert result["worker_id"] == "w-02"
