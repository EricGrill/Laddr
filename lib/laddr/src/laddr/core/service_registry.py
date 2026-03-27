"""Service registry — loads service definitions from YAML config and tracks availability."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml


@dataclass
class ServiceDefinition:
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
    """Registry of platform services loaded from a YAML config file."""

    def __init__(self, config_path: str | Path, redis_client=None) -> None:
        self._config_path = Path(config_path)
        self._services: dict[str, ServiceDefinition] = {}
        self.last_discovered: str | None = None
        self._redis = redis_client
        self._load()

    # ------------------------------------------------------------------
    # Config loading
    # ------------------------------------------------------------------

    def _load(self) -> None:
        with open(self._config_path) as f:
            data = yaml.safe_load(f)

        for svc in data.get("services", []):
            sd = ServiceDefinition(
                id=svc["id"],
                name=svc["name"],
                category=svc["category"],
                icon=svc.get("icon", ""),
                description=svc.get("description", ""),
                mcp=svc["mcp"],
                playbook=svc.get("playbook", ""),
                tools=svc.get("tools", []),
            )
            self._services[sd.id] = sd

    # ------------------------------------------------------------------
    # Query methods
    # ------------------------------------------------------------------

    def get_all(self) -> list[ServiceDefinition]:
        """Return all services."""
        return list(self._services.values())

    def get(self, service_id: str) -> ServiceDefinition | None:
        """Return a service by ID, or None if not found."""
        return self._services.get(service_id)

    def get_available(self) -> list[ServiceDefinition]:
        """Return only available services."""
        return [s for s in self._services.values() if s.available]

    def get_by_category(self, category: str) -> list[ServiceDefinition]:
        """Return all services in a given category."""
        return [s for s in self._services.values() if s.category == category]

    # ------------------------------------------------------------------
    # Availability discovery
    # ------------------------------------------------------------------

    async def discover(self, redis=None) -> None:
        """Read worker heartbeats from Redis and mark services available/unavailable.

        Checks ``laddr:workers:registry`` hash. Workers whose ``last_heartbeat``
        is within 90 seconds are considered alive. Any MCP listed by an alive
        worker marks the corresponding service(s) as available.
        """
        import time

        # Re-read config to support hot-reload
        self._load()

        redis = redis or self._redis
        if not redis:
            logger.warning("No Redis client — all services marked unavailable")
            return

        alive_mcps: set[str] = set()

        workers_data = await redis.hgetall("laddr:workers:registry")
        now = time.time()

        for _worker_id, raw in workers_data.items():
            if isinstance(raw, bytes):
                raw = raw.decode()
            try:
                worker = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue

            last_heartbeat = worker.get("last_heartbeat", 0)
            if isinstance(last_heartbeat, str):
                try:
                    last_heartbeat = float(last_heartbeat)
                except ValueError:
                    continue

            if now - last_heartbeat <= 90:
                for mcp_name in worker.get("mcps", []):
                    alive_mcps.add(mcp_name)

        for svc in self._services.values():
            svc.available = svc.mcp in alive_mcps

        self.last_discovered = datetime.now(timezone.utc).isoformat()

    async def refresh(self, redis=None) -> None:
        """Re-run discovery; convenience alias for ``discover()``.

        Intended for periodic background refresh calls.
        """
        await self.discover(redis)

    # ------------------------------------------------------------------
    # Playbook builder
    # ------------------------------------------------------------------

    def build_playbook(self, job: dict) -> str:
        """Build a playbook string to inject into an agent's system prompt.

        Priority:
        1. If job has ``services`` list, inject only those (must be available).
        2. If job has ``requirements.mcps``, inject services matching those MCPs.
        3. Otherwise inject all available services.

        Returns an empty string if no matching services are available.

        ``requirements`` may be a dict or a JSON string (as stored in some job
        payloads).

        Callers should prepend the returned string to the job's ``system_prompt``
        with a blank line separator::

            playbook = registry.build_playbook(job)
            if playbook:
                job["system_prompt"] = playbook + "\\n\\n" + job.get("system_prompt", "")
        """
        # Resolve requirements — may be a dict or a JSON string
        requirements = job.get("requirements", {})
        if isinstance(requirements, str):
            try:
                requirements = json.loads(requirements)
            except (json.JSONDecodeError, TypeError):
                requirements = {}

        services: list[ServiceDefinition] = []

        if "services" in job and job["services"]:
            requested = set(job["services"])
            services = [
                s for s in self._services.values()
                if s.id in requested and s.available
            ]
        elif requirements and "mcps" in requirements:
            requested_mcps = set(requirements["mcps"])
            services = [
                s for s in self._services.values()
                if s.mcp in requested_mcps and s.available
            ]
        else:
            services = self.get_available()

        if not services:
            return ""

        parts = ["# Available Platform Services\n"]
        for svc in services:
            parts.append(f"---\n\n## {svc.icon} {svc.name} ({svc.mcp})\n")
            parts.append(svc.description)
            if svc.playbook:
                parts.append("\n" + svc.playbook)

        return "\n".join(parts)
