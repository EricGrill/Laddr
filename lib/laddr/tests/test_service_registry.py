"""Tests for ServiceRegistry — config loading, discovery, and playbook building."""
from __future__ import annotations

import asyncio
import json
import time
import textwrap
from pathlib import Path

import pytest
import yaml

from laddr.core.service_registry import ServiceRegistry, ServiceDefinition


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SAMPLE_CONFIG = {
    "services": [
        {
            "id": "test-images",
            "name": "Test Image Generation",
            "category": "creative",
            "icon": "🎨",
            "description": "Generate test images.",
            "mcp": "nano-banana",
            "tools": ["generate_image", "generate_blog_images"],
            "playbook": "Use for image tasks.",
        },
        {
            "id": "test-knowledge",
            "name": "Test Knowledge Base",
            "category": "data",
            "icon": "📚",
            "description": "Persistent storage.",
            "mcp": "holocron",
            "tools": ["knowledge_search", "knowledge_get"],
            "playbook": "Use for knowledge tasks.",
        },
    ]
}


@pytest.fixture
def sample_config(tmp_path: Path) -> Path:
    config_file = tmp_path / "services.yml"
    config_file.write_text(yaml.dump(SAMPLE_CONFIG))
    return config_file


@pytest.fixture
def registry(sample_config: Path) -> ServiceRegistry:
    return ServiceRegistry(sample_config)


# ---------------------------------------------------------------------------
# FakeRedis
# ---------------------------------------------------------------------------


class FakeRedis:
    """Minimal async Redis stub for testing."""

    def __init__(self, data: dict[str, dict]) -> None:
        # data: {worker_id: worker_dict}
        self._data = data

    async def hgetall(self, key: str) -> dict[bytes, bytes]:
        return {
            k.encode(): json.dumps(v).encode()
            for k, v in self._data.items()
        }


@pytest.fixture
def redis_with_workers() -> FakeRedis:
    now = time.time()
    return FakeRedis(
        {
            "worker-1": {
                "mcps": ["nano-banana", "holocron"],
                "last_heartbeat": now - 10,  # fresh
            },
            "worker-2": {
                "mcps": [],
                "last_heartbeat": now - 5,
            },
        }
    )


@pytest.fixture
def redis_no_workers() -> FakeRedis:
    return FakeRedis({})


@pytest.fixture
def redis_stale_worker() -> FakeRedis:
    return FakeRedis(
        {
            "worker-old": {
                "mcps": ["nano-banana", "holocron"],
                "last_heartbeat": time.time() - 200,  # stale
            }
        }
    )


# ---------------------------------------------------------------------------
# Task 2: Config loading tests
# ---------------------------------------------------------------------------


class TestServiceRegistryConfigLoading:
    def test_loads_services_from_yaml(self, registry: ServiceRegistry):
        services = registry.get_all()
        assert len(services) == 2
        ids = {s.id for s in services}
        assert ids == {"test-images", "test-knowledge"}

    def test_get_by_id(self, registry: ServiceRegistry):
        svc = registry.get("test-images")
        assert svc is not None
        assert svc.name == "Test Image Generation"
        assert svc.mcp == "nano-banana"
        assert svc.category == "creative"

    def test_get_unknown_returns_none(self, registry: ServiceRegistry):
        assert registry.get("does-not-exist") is None

    def test_get_by_category(self, registry: ServiceRegistry):
        creative = registry.get_by_category("creative")
        assert len(creative) == 1
        assert creative[0].id == "test-images"

        data = registry.get_by_category("data")
        assert len(data) == 1
        assert data[0].id == "test-knowledge"

    def test_all_services_start_unavailable(self, registry: ServiceRegistry):
        for svc in registry.get_all():
            assert svc.available is False

    def test_tools_loaded_from_config(self, registry: ServiceRegistry):
        svc = registry.get("test-images")
        assert "generate_image" in svc.tools
        assert "generate_blog_images" in svc.tools


# ---------------------------------------------------------------------------
# Task 3: Discovery tests
# ---------------------------------------------------------------------------


class TestServiceRegistryDiscovery:
    def test_discover_marks_services_available(
        self, registry: ServiceRegistry, redis_with_workers: FakeRedis
    ):
        asyncio.get_event_loop().run_until_complete(
            registry.discover(redis_with_workers)
        )
        assert registry.get("test-images").available is True
        assert registry.get("test-knowledge").available is True
        assert registry.last_discovered is not None

    def test_discover_no_workers_marks_unavailable(
        self, registry: ServiceRegistry, redis_no_workers: FakeRedis
    ):
        asyncio.get_event_loop().run_until_complete(
            registry.discover(redis_no_workers)
        )
        for svc in registry.get_all():
            assert svc.available is False

    def test_discover_stale_worker_ignored(
        self, registry: ServiceRegistry, redis_stale_worker: FakeRedis
    ):
        asyncio.get_event_loop().run_until_complete(
            registry.discover(redis_stale_worker)
        )
        for svc in registry.get_all():
            assert svc.available is False


# ---------------------------------------------------------------------------
# Task 4: Playbook builder tests
# ---------------------------------------------------------------------------


@pytest.fixture
def available_registry(registry: ServiceRegistry, redis_with_workers: FakeRedis) -> ServiceRegistry:
    """Registry with both test services marked available."""
    asyncio.get_event_loop().run_until_complete(
        registry.discover(redis_with_workers)
    )
    return registry


class TestPlaybookBuilder:
    def test_build_playbook_all_available(self, available_registry: ServiceRegistry):
        playbook = available_registry.build_playbook({})
        assert "# Available Platform Services" in playbook
        assert "Test Image Generation" in playbook
        assert "Test Knowledge Base" in playbook

    def test_filters_by_services(self, available_registry: ServiceRegistry):
        playbook = available_registry.build_playbook({"services": ["test-images"]})
        assert "Test Image Generation" in playbook
        assert "Test Knowledge Base" not in playbook

    def test_filters_by_mcps(self, available_registry: ServiceRegistry):
        playbook = available_registry.build_playbook(
            {"requirements": {"mcps": ["holocron"]}}
        )
        assert "Test Knowledge Base" in playbook
        assert "Test Image Generation" not in playbook

    def test_empty_when_none_available(self, registry: ServiceRegistry):
        # No discovery — all services are unavailable
        playbook = registry.build_playbook({})
        assert playbook == ""

    def test_includes_playbook_content(self, available_registry: ServiceRegistry):
        playbook = available_registry.build_playbook({"services": ["test-images"]})
        assert "Use for image tasks." in playbook

    def test_filters_by_services_unavailable_excluded(
        self, registry: ServiceRegistry
    ):
        """Requesting an unavailable service returns empty string."""
        playbook = registry.build_playbook({"services": ["test-images"]})
        assert playbook == ""

    def test_requirements_as_json_string(self, available_registry: ServiceRegistry):
        """requirements can be a JSON string."""
        requirements_str = json.dumps({"mcps": ["nano-banana"]})
        playbook = available_registry.build_playbook({"requirements": requirements_str})
        assert "Test Image Generation" in playbook
        assert "Test Knowledge Base" not in playbook


class TestPlaybookInjection:
    def test_playbook_prepended_to_system_prompt(
        self, available_registry: ServiceRegistry
    ):
        job = {
            "system_prompt": "You are a helpful assistant.",
            "services": ["test-images"],
        }
        playbook = available_registry.build_playbook(job)
        assert playbook  # non-empty
        injected = playbook + "\n\n" + job["system_prompt"]
        assert injected.startswith("# Available Platform Services")
        assert "You are a helpful assistant." in injected

    def test_no_playbook_leaves_prompt_unchanged(self, registry: ServiceRegistry):
        job = {
            "system_prompt": "You are a helpful assistant.",
        }
        playbook = registry.build_playbook(job)
        assert playbook == ""
        # No injection when empty
        final_prompt = (playbook + "\n\n" + job["system_prompt"]).lstrip("\n")
        # with empty playbook the result should just be the original prompt
        assert "You are a helpful assistant." in final_prompt
