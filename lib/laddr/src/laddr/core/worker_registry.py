"""In-memory worker registry for tracking worker nodes and their capabilities."""
from __future__ import annotations

import time


class WorkerRegistry:
    """Registry for worker nodes.

    Tracks registration, heartbeats, and availability.
    Backend is memory-only for now; a Redis backend will be added later.
    """

    def __init__(self, backend: str = "memory") -> None:
        self._store: dict[str, dict] = {}

    # ------------------------------------------------------------------
    # Core operations
    # ------------------------------------------------------------------

    def register(self, worker_id: str, node: str, capabilities: dict) -> None:
        """Register a worker, initialising it with status='idle'."""
        self._store[worker_id] = {
            "worker_id": worker_id,
            "node": node,
            "capabilities": capabilities,
            "status": "idle",
            "active_jobs": 0,
            "last_heartbeat": time.time(),
        }

    def get(self, worker_id: str) -> dict | None:
        """Return the registry entry for *worker_id*, or None if not found."""
        return self._store.get(worker_id)

    def heartbeat(
        self,
        worker_id: str,
        active_jobs: int | None = None,
        models: list | None = None,
    ) -> None:
        """Update last_heartbeat, optionally reconcile active_jobs and models.

        Status is updated to "busy" when active_jobs >= max_concurrent and to
        "idle" when below that threshold.  Workers in "draining" status are
        never moved back to idle/busy by a heartbeat.
        """
        entry = self._store.get(worker_id)
        if entry is None:
            return

        entry["last_heartbeat"] = time.time()

        if active_jobs is not None:
            entry["active_jobs"] = active_jobs

        if models is not None:
            entry["capabilities"]["models"] = models

        # Reconcile status (skip if draining)
        if entry["status"] != "draining":
            max_concurrent = entry["capabilities"].get("max_concurrent", 0)
            if entry["active_jobs"] >= max_concurrent:
                entry["status"] = "busy"
            else:
                entry["status"] = "idle"

    def list_alive(self, max_stale_seconds: int = 60) -> list[dict]:
        """Return workers whose last heartbeat is within *max_stale_seconds*."""
        cutoff = time.time() - max_stale_seconds
        return [
            entry
            for entry in self._store.values()
            if entry["last_heartbeat"] >= cutoff
        ]

    def list_all(self) -> list[dict]:
        """Return all registered workers including stale ones."""
        return list(self._store.values())

    def deregister(self, worker_id: str) -> None:
        """Remove a worker from the registry."""
        self._store.pop(worker_id, None)

    def set_status(self, worker_id: str, status: str) -> None:
        """Explicitly set the status of a worker (e.g. 'draining')."""
        entry = self._store.get(worker_id)
        if entry is not None:
            entry["status"] = status
