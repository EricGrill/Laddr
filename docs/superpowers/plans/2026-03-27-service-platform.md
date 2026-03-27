# Service Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a centralized service registry that auto-discovers MCP tools from worker heartbeats, merges with human-authored playbooks, injects service catalogs into agent prompts, and exposes a dashboard UI for operator visibility and job submission.

**Architecture:** A `ServiceRegistry` singleton loads service definitions from `services.yml`, checks worker heartbeats in Redis for MCP availability, and serves the merged catalog via new `/api/services` endpoints. The API injects playbooks into job payloads before dispatching. A new dashboard Services page shows the catalog with job submission and playbook viewing.

**Tech Stack:** Python/FastAPI (backend), React/TypeScript (dashboard), Redis (worker data), YAML (config), React Query (data fetching)

**Spec:** `docs/superpowers/specs/2026-03-27-service-platform-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `lib/laddr/src/laddr/core/service_registry.py` | Service registry singleton — loads YAML, reads Redis, builds catalog, generates playbooks |
| `lib/laddr/src/laddr/config/services.yml` | Service definitions with playbooks, categories, tool lists |
| `lib/laddr/tests/test_service_registry.py` | Unit tests for registry: config loading, availability, playbook builder |
| `lib/laddr/tests/test_api_services.py` | API tests for `/api/services` endpoints |
| `dashboard/src/pages/Services.tsx` | Services catalog page with card grid, filters, modals |
| `dashboard/src/lib/queries/services.ts` | React Query hooks for services API |

### Modified Files

| File | Change |
|------|--------|
| `lib/laddr/src/laddr/api/main.py` | Add `/api/services` endpoints, inject playbook at job submission, init registry in `lifespan()` |
| `dashboard/src/components/Sidebar.tsx` | Add "Services" nav link |
| `dashboard/src/App.tsx` | Add route for `/services` |
| `dashboard/src/lib/api.ts` | Add service API functions (if not using React Query directly) |

---

## Task 1: Service Configuration File

**Files:**
- Create: `lib/laddr/src/laddr/config/services.yml`

This is the static config file that defines all services with their playbooks. No tests needed — it's pure data.

- [ ] **Step 1: Create the config directory**

```bash
mkdir -p lib/laddr/src/laddr/config
```

- [ ] **Step 2: Write services.yml**

Create `lib/laddr/src/laddr/config/services.yml` with the full service catalog. Each entry has: `id`, `name`, `category`, `icon`, `description`, `mcp`, `tools`, `playbook`.

Include all 7 services from the spec:
- `image-generation` (nano-banana) — category: creative
- `knowledge-base` (holocron) — category: data
- `plans` (holocron) — category: data
- `deployments` (holocron) — category: ops
- `job-orchestration` (holocron) — category: ops
- `system-operations` (holocron) — category: system
- `qa` (holocron) — category: system

Copy the full playbook content from the spec (`docs/superpowers/specs/2026-03-27-service-platform-design.md`, Section 2: Service Configuration).

- [ ] **Step 3: Commit**

```bash
git add -f lib/laddr/src/laddr/config/services.yml
git commit -m "feat: add services.yml config with 7 service definitions and playbooks"
```

---

## Task 2: Service Registry — Core Module

**Files:**
- Create: `lib/laddr/src/laddr/core/service_registry.py`
- Test: `lib/laddr/tests/test_service_registry.py`

The registry loads YAML config, checks Redis for worker MCP availability, and serves the merged catalog.

- [ ] **Step 1: Write failing test for config loading**

Create `lib/laddr/tests/test_service_registry.py`:

```python
import os
import pytest
import yaml
from pathlib import Path


@pytest.fixture
def sample_config(tmp_path):
    """Create a minimal services.yml for testing."""
    config = {
        "services": [
            {
                "id": "test-images",
                "name": "Test Images",
                "category": "creative",
                "icon": "🎨",
                "description": "Test image generation service.",
                "mcp": "nano-banana",
                "tools": ["generate_image"],
                "playbook": "## When to use\nUse for image generation.\n",
            },
            {
                "id": "test-knowledge",
                "name": "Test Knowledge",
                "category": "data",
                "icon": "📚",
                "description": "Test knowledge base.",
                "mcp": "holocron",
                "tools": ["knowledge_search", "knowledge_get"],
                "playbook": "## When to use\nUse for searching knowledge.\n",
            },
        ]
    }
    config_path = tmp_path / "services.yml"
    config_path.write_text(yaml.dump(config))
    return str(config_path)


class TestServiceRegistryConfigLoading:
    def test_loads_services_from_yaml(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        services = registry.get_all()
        assert len(services) == 2

    def test_get_by_id(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        svc = registry.get("test-images")
        assert svc is not None
        assert svc.name == "Test Images"
        assert svc.mcp == "nano-banana"
        assert svc.category == "creative"

    def test_get_unknown_returns_none(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        assert registry.get("nonexistent") is None

    def test_get_by_category(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        creative = registry.get_by_category("creative")
        assert len(creative) == 1
        assert creative[0].id == "test-images"

    def test_all_services_start_unavailable(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        for svc in registry.get_all():
            assert svc.available is False

    def test_tools_loaded_from_config(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config)
        svc = registry.get("test-knowledge")
        assert svc.tools == ["knowledge_search", "knowledge_get"]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py -v
```

Expected: `ModuleNotFoundError: No module named 'laddr.core.service_registry'`

- [ ] **Step 3: Implement ServiceRegistry with config loading**

Create `lib/laddr/src/laddr/core/service_registry.py`:

```python
"""Centralized service registry.

Loads service definitions from a YAML config file and merges with
dynamic MCP availability from worker heartbeats in Redis.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


@dataclass
class ServiceDefinition:
    """A platform service with its metadata and playbook."""

    id: str
    name: str
    category: str
    icon: str
    description: str
    mcp: str
    playbook: str
    tools: list[str]
    available: bool = False
    tool_schemas: dict[str, Any] = field(default_factory=dict)


class ServiceRegistry:
    """Centralized service catalog.

    Loads service definitions from YAML config. Availability is determined
    by checking which MCPs are reported by alive workers in Redis.
    """

    def __init__(self, config_path: str, redis_client: Any = None) -> None:
        self._config_path = config_path
        self._redis = redis_client
        self._services: dict[str, ServiceDefinition] = {}
        self.last_discovered: str | None = None
        self._load_config()

    def _load_config(self) -> None:
        """Load service definitions from YAML config."""
        path = Path(self._config_path)
        if not path.exists():
            logger.warning("Services config not found: %s", self._config_path)
            return

        with open(path) as f:
            data = yaml.safe_load(f)

        if not data or "services" not in data:
            logger.warning("No services defined in %s", self._config_path)
            return

        services = {}
        for entry in data["services"]:
            svc = ServiceDefinition(
                id=entry["id"],
                name=entry["name"],
                category=entry.get("category", "other"),
                icon=entry.get("icon", ""),
                description=entry.get("description", ""),
                mcp=entry["mcp"],
                playbook=entry.get("playbook", ""),
                tools=entry.get("tools", []),
                available=False,
            )
            services[svc.id] = svc

        self._services = services
        logger.info("Loaded %d service definitions from %s", len(services), self._config_path)

    def get_all(self) -> list[ServiceDefinition]:
        """Return all services."""
        return list(self._services.values())

    def get(self, service_id: str) -> ServiceDefinition | None:
        """Return a service by ID, or None."""
        return self._services.get(service_id)

    def get_available(self) -> list[ServiceDefinition]:
        """Return only available services."""
        return [s for s in self._services.values() if s.available]

    def get_by_category(self, category: str) -> list[ServiceDefinition]:
        """Return services matching a category."""
        return [s for s in self._services.values() if s.category == category]
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py -v
```

Expected: All 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/laddr/src/laddr/core/service_registry.py lib/laddr/tests/test_service_registry.py
git commit -m "feat: ServiceRegistry core module with config loading and query methods"
```

---

## Task 3: Service Registry — Availability Discovery from Redis

**Files:**
- Modify: `lib/laddr/src/laddr/core/service_registry.py`
- Modify: `lib/laddr/tests/test_service_registry.py`

Add the `discover()` method that reads worker heartbeats from Redis to determine which MCPs are online.

- [ ] **Step 1: Write failing test for availability discovery**

Add to `lib/laddr/tests/test_service_registry.py`:

```python
import json
import asyncio


class FakeRedis:
    """Minimal fake Redis client for testing."""

    def __init__(self, registry_data: dict[str, str] | None = None):
        self._registry = registry_data or {}

    async def hgetall(self, key: str) -> dict:
        return {k.encode(): v.encode() for k, v in self._registry.items()}


@pytest.fixture
def redis_with_workers():
    """Redis with two workers: one has nano-banana, one has holocron."""
    return FakeRedis({
        "worker-1": json.dumps({
            "worker_id": "worker-1",
            "node": "snoke",
            "mcps": ["nano-banana", "holocron"],
            "last_heartbeat": 9999999999,  # far future = alive
        }),
        "worker-2": json.dumps({
            "worker_id": "worker-2",
            "node": "venice",
            "mcps": [],
            "last_heartbeat": 9999999999,
        }),
    })


@pytest.fixture
def redis_no_workers():
    """Redis with no workers."""
    return FakeRedis({})


class TestServiceRegistryDiscovery:
    def test_discover_marks_services_available(self, sample_config, redis_with_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_with_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        images = registry.get("test-images")
        assert images.available is True  # worker-1 has nano-banana

        knowledge = registry.get("test-knowledge")
        assert knowledge.available is True  # worker-1 has holocron

    def test_discover_no_workers_marks_unavailable(self, sample_config, redis_no_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_no_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        for svc in registry.get_all():
            assert svc.available is False

    def test_discover_stale_worker_ignored(self, sample_config):
        from laddr.core.service_registry import ServiceRegistry

        redis = FakeRedis({
            "stale-worker": json.dumps({
                "worker_id": "stale-worker",
                "mcps": ["nano-banana"],
                "last_heartbeat": 0,  # epoch = very stale
            }),
        })
        registry = ServiceRegistry(config_path=sample_config, redis_client=redis)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        assert registry.get("test-images").available is False
```

- [ ] **Step 2: Run tests to verify new tests fail**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py::TestServiceRegistryDiscovery -v
```

Expected: `AttributeError: 'ServiceRegistry' object has no attribute 'discover'`

- [ ] **Step 3: Implement discover() method**

Add to `ServiceRegistry` in `lib/laddr/src/laddr/core/service_registry.py`:

```python
import json
import time
from datetime import datetime, timezone

# Add to __init__:
#   self.last_discovered: str | None = None

# Add these methods to the ServiceRegistry class:

async def discover(self) -> None:
    """Check worker heartbeats in Redis to determine MCP availability.

    Re-reads the YAML config first (supports hot-reload), then checks
    which MCPs are reported by alive workers.
    """
    self._load_config()

    if not self._redis:
        logger.warning("No Redis client — all services marked unavailable")
        return

    # Get alive MCPs from worker heartbeats
    alive_mcps: set[str] = set()
    try:
        raw = await self._redis.hgetall("laddr:workers:registry")
        cutoff = time.time() - 90  # 90s stale threshold (heartbeat is every 30s)
        for _worker_id, data in raw.items():
            val = data.decode() if isinstance(data, bytes) else data
            try:
                worker = json.loads(val)
            except (json.JSONDecodeError, TypeError):
                continue
            if worker.get("last_heartbeat", 0) < cutoff:
                continue
            for mcp_name in worker.get("mcps", []):
                alive_mcps.add(mcp_name)
    except Exception:
        logger.exception("Failed to read worker registry from Redis")
        return

    # Update availability based on alive MCPs
    for svc in self._services.values():
        was_available = svc.available
        svc.available = svc.mcp in alive_mcps
        if svc.available != was_available:
            status = "available" if svc.available else "unavailable"
            logger.info("Service '%s' is now %s (mcp: %s)", svc.id, status, svc.mcp)

    self.last_discovered = datetime.now(timezone.utc).isoformat()

async def refresh(self) -> None:
    """Force re-read config and re-check availability."""
    await self.discover()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py -v
```

Expected: All 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/laddr/src/laddr/core/service_registry.py lib/laddr/tests/test_service_registry.py
git commit -m "feat: ServiceRegistry.discover() reads worker heartbeats for MCP availability"
```

---

## Task 4: Service Registry — Playbook Builder

**Files:**
- Modify: `lib/laddr/src/laddr/core/service_registry.py`
- Modify: `lib/laddr/tests/test_service_registry.py`

Add `build_playbook()` that generates the prompt injection block for agents.

- [ ] **Step 1: Write failing test for playbook builder**

Add to `lib/laddr/tests/test_service_registry.py`:

```python
class TestPlaybookBuilder:
    def _make_registry_with_availability(self, sample_config, redis_with_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_with_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())
        return registry

    def test_build_playbook_all_available(self, sample_config, redis_with_workers):
        registry = self._make_registry_with_availability(sample_config, redis_with_workers)
        playbook = registry.build_playbook({})

        assert "# Available Platform Services" in playbook
        assert "Test Images" in playbook
        assert "Test Knowledge" in playbook
        assert "nano-banana" in playbook

    def test_build_playbook_filters_by_services(self, sample_config, redis_with_workers):
        registry = self._make_registry_with_availability(sample_config, redis_with_workers)
        playbook = registry.build_playbook({"services": ["test-images"]})

        assert "Test Images" in playbook
        assert "Test Knowledge" not in playbook

    def test_build_playbook_filters_by_mcps(self, sample_config, redis_with_workers):
        registry = self._make_registry_with_availability(sample_config, redis_with_workers)
        playbook = registry.build_playbook({"requirements": {"mcps": ["holocron"]}})

        assert "Test Knowledge" in playbook
        assert "Test Images" not in playbook

    def test_build_playbook_empty_when_none_available(self, sample_config, redis_no_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_no_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())
        playbook = registry.build_playbook({})

        assert playbook == ""

    def test_playbook_includes_playbook_content(self, sample_config, redis_with_workers):
        registry = self._make_registry_with_availability(sample_config, redis_with_workers)
        playbook = registry.build_playbook({"services": ["test-images"]})

        assert "## When to use" in playbook
        assert "Use for image generation." in playbook
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py::TestPlaybookBuilder -v
```

Expected: `AttributeError: 'ServiceRegistry' object has no attribute 'build_playbook'`

- [ ] **Step 3: Implement build_playbook()**

Add to `ServiceRegistry` in `lib/laddr/src/laddr/core/service_registry.py`:

```python
def build_playbook(self, job: dict) -> str:
    """Build the prompt injection block for a job's available services.

    Filtering priority:
    1. If job has ``services`` list, inject only those.
    2. If job has ``requirements.mcps``, inject services matching those MCPs.
    3. Otherwise, inject all available services.
    """
    requested_ids = job.get("services", [])
    if requested_ids:
        services = [s for s in (self.get(sid) for sid in requested_ids) if s and s.available]
    else:
        requirements = job.get("requirements", {})
        if isinstance(requirements, str):
            try:
                requirements = json.loads(requirements)
            except (json.JSONDecodeError, TypeError):
                requirements = {}
        required_mcps = requirements.get("mcps", [])
        if required_mcps:
            services = [s for s in self.get_available() if s.mcp in required_mcps]
        else:
            services = self.get_available()

    if not services:
        return ""

    sections = ["# Available Platform Services\n"]
    sections.append(
        "You have access to the following services via MCP tools. "
        "Use them when your task requires their capabilities.\n"
    )

    for svc in services:
        sections.append(f"---\n\n## {svc.icon} {svc.name} ({svc.mcp})\n")
        sections.append(f"{svc.description}\n")
        sections.append(svc.playbook)
        sections.append("")

    return "\n".join(sections)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py -v
```

Expected: All 14 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/laddr/src/laddr/core/service_registry.py lib/laddr/tests/test_service_registry.py
git commit -m "feat: ServiceRegistry.build_playbook() generates agent prompt injection"
```

---

## Task 5: API Endpoints for Services

**Files:**
- Modify: `lib/laddr/src/laddr/api/main.py` (add endpoints + registry init in lifespan)
- Create: `lib/laddr/tests/test_api_services.py`

Add `/api/services` endpoints and initialize the registry at API startup.

- [ ] **Step 1: Write failing API tests**

Create `lib/laddr/tests/test_api_services.py`:

```python
"""Tests for /api/services endpoints."""

import json
import pytest
import yaml
from unittest.mock import AsyncMock, patch


@pytest.fixture
def sample_services_config(tmp_path):
    config = {
        "services": [
            {
                "id": "test-images",
                "name": "Test Images",
                "category": "creative",
                "icon": "🎨",
                "description": "Image generation.",
                "mcp": "nano-banana",
                "tools": ["generate_image"],
                "playbook": "Use for images.\n",
            },
        ]
    }
    path = tmp_path / "services.yml"
    path.write_text(yaml.dump(config))
    return str(path)


class TestServicesAPI:
    """Test /api/services endpoints.

    These tests import the registry and test its serialization to API
    response format, since full API integration tests require the full
    FastAPI app setup.
    """

    def test_registry_to_api_response_format(self, sample_services_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_services_config)
        services = registry.get_all()

        # Verify the data can be serialized to the expected API response shape
        response = {
            "services": [
                {
                    "id": s.id,
                    "name": s.name,
                    "category": s.category,
                    "icon": s.icon,
                    "description": s.description,
                    "mcp": s.mcp,
                    "tools": s.tools,
                    "available": s.available,
                }
                for s in services
            ],
            "summary": {
                "total": len(services),
                "available": sum(1 for s in services if s.available),
                "unavailable": sum(1 for s in services if not s.available),
            },
        }

        assert response["summary"]["total"] == 1
        assert response["services"][0]["id"] == "test-images"
        # Verify it's JSON-serializable
        json.dumps(response)

    def test_single_service_includes_playbook(self, sample_services_config):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_services_config)
        svc = registry.get("test-images")

        detail = {
            "id": svc.id,
            "name": svc.name,
            "playbook": svc.playbook,
            "tool_schemas": svc.tool_schemas,
        }

        assert "Use for images" in detail["playbook"]
        json.dumps(detail)
```

- [ ] **Step 2: Run tests to verify they pass** (these test serialization, not endpoints)

```bash
cd lib/laddr && python -m pytest tests/test_api_services.py -v
```

Expected: PASS (these validate the data shape, not the HTTP layer).

- [ ] **Step 3: Add registry initialization to API lifespan**

In `lib/laddr/src/laddr/api/main.py`, add the registry import and initialization.

After the existing global variables (around line 164), add:

```python
from laddr.core.service_registry import ServiceRegistry

service_registry: ServiceRegistry | None = None
```

Inside the `lifespan()` function (around line 197, after `set_mc_deps`), add:

```python
    # Initialize service registry
    global service_registry
    import importlib.resources
    config_path = str(Path(__file__).resolve().parent.parent / "config" / "services.yml")
    service_registry = ServiceRegistry(config_path=config_path, redis_client=redis_client)
    try:
        await service_registry.discover()
    except Exception:
        logger.warning("Initial service discovery failed — services may show as unavailable")

    # Start periodic refresh task
    async def _refresh_services():
        while True:
            await asyncio.sleep(60)
            try:
                await service_registry.refresh()
            except Exception:
                logger.exception("Service registry refresh failed")

    refresh_task = asyncio.create_task(_refresh_services())
```

After the `yield` (in the shutdown section), add:

```python
    refresh_task.cancel()
```

- [ ] **Step 4: Add /api/services endpoints**

Add these endpoints to `lib/laddr/src/laddr/api/main.py` (after the existing `/api/workers` endpoints, around line 2670):

```python
@app.get("/api/services", dependencies=[require_api_key])
async def list_services():
    """List all platform services with availability status."""
    if not service_registry:
        raise HTTPException(status_code=503, detail="Service registry not initialized")

    services = service_registry.get_all()
    return {
        "services": [
            {
                "id": s.id,
                "name": s.name,
                "category": s.category,
                "icon": s.icon,
                "description": s.description,
                "mcp": s.mcp,
                "tools": s.tools,
                "available": s.available,
            }
            for s in services
        ],
        "summary": {
            "total": len(services),
            "available": sum(1 for s in services if s.available),
            "unavailable": sum(1 for s in services if not s.available),
            "last_discovered": service_registry.last_discovered,
        },
    }


@app.get("/api/services/{service_id}", dependencies=[require_api_key])
async def get_service(service_id: str):
    """Get a single service with full playbook and tool schemas."""
    if not service_registry:
        raise HTTPException(status_code=503, detail="Service registry not initialized")

    svc = service_registry.get(service_id)
    if not svc:
        raise HTTPException(status_code=404, detail=f"Service not found: {service_id}")

    return {
        "id": svc.id,
        "name": svc.name,
        "category": svc.category,
        "icon": svc.icon,
        "description": svc.description,
        "mcp": svc.mcp,
        "playbook": svc.playbook,
        "tools": svc.tools,
        "available": svc.available,
        "tool_schemas": svc.tool_schemas,
    }


@app.get("/api/services/{service_id}/tools", dependencies=[require_api_key])
async def get_service_tools(service_id: str):
    """Get tool schemas for a service."""
    if not service_registry:
        raise HTTPException(status_code=503, detail="Service registry not initialized")

    svc = service_registry.get(service_id)
    if not svc:
        raise HTTPException(status_code=404, detail=f"Service not found: {service_id}")

    return {"service_id": svc.id, "tools": svc.tools, "tool_schemas": svc.tool_schemas}


@app.post("/api/services/refresh", dependencies=[require_api_key])
async def refresh_services(request: Request):
    """Force service registry refresh (re-read config + re-check availability).

    Requires admin role.
    """
    _require_admin_dashboard_user(request)
    if not service_registry:
        raise HTTPException(status_code=503, detail="Service registry not initialized")

    await service_registry.refresh()
    available = service_registry.get_available()
    return {
        "status": "refreshed",
        "available_count": len(available),
        "total_count": len(service_registry.get_all()),
    }
```

- [ ] **Step 5: Commit**

```bash
git add lib/laddr/src/laddr/api/main.py lib/laddr/tests/test_api_services.py
git commit -m "feat: add /api/services endpoints and registry init in API lifespan"
```

---

## Task 6: Playbook Injection at Job Submission

**Files:**
- Modify: `lib/laddr/src/laddr/api/main.py` (modify job submission endpoint)
- Modify: `lib/laddr/tests/test_service_registry.py` (add integration test)

Inject the playbook into the job's `system_prompt` before dispatching.

- [ ] **Step 1: Write failing test for playbook injection into job payload**

Add to `lib/laddr/tests/test_service_registry.py`:

```python
class TestPlaybookInjection:
    """Test that build_playbook output can be prepended to a job system_prompt."""

    def test_playbook_prepended_to_system_prompt(self, sample_config, redis_with_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_with_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        original_prompt = "You are a helpful assistant."
        job = {"system_prompt": original_prompt, "services": ["test-images"]}

        playbook = registry.build_playbook(job)
        enriched_prompt = f"{playbook}\n\n{original_prompt}" if playbook else original_prompt

        assert "# Available Platform Services" in enriched_prompt
        assert "Test Images" in enriched_prompt
        assert original_prompt in enriched_prompt

    def test_no_playbook_leaves_prompt_unchanged(self, sample_config, redis_no_workers):
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=sample_config, redis_client=redis_no_workers)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        original_prompt = "You are a helpful assistant."
        job = {"system_prompt": original_prompt}

        playbook = registry.build_playbook(job)
        enriched_prompt = f"{playbook}\n\n{original_prompt}" if playbook else original_prompt

        assert enriched_prompt == original_prompt
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py::TestPlaybookInjection -v
```

Expected: PASS.

- [ ] **Step 3: Modify the capability job submission endpoint**

In `lib/laddr/src/laddr/api/main.py`, inside the `submit_capability_job()` function (around line 2557), add playbook injection after building `job_payload` but before writing to Redis:

```python
    # Inject service playbook into system_prompt
    if service_registry:
        playbook = service_registry.build_playbook(job_payload)
        if playbook:
            original = job_payload.get("system_prompt", "")
            job_payload["system_prompt"] = f"{playbook}\n\n{original}" if original else playbook
```

Also add the `services` field to `SubmitCapabilityJobRequest` (around line 111):

```python
class SubmitCapabilityJobRequest(BaseModel):
    system_prompt: str
    user_prompt: str = ""
    inputs: dict = PydanticField(default_factory=dict)
    requirements: dict = PydanticField(default_factory=dict)
    services: list[str] = PydanticField(default_factory=list)  # NEW
    priority: str = "normal"
    timeout_seconds: int = 300
    max_iterations: int = 5
    max_tool_calls: int = 20
    callback_url: str | None = None
    callback_headers: dict = PydanticField(default_factory=dict)
```

And pass `services` into `job_payload`:

```python
    job_payload = {
        ...
        "services": request.services,  # NEW
    }
```

- [ ] **Step 4: Run all registry tests**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py tests/test_api_services.py -v
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/laddr/src/laddr/api/main.py lib/laddr/tests/test_service_registry.py
git commit -m "feat: inject service playbook into job system_prompt at submission"
```

---

**Note on `tool_schemas`:** The `ServiceDefinition.tool_schemas` field will be an empty dict `{}` in this implementation. Workers currently do not publish tool schemas to Redis — they only report MCP names in their heartbeat. Populating `tool_schemas` requires either (a) workers publishing discovered tool schemas to a Redis key, or (b) the API connecting to MCPs directly. This is deferred to a follow-up task. The API endpoints return `tool_schemas` as empty, and the dashboard's playbook drawer shows playbook text (which includes tool descriptions) rather than relying on schemas.

---

## Task 7: Dashboard — Services API Hooks

**Files:**
- Create: `dashboard/src/lib/queries/services.ts`

React Query hooks for the services API.

- [ ] **Step 1: Create services query hooks**

Create `dashboard/src/lib/queries/services.ts`:

```typescript
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";

export interface ServiceSummary {
  id: string;
  name: string;
  category: string;
  icon: string;
  description: string;
  mcp: string;
  tools: string[];
  available: boolean;
}

export interface ServiceDetail extends ServiceSummary {
  playbook: string;
  tool_schemas: Record<string, any>;
}

export interface ServicesResponse {
  services: ServiceSummary[];
  summary: {
    total: number;
    available: number;
    unavailable: number;
    last_discovered: string | null;
  };
}

export const useServices = () => {
  return useQuery({
    queryKey: ["services"],
    queryFn: async () => {
      const { data } = await api.get<ServicesResponse>("/api/services");
      return data;
    },
    staleTime: 30_000,
    refetchInterval: 60_000,
  });
};

export const useService = (serviceId: string) => {
  return useQuery({
    queryKey: ["services", serviceId],
    queryFn: async () => {
      const { data } = await api.get<ServiceDetail>(
        `/api/services/${serviceId}`
      );
      return data;
    },
    enabled: !!serviceId,
  });
};

export const useRefreshServices = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async () => {
      const { data } = await api.post("/api/services/refresh");
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["services"] });
    },
  });
};

export const useSubmitServiceJob = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      services,
      prompt,
      priority,
      timeout,
    }: {
      services: string[];
      prompt: string;
      priority: string;
      timeout?: number;
    }) => {
      const { data } = await api.post("/api/jobs/capability", {
        system_prompt: prompt,
        user_prompt: "",
        services,
        priority,
        timeout_seconds: timeout || 300,
      });
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["prompts"] });
    },
  });
};
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/queries/services.ts
git commit -m "feat: add React Query hooks for /api/services endpoints"
```

---

## Task 8: Dashboard — Services Page

**Files:**
- Create: `dashboard/src/pages/Services.tsx`
- Modify: `dashboard/src/components/Sidebar.tsx`
- Modify: `dashboard/src/App.tsx`

The main services catalog page with card grid, category filters, job submission modal, and playbook drawer.

- [ ] **Step 1: Add Services to sidebar navigation**

In `dashboard/src/components/Sidebar.tsx`, add to the `navigation` array (around line 8, after the existing entries but before Settings):

```typescript
  { name: 'Services', href: '/services', icon: Layers },
```

Add `Layers` to the lucide-react import at the top of the file.

- [ ] **Step 2: Add route in App.tsx**

In `dashboard/src/App.tsx`, add the import:

```typescript
import Services from './pages/Services';
```

Add the route inside the router (alongside other routes):

```tsx
<Route path="/services" element={<Services />} />
```

- [ ] **Step 3: Create Services page**

Create `dashboard/src/pages/Services.tsx`. This is a larger component — build it with:

1. **Top bar** with title, summary stats, category filter pills, and a refresh button
2. **Card grid** (2-column responsive) showing service cards
3. **Job submission modal** (opens on "Submit Job" click)
4. **Playbook drawer** (slide-out panel on "View Playbook" click)

The page should use:
- `useServices()` hook for the catalog data
- `useService(id)` hook for playbook detail (fetched on demand)
- `useSubmitServiceJob()` hook for job submission
- `useRefreshServices()` hook for the refresh button
- Local state for: `selectedCategory`, `jobModalService`, `playbookService`

Follow the existing page patterns from `CapabilityPlayground.tsx` for styling (dark theme: `bg-[#191A1A]`, `bg-[#1F2121]`, `border-[#2A2C2C]`, `text-cyan-400` for accents).

**Service card structure:**
- Icon + name + MCP source
- Description
- Tool tags (show first 3, then "+N more")
- Availability badge (green "Available" or red "Unavailable")
- "Submit Job" and "View Playbook" buttons

**Category filter pills:**
- All | Creative | Data | Ops | System
- Active pill: `bg-cyan-600 text-white`
- Inactive pill: `bg-[#1F2121] text-gray-400`

**Job submission modal:**
- Service name at top
- Textarea for prompt/instructions
- Priority dropdown (low/normal/high/critical)
- Submit button, loading state, error display

**Playbook drawer:**
- Fixed right panel (slide in from right)
- Renders playbook as formatted text (use `whitespace-pre-wrap` for markdown-like display)
- Close button

Refer to the mockup in the spec for the visual design. Color-code category accents:
- creative: `#7c3aed` (purple)
- data: `#0891b2` (cyan)
- ops: `#059669` (green)
- system: `#d97706` (amber)

- [ ] **Step 4: Verify the page loads**

Start the dashboard dev server and navigate to `/services`. Verify:
- Sidebar shows "Services" link
- Page renders with the service cards (may show as unavailable if API isn't running)
- Category filters work
- Submit Job modal opens
- View Playbook drawer opens

```bash
cd dashboard && npm run dev
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/pages/Services.tsx dashboard/src/components/Sidebar.tsx dashboard/src/App.tsx
git commit -m "feat: add Services dashboard page with catalog, job submission, and playbook viewer"
```

---

## Task 9: Integration Test — End-to-End Flow

**Files:**
- Create: `lib/laddr/tests/test_e2e_service_platform.py`

Test the full flow: registry loads config, discovers from Redis, builds playbook, and the playbook ends up in the job payload.

- [ ] **Step 1: Write the integration test**

Create `lib/laddr/tests/test_e2e_service_platform.py`:

```python
"""End-to-end test for the service platform.

Tests the complete flow: config → registry → discovery → playbook → job enrichment.
"""

import asyncio
import json
import yaml
import pytest
from pathlib import Path


class FakeRedis:
    def __init__(self, data):
        self._data = data

    async def hgetall(self, key):
        return {k.encode(): v.encode() for k, v in self._data.items()}


@pytest.fixture
def full_config(tmp_path):
    """Use the actual services.yml structure with 2 services."""
    config = {
        "services": [
            {
                "id": "image-generation",
                "name": "Image Generation",
                "category": "creative",
                "icon": "🎨",
                "description": "Generate images from text prompts using Gemini.",
                "mcp": "nano-banana",
                "tools": ["generate_image", "generate_blog_images"],
                "playbook": (
                    "## When to use\n"
                    "Use when a task requires creating or visualizing something.\n\n"
                    "## Tools\n"
                    "- `generate_image(prompt, filename, aspectRatio)`\n"
                ),
            },
            {
                "id": "knowledge-base",
                "name": "Knowledge Base",
                "category": "data",
                "icon": "📚",
                "description": "Persistent markdown storage with semantic search.",
                "mcp": "holocron",
                "tools": ["knowledge_search", "knowledge_get"],
                "playbook": (
                    "## When to use\n"
                    "Use for finding or storing persistent information.\n\n"
                    "## Tools\n"
                    "- `knowledge_search(query)`\n"
                ),
            },
        ]
    }
    path = tmp_path / "services.yml"
    path.write_text(yaml.dump(config))
    return str(path)


@pytest.fixture
def redis_with_both_mcps():
    return FakeRedis({
        "worker-snoke": json.dumps({
            "worker_id": "worker-snoke",
            "node": "snoke",
            "mcps": ["nano-banana", "holocron", "context7"],
            "last_heartbeat": 9999999999,
        }),
    })


class TestServicePlatformE2E:
    def test_full_flow_all_services(self, full_config, redis_with_both_mcps):
        """Config → discover → playbook for unrestricted job."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        # All services available
        assert len(registry.get_available()) == 2

        # Build playbook for a generic job (no service filter)
        job = {"system_prompt": "Do something creative."}
        playbook = registry.build_playbook(job)

        # Both services in playbook
        assert "Image Generation" in playbook
        assert "Knowledge Base" in playbook
        assert "generate_image" in playbook
        assert "knowledge_search" in playbook

        # Enrich the job
        enriched = f"{playbook}\n\n{job['system_prompt']}"
        assert "# Available Platform Services" in enriched
        assert "Do something creative." in enriched

    def test_full_flow_filtered_by_service(self, full_config, redis_with_both_mcps):
        """Config → discover → playbook filtered to one service."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        job = {
            "system_prompt": "Generate a hero image.",
            "services": ["image-generation"],
        }
        playbook = registry.build_playbook(job)

        assert "Image Generation" in playbook
        assert "Knowledge Base" not in playbook

    def test_api_response_shape(self, full_config, redis_with_both_mcps):
        """Verify the catalog can be serialized to API response format."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        services = registry.get_all()
        response = {
            "services": [
                {
                    "id": s.id,
                    "name": s.name,
                    "category": s.category,
                    "icon": s.icon,
                    "description": s.description,
                    "mcp": s.mcp,
                    "tools": s.tools,
                    "available": s.available,
                }
                for s in services
            ],
            "summary": {
                "total": len(services),
                "available": sum(1 for s in services if s.available),
                "unavailable": sum(1 for s in services if not s.available),
            },
        }

        serialized = json.dumps(response)
        parsed = json.loads(serialized)
        assert parsed["summary"]["total"] == 2
        assert parsed["summary"]["available"] == 2
```

- [ ] **Step 2: Run the integration test**

```bash
cd lib/laddr && python -m pytest tests/test_e2e_service_platform.py -v
```

Expected: All 3 tests PASS.

- [ ] **Step 3: Run all service platform tests together**

```bash
cd lib/laddr && python -m pytest tests/test_service_registry.py tests/test_api_services.py tests/test_e2e_service_platform.py -v
```

Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/laddr/tests/test_e2e_service_platform.py
git commit -m "test: add end-to-end integration test for service platform"
```

---

## Summary

| Task | What it builds | Key files |
|------|---------------|-----------|
| 1 | Service config with playbooks | `config/services.yml` |
| 2 | Registry core — load config, query methods | `core/service_registry.py` |
| 3 | Registry discovery — Redis availability | `core/service_registry.py` |
| 4 | Registry playbook builder — prompt injection | `core/service_registry.py` |
| 5 | API endpoints — `/api/services` | `api/main.py` |
| 6 | Playbook injection at job submission | `api/main.py` |
| 7 | Dashboard API hooks | `queries/services.ts` |
| 8 | Dashboard Services page | `pages/Services.tsx` |
| 9 | End-to-end integration test | `test_e2e_service_platform.py` |
