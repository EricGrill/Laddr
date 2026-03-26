# lib/laddr/src/laddr/api/mission_control.py
"""WebSocket endpoint for Mission Control 3D visualization."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)

router = APIRouter()

# ---------------------------------------------------------------------------
# State snapshot builder
# ---------------------------------------------------------------------------


def _build_station_from_worker(worker: dict) -> dict:
    """Convert a worker registry entry to a Mission Control station."""
    caps = []
    for key in ("models", "mcps", "skills"):
        val = worker.get(key)
        if isinstance(val, list):
            caps.extend(val)
        elif isinstance(val, str):
            try:
                caps.extend(json.loads(val))
            except (json.JSONDecodeError, TypeError):
                if val:
                    caps.append(val)

    # Determine station type from capabilities
    has_models = bool(worker.get("models"))
    has_mcps = bool(worker.get("mcps"))
    if has_models:
        station_type = "llm"
    elif has_mcps:
        station_type = "tool"
    else:
        station_type = "code"

    status = worker.get("status", "idle")
    if status in ("idle", "online"):
        state = "idle"
    elif status == "busy":
        state = "active"
    elif status == "draining":
        state = "blocked"
    else:
        state = "offline"

    active = worker.get("active_jobs", 0)
    if isinstance(active, str):
        active = int(active)
    max_concurrent = worker.get("max_concurrent", 4)
    if isinstance(max_concurrent, str):
        max_concurrent = int(max_concurrent)

    return {
        "id": f"station-{worker['worker_id']}",
        "type": station_type,
        "label": worker.get("node", worker["worker_id"]),
        "state": "saturated" if active >= max_concurrent else state,
        "capacity": max_concurrent,
        "queueDepth": 0,
        "activeJobIds": [],
        "workerId": worker["worker_id"],
    }


def _build_worker(worker: dict) -> dict:
    """Convert a worker registry entry to a Mission Control worker."""
    caps = []
    for key in ("models", "mcps", "skills"):
        val = worker.get(key)
        if isinstance(val, list):
            caps.extend(val)
        elif isinstance(val, str):
            try:
                caps.extend(json.loads(val))
            except (json.JSONDecodeError, TypeError):
                if val:
                    caps.append(val)

    active = worker.get("active_jobs", 0)
    if isinstance(active, str):
        active = int(active)
    max_concurrent = worker.get("max_concurrent", 4)
    if isinstance(max_concurrent, str):
        max_concurrent = int(max_concurrent)

    status = worker.get("status", "online")
    if status in ("idle", "busy"):
        status = "online"

    return {
        "id": worker["worker_id"],
        "name": worker.get("node", worker["worker_id"]),
        "capabilities": caps,
        "activeJobs": active,
        "maxJobs": max_concurrent,
        "status": status,
    }


def _build_agent(agent: dict) -> dict:
    """Convert a Laddr agent registry entry to a Mission Control agent."""
    return {
        "id": agent.get("name", agent.get("id", "unknown")),
        "name": agent.get("name"),
        "role": agent.get("role", "agent"),
        "state": "idle",
        "currentJobId": None,
        "efficiency": None,
        "recentJobIds": [],
    }


def _fixed_stations() -> list[dict]:
    """Return the fixed (non-worker) stations."""
    return [
        {"id": "intake", "type": "intake", "label": "Intake Bay", "state": "active",
         "capacity": 100, "queueDepth": 0, "activeJobIds": [], "workerId": None},
        {"id": "dispatcher", "type": "dispatcher", "label": "Dispatcher Hub", "state": "active",
         "capacity": 100, "queueDepth": 0, "activeJobIds": [], "workerId": None},
        {"id": "supervisor", "type": "supervisor", "label": "Command Deck", "state": "idle",
         "capacity": 10, "queueDepth": 0, "activeJobIds": [], "workerId": None},
        {"id": "error-chamber", "type": "error", "label": "Error Chamber", "state": "idle",
         "capacity": 100, "queueDepth": 0, "activeJobIds": [], "workerId": None},
        {"id": "output-dock", "type": "output", "label": "Output Dock", "state": "active",
         "capacity": 100, "queueDepth": 0, "activeJobIds": [], "workerId": None},
    ]


async def _build_snapshot(deps: dict) -> dict:
    """Build the full Mission Control snapshot from Laddr state.

    Args:
        deps: dict with keys: worker_registry, redis, database
    """
    worker_registry = deps["worker_registry"]
    redis_client = deps.get("redis")
    database = deps.get("database")

    # Workers from registry
    raw_workers = worker_registry.list_all() if worker_registry else []

    # Also try Redis if available
    if redis_client and not raw_workers:
        try:
            all_data = await redis_client.hgetall("laddr:workers:registry")
            for wid, raw in all_data.items():
                if isinstance(wid, bytes):
                    wid = wid.decode()
                if isinstance(raw, bytes):
                    raw = raw.decode()
                try:
                    data = json.loads(raw)
                    data["worker_id"] = wid
                    raw_workers.append(data)
                except (json.JSONDecodeError, TypeError):
                    pass
        except Exception:
            logger.debug("Could not read workers from Redis")

    workers = [_build_worker(w) for w in raw_workers]
    dynamic_stations = [_build_station_from_worker(w) for w in raw_workers]
    stations = _fixed_stations() + dynamic_stations

    # Agents from Redis
    agents = []
    if redis_client:
        try:
            all_agents = await redis_client.hgetall("laddr:agents:registry")
            for name, raw in all_agents.items():
                if isinstance(name, bytes):
                    name = name.decode()
                if isinstance(raw, bytes):
                    raw = raw.decode()
                try:
                    data = json.loads(raw)
                    data["name"] = name
                    agents.append(_build_agent(data))
                except (json.JSONDecodeError, TypeError):
                    pass
        except Exception:
            logger.debug("Could not read agents from Redis")

    # Jobs from database (recent)
    # Note: database.list_prompts() returns: prompt_id, prompt_name, status, created_at
    jobs = []
    if database:
        try:
            recent = database.list_prompts(limit=100)
            for pe in recent:
                state_map = {
                    "pending": "queued",
                    "running": "processing",
                    "completed": "completed",
                    "failed": "failed",
                    "cancelled": "cancelled",
                }
                jobs.append({
                    "id": pe.get("prompt_id", ""),
                    "type": pe.get("prompt_name", "unknown"),
                    "priority": "normal",
                    "state": state_map.get(pe.get("status", ""), "queued"),
                    "assignedAgentId": None,
                    "currentStationId": None,
                    "path": [],
                    "progress": None,
                    "createdAt": pe.get("created_at", ""),
                    "updatedAt": pe.get("created_at", ""),
                    "metadata": None,
                    "history": [],
                })
        except Exception:
            logger.debug("Could not read jobs from database")

    # Metrics
    total_jobs = len(jobs)
    active_agents = len([a for a in agents if a["state"] != "idle"])
    error_count = len([j for j in jobs if j["state"] == "failed"])
    retry_count = len([j for j in jobs if j["state"] == "retrying"])

    return {
        "type": "snapshot",
        "data": {
            "agents": agents,
            "jobs": jobs,
            "stations": stations,
            "workers": workers,
            "queues": {s["id"]: s["queueDepth"] for s in stations},
            "metrics": {
                "totalJobs": total_jobs,
                "activeAgents": active_agents,
                "errorCount": error_count,
                "retryCount": retry_count,
            },
        },
    }


# ---------------------------------------------------------------------------
# Diff detection
# ---------------------------------------------------------------------------


def _diff_lists(old: list[dict], new: list[dict], id_key: str = "id") -> tuple[list, list, list]:
    """Return (added, updated, removed) between two lists of dicts."""
    old_map = {item[id_key]: item for item in old}
    new_map = {item[id_key]: item for item in new}

    added = [v for k, v in new_map.items() if k not in old_map]
    removed = [k for k in old_map if k not in new_map]
    updated = [v for k, v in new_map.items() if k in old_map and v != old_map[k]]

    return added, updated, removed


# ---------------------------------------------------------------------------
# Command handler
# ---------------------------------------------------------------------------


async def _handle_command(command: dict, deps: dict) -> dict:
    """Process a control command and return an ack."""
    action = command.get("action", "")
    worker_registry = deps.get("worker_registry")
    redis_client = deps.get("redis")

    try:
        if action == "drain_station":
            station_id = command.get("stationId", "")
            worker_id = station_id.replace("station-", "", 1)
            if worker_registry:
                worker_registry.set_status(worker_id, "draining")
            return {"type": "command_ack", "action": action, "success": True}

        elif action == "resume_station":
            station_id = command.get("stationId", "")
            worker_id = station_id.replace("station-", "", 1)
            if worker_registry:
                worker_registry.set_status(worker_id, "idle")
            return {"type": "command_ack", "action": action, "success": True}

        elif action == "kill_job":
            job_id = command.get("jobId", "")
            if redis_client:
                await redis_client.publish(f"laddr:response:{job_id}", json.dumps({
                    "status": "cancelled",
                    "error": "Killed from Mission Control",
                }))
            return {"type": "command_ack", "action": action, "success": True}

        elif action == "pause_job":
            job_id = command.get("jobId", "")
            if redis_client:
                await redis_client.hset(f"laddr:job:{job_id}:meta", "paused", "1")
            return {"type": "command_ack", "action": action, "success": True}

        elif action == "resume_job":
            job_id = command.get("jobId", "")
            if redis_client:
                await redis_client.hdel(f"laddr:job:{job_id}:meta", "paused")
            return {"type": "command_ack", "action": action, "success": True}

        elif action == "retry_job":
            # Delegate to existing replay logic
            job_id = command.get("jobId", "")
            try:
                from laddr.core.agent_runtime import AgentRunner
                from laddr.core.config import LaddrConfig
                runner = AgentRunner(env_config=LaddrConfig())
                runner.replay(job_id, reexecute=True)
                return {"type": "command_ack", "action": action, "success": True}
            except Exception as e:
                return {"type": "command_ack", "action": action, "success": False, "error": str(e)}

        elif action == "reassign_job":
            # Cancel current assignment and re-submit with target worker hint
            job_id = command.get("jobId", "")
            target_worker = command.get("targetWorkerId", "")
            if redis_client and target_worker:
                # Cancel current
                await redis_client.publish(f"laddr:response:{job_id}", json.dumps({
                    "status": "cancelled",
                    "error": "Reassigned from Mission Control",
                }))
                # Re-submit to target worker's stream
                worker_stream = f"laddr:workers:stream:{target_worker}"
                await redis_client.xadd(worker_stream, {"job": json.dumps({"job_id": job_id})})
                return {"type": "command_ack", "action": action, "success": True}
            return {"type": "command_ack", "action": action, "success": False,
                    "error": "Missing targetWorkerId or Redis unavailable"}

        else:
            return {"type": "command_ack", "action": action, "success": False,
                    "error": f"Unknown action: {action}"}

    except Exception as e:
        logger.exception("Command failed: %s", action)
        return {"type": "command_ack", "action": action, "success": False, "error": str(e)}


# ---------------------------------------------------------------------------
# WebSocket endpoint
# ---------------------------------------------------------------------------

# The deps dict is injected by the main app when mounting this router.
# It contains: worker_registry, redis, database, verify_ws_key
_deps: dict[str, Any] = {}


def set_deps(deps: dict[str, Any]) -> None:
    """Called by main.py to inject shared dependencies."""
    global _deps
    _deps = deps


@router.websocket("/ws/mission-control")
async def websocket_mission_control(websocket: WebSocket):
    """Mission Control real-time visualization endpoint.

    On connect: sends full snapshot.
    Then: polls every 2 seconds for diffs.
    Accepts: command messages from client.
    """
    # Auth
    verify = _deps.get("verify_ws_key")
    if verify:
        await verify(websocket)

    await websocket.accept()
    logger.info("Mission Control WebSocket connected")

    try:
        # Send initial snapshot
        snapshot = await _build_snapshot(_deps)
        await websocket.send_json(snapshot)
        last_snapshot = snapshot["data"]

        while True:
            # Check for incoming commands (non-blocking)
            try:
                raw = await asyncio.wait_for(websocket.receive_text(), timeout=2.0)
                command = json.loads(raw)
                if command.get("type") == "command":
                    ack = await _handle_command(command, _deps)
                    await websocket.send_json(ack)
            except asyncio.TimeoutError:
                pass  # No message received — proceed to diff check

            # Build current state and diff
            current = await _build_snapshot(_deps)
            current_data = current["data"]

            # Diff workers
            added, updated, removed = _diff_lists(
                last_snapshot.get("workers", []),
                current_data.get("workers", []),
            )
            for w in added:
                await websocket.send_json({"type": "worker_registered", "worker": w})
            for w in updated:
                await websocket.send_json({"type": "worker_registered", "worker": w})
            for wid in removed:
                await websocket.send_json({"type": "worker_deregistered", "workerId": wid})

            # Diff stations
            _, updated_stations, _ = _diff_lists(
                last_snapshot.get("stations", []),
                current_data.get("stations", []),
            )
            for s in updated_stations:
                await websocket.send_json({"type": "station_updated", "station": s})

            # Diff agents
            added_agents, updated_agents, _ = _diff_lists(
                last_snapshot.get("agents", []),
                current_data.get("agents", []),
            )
            for a in added_agents + updated_agents:
                await websocket.send_json({"type": "agent_updated", "agent": a})

            # Diff jobs
            old_jobs = {j["id"]: j for j in last_snapshot.get("jobs", [])}
            new_jobs = {j["id"]: j for j in current_data.get("jobs", [])}

            for jid, job in new_jobs.items():
                if jid not in old_jobs:
                    await websocket.send_json({"type": "job_created", "job": job})
                elif job != old_jobs[jid]:
                    old_state = old_jobs[jid].get("state")
                    new_state = job.get("state")
                    if new_state == "completed" and old_state != "completed":
                        await websocket.send_json({"type": "job_completed", "jobId": jid, "at": job["updatedAt"]})
                    elif new_state == "failed" and old_state != "failed":
                        await websocket.send_json({"type": "job_failed", "jobId": jid, "at": job["updatedAt"]})
                    else:
                        await websocket.send_json({"type": "job_updated", "job": job})

            # Diff metrics
            if current_data.get("metrics") != last_snapshot.get("metrics"):
                await websocket.send_json({"type": "metrics_updated", "metrics": current_data["metrics"]})

            last_snapshot = current_data

    except WebSocketDisconnect:
        logger.info("Mission Control WebSocket disconnected")
    except Exception:
        logger.exception("Mission Control WebSocket error")
