# lib/laddr/src/laddr/api/mission_control.py
"""WebSocket endpoint for Mission Control 3D visualization."""

from __future__ import annotations

import asyncio
import copy as _copy
import json
import logging
import time as _time
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


def _infer_work_type(worker: dict | None = None, job_type: str | None = None, status: str | None = None) -> str:
    """Best-effort work type inference for Mission Control overlays."""
    if status == "retrying":
        return "retry"
    if status in ("pending", "queued", "created"):
        return "wait"

    job_type_l = (job_type or "").lower()
    if any(token in job_type_l for token in ("review", "qa", "audit")):
        return "review"
    if any(token in job_type_l for token in ("code", "script", "patch", "test", "build")):
        return "code"
    if any(token in job_type_l for token in ("search", "browser", "tool", "mcp", "fetch")):
        return "tool"
    if any(token in job_type_l for token in ("chat", "prompt", "llm", "model", "summar")):
        return "llm"

    if worker:
      if worker.get("models"):
          return "llm"
      if worker.get("mcps"):
          return "tool"
      if worker.get("skills"):
          return "code"
    return "orchestration"


def _status_to_step(status: str) -> str:
    return {
        "pending": "Queued for pickup",
        "running": "In progress",
        "completed": "Delivered to output",
        "failed": "Failed in execution",
        "cancelled": "Cancelled",
    }.get(status, "Queued for pickup")


def _progress_from_status(status: str) -> float:
    return {
        "pending": 0.1,
        "running": 0.65,
        "completed": 1.0,
        "failed": 1.0,
        "cancelled": 1.0,
    }.get(status, 0.0)


def _build_job_history(prompt_entry: dict, station_id: str, work_type: str) -> list[dict]:
    created_at = prompt_entry.get("created_at", "")
    status = prompt_entry.get("status", "pending")
    history = [
        {
            "at": created_at,
            "event": "created",
            "detail": "Job entered Mission Control",
            "workType": "orchestration",
            "stationId": "intake",
        }
    ]
    history.append(
        {
            "at": created_at,
            "event": status,
            "detail": _status_to_step(status),
            "workType": work_type,
            "stationId": station_id,
        }
    )
    return history


def _dominant_mode(work_mix: dict[str, int]) -> str:
    non_zero = {k: v for k, v in work_mix.items() if v > 0}
    if not non_zero:
        return "orchestration"
    return max(non_zero.items(), key=lambda item: item[1])[0]


def _build_worker(worker: dict) -> dict:
    """Convert a worker registry entry to a Mission Control worker."""
    # Map skills to known station IDs — frontend uses capabilities[0] as station grouping key
    _SKILL_TO_STATION = {
        "code-gen": "code",
        "script-exec": "code",
        "web-research": "tool",
        "image-gen": "llm",
    }
    caps = []
    skills = worker.get("skills", [])
    if isinstance(skills, str):
        try:
            skills = json.loads(skills)
        except (json.JSONDecodeError, TypeError):
            skills = [skills] if skills else []
    for s in skills:
        station = _SKILL_TO_STATION.get(s, s)
        if station not in caps:
            caps.append(station)
    # Append MCPs as secondary capabilities
    mcps = worker.get("mcps", [])
    if isinstance(mcps, str):
        try:
            mcps = json.loads(mcps)
        except (json.JSONDecodeError, TypeError):
            mcps = [mcps] if mcps else []
    for m in mcps:
        if m not in caps:
            caps.append(str(m))
    if not caps:
        caps = ["dispatcher"]

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


# Module-level capacity imbalance tracking (system-wide, not per-connection).
# Server restarts reset to healthy — self-corrects within 5 minutes.
_imbalance_start_time: float | None = None

_ZERO_THROUGHPUT = {
    "inbound": {"5m": 0, "1h": 0, "24h": 0},
    "completed": {"5m": 0, "1h": 0, "24h": 0},
    "failed": {"5m": 0, "1h": 0, "24h": 0},
    "capacity": {"status": "healthy", "saturation": 0.0, "imbalanceSustainedMinutes": 0},
}


def _compute_throughput(database) -> dict:
    """Compute throughput rates and capacity status from the database."""
    global _imbalance_start_time

    if not database:
        return _copy.deepcopy(_ZERO_THROUGHPUT)

    b5 = database.count_executions_by_bucket(since_minutes=5)
    b15 = database.count_executions_by_bucket(since_minutes=15)
    b60 = database.count_executions_by_bucket(since_minutes=60)
    b1440 = database.count_executions_by_bucket(since_minutes=1440)

    # Saturation: how much of hourly inbound is being cleared
    saturation = min(b60["completed"] / max(b60["inbound"], 1), 1.0)

    # Capacity detection: sustained imbalance over 15-minute window
    imbalanced = b15["inbound"] > b15["completed"] * 1.2

    if imbalanced:
        if _imbalance_start_time is None:
            _imbalance_start_time = _time.time()
        sustained_minutes = (_time.time() - _imbalance_start_time) / 60.0
    else:
        _imbalance_start_time = None
        sustained_minutes = 0.0

    if sustained_minutes >= 15:
        status = "critical"
    elif sustained_minutes >= 5:
        status = "warning"
    else:
        status = "healthy"

    return {
        "inbound": {"5m": b5["inbound"], "1h": b60["inbound"], "24h": b1440["inbound"]},
        "completed": {"5m": b5["completed"], "1h": b60["completed"], "24h": b1440["completed"]},
        "failed": {"5m": b5["failed"], "1h": b60["failed"], "24h": b1440["failed"]},
        "capacity": {
            "status": status,
            "saturation": round(saturation, 2),
            "imbalanceSustainedMinutes": round(sustained_minutes, 1),
        },
    }


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

    # Enrich workers with stream pending count (true activity indicator)
    if redis_client:
        for w in workers:
            wid = w["id"]
            try:
                stream_len = await redis_client.xlen(f"laddr:worker:{wid}")
                w["streamPending"] = stream_len
                # If heartbeat says 0 active but stream has jobs, worker IS busy
                if w["activeJobs"] == 0 and stream_len > 0:
                    w["activeJobs"] = stream_len
            except Exception:
                w["streamPending"] = 0

        # Per-worker completion stats (hourly buckets in Redis)
        import time as _wtime
        hour_bucket = int(_wtime.time() // 3600)
        for w in workers:
            wid = w["id"]
            try:
                current = await redis_client.get(f"laddr:worker_stats:{wid}:completed:{hour_bucket}")
                prev = await redis_client.get(f"laddr:worker_stats:{wid}:completed:{hour_bucket - 1}")
                w["completedLastHour"] = int(current or 0) + int(prev or 0)
            except Exception:
                w["completedLastHour"] = 0

        # Set status + last job name
        for w in workers:
            if w["activeJobs"] > 0 or w.get("streamPending", 0) > 0:
                w["status"] = "busy"
            elif w.get("completedLastHour", 0) > 0:
                w["status"] = "working"
            else:
                w["status"] = "online"
            # Last completed job name
            try:
                last_job = await redis_client.get(f"laddr:worker_stats:{w['id']}:last_job")
                w["lastJobName"] = last_job.decode() if isinstance(last_job, bytes) else (last_job or "")
            except Exception:
                w["lastJobName"] = ""

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
            recent = database.list_prompts(limit=25)
            worker_lookup: dict[str, dict] = {}
            for worker in raw_workers:
                worker_lookup[worker["worker_id"]] = worker

            for pe in recent:
                state_map = {
                    "pending": "queued",
                    "running": "processing",
                    "completed": "completed",
                    "failed": "failed",
                    "cancelled": "cancelled",
                }
                status = pe.get("status", "")
                worker_hint = raw_workers[0] if raw_workers else None
                work_type = _infer_work_type(worker_hint, pe.get("prompt_name", ""), status)
                station_map = {
                    "llm": "llm",
                    "tool": "tool",
                    "code": "code",
                    "review": "supervisor",
                    "orchestration": "dispatcher",
                    "wait": "intake",
                    "retry": "error-chamber",
                }
                station_suffix = station_map.get(work_type, "dispatcher")
                station_id = station_suffix
                for station in stations:
                    if station["type"] == station_suffix:
                        station_id = station["id"]
                        break
                summary = pe.get("prompt_name", "unknown")[:80]
                current_step = _status_to_step(status)
                history = _build_job_history(pe, station_id, work_type)
                progress = _progress_from_status(status)
                jobs.append({
                    "id": pe.get("prompt_id", ""),
                    "type": pe.get("prompt_name", "unknown")[:80],
                    "priority": "normal",
                    "state": state_map.get(status, "queued"),
                    "assignedAgentId": worker_hint.get("worker_id") if status == "running" and worker_hint else None,
                    "currentStationId": station_id,
                    "path": ["intake", "dispatcher", station_id],
                    "progress": progress,
                    "createdAt": pe.get("created_at", ""),
                    "updatedAt": pe.get("created_at", ""),
                    "metadata": {
                        "summary": summary,
                        "goal": summary,
                        "workType": work_type,
                        "currentStep": current_step,
                        "latestActivity": current_step,
                        "latestActivityAt": pe.get("created_at", ""),
                        "retryCount": 1 if status == "failed" else 0,
                        "toolNames": ["llm" if work_type == "llm" else work_type] if work_type not in ("wait", "orchestration") else [],
                        "filePaths": [],
                        "tokenCount": None,
                        "costUsd": None,
                        "estimatedProgress": progress,
                    },
                    "history": history,
                })
        except Exception:
            logger.debug("Could not read jobs from database")

    # Metrics
    total_jobs = len(jobs)
    active_agents = len([a for a in agents if a["state"] != "idle"])
    error_count = len([j for j in jobs if j["state"] == "failed"])
    retry_count = len([j for j in jobs if j["state"] == "retrying"])
    jobs_blocked = len([j for j in jobs if j["state"] in ("failed", "paused")])
    work_mix = {
        "llm": 0,
        "tool": 0,
        "code": 0,
        "review": 0,
        "orchestration": 0,
        "wait": 0,
        "retry": 0,
    }
    for job in jobs:
        if job["state"] == "queued":
            work_mix["wait"] += 1
            continue
        if job["state"] == "failed":
            work_mix["retry"] += 1
            continue
        work_type = (job.get("metadata") or {}).get("workType", "orchestration")
        work_mix[work_type] = work_mix.get(work_type, 0) + 1

    # Queue depth: Redis pending streams + worker streams + DB in-flight jobs
    real_queue_depth = 0
    redis_queue = 0
    if redis_client:
        try:
            for priority in ("normal", "high", "low", "critical"):
                redis_queue += await redis_client.xlen(f"laddr:jobs:pending:{priority}")
            for w in workers:
                try:
                    redis_queue += await redis_client.xlen(f"laddr:worker:{w['id']}")
                except Exception:
                    pass
        except Exception:
            pass
    # DB in-flight = pending + running (not yet completed/failed)
    db_inflight = 0
    if database:
        try:
            from sqlalchemy import func as sa_func
            from laddr.core.database import PromptExecution
            with database.get_session() as session:
                db_inflight = (
                    session.query(sa_func.count())
                    .select_from(PromptExecution)
                    .filter(PromptExecution.status.in_(["pending", "running"]))
                    .scalar()
                ) or 0
        except Exception:
            pass
    real_queue_depth = max(redis_queue, db_inflight)

    # Overflow/triage state
    overflow_active = real_queue_depth > 100
    daily_spend = 0.0
    if redis_client:
        try:
            daily_spend = float(await redis_client.get("laddr:overflow:daily_spend") or "0.0")
        except Exception:
            pass

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
                "workMix": work_mix,
                "dominantMode": _dominant_mode(work_mix),
                "jobsBlocked": jobs_blocked,
                "realQueueDepth": real_queue_depth,
                "overflowActive": overflow_active,
                "dailyVeniceSpend": round(daily_spend, 3),
                "dailyVeniceBudget": 5.0,
                "throughput": _compute_throughput(database),
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
