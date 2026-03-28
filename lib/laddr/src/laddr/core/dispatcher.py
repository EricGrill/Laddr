"""Dispatcher service — matches jobs to workers and routes to per-worker streams.

Part A: Synchronous matching logic (find_worker_for_job) — testable without Redis.
Part B: Async dispatch loop (run) — production code requiring Redis.
"""
from __future__ import annotations

import json
import logging
import time
from typing import Any

from laddr.core.capability_matcher import matches_requirements, select_best_worker
from laddr.core.job_templates import TemplateRegistry, resolve_requirements
from laddr.core.message_bus import PRIORITY_LEVELS, priority_stream_key, worker_stream_key
from laddr.core.worker_registry import WorkerRegistry

logger = logging.getLogger(__name__)

DISPATCHER_GROUP = "dispatcher"
DISPATCHER_CONSUMER = "dispatcher-0"

# Overflow thresholds
OVERFLOW_QUEUE_THRESHOLD = 100  # Queue depth that triggers Venice overflow
OVERFLOW_DAILY_BUDGET_USD = 5.0  # Max daily Venice spend
OVERFLOW_BUDGET_KEY = "laddr:overflow:daily_spend"
OVERFLOW_BUDGET_DATE_KEY = "laddr:overflow:budget_date"

# Triage: job complexity estimation keywords
SIMPLE_KEYWORDS = ["summarize", "translate", "classify", "list", "count", "extract", "format"]
COMPLEX_KEYWORDS = ["analyze", "research", "implement", "debug", "design", "architect", "compare"]


def estimate_job_complexity(job: dict) -> str:
    """Estimate job complexity: 'simple', 'moderate', or 'complex'.

    Used by the triage system to prioritize and route jobs.
    Simple jobs go to fast local models, complex jobs get priority routing.
    """
    prompt = str(job.get("user_prompt", "") or job.get("prompt", "")).lower()
    system = str(job.get("system_prompt", "")).lower()
    text = prompt + " " + system

    # Check prompt length as a signal
    is_long = len(text) > 2000

    simple_hits = sum(1 for kw in SIMPLE_KEYWORDS if kw in text)
    complex_hits = sum(1 for kw in COMPLEX_KEYWORDS if kw in text)

    if complex_hits >= 2 or is_long:
        return "complex"
    elif simple_hits >= 2 and not is_long:
        return "simple"
    return "moderate"


class Dispatcher:
    """Central job router: reads pending streams, matches to workers, routes jobs."""

    def __init__(
        self,
        worker_registry: WorkerRegistry,
        template_registry: TemplateRegistry,
        redis_client: Any | None = None,
    ) -> None:
        self.worker_registry = worker_registry
        self.template_registry = template_registry
        self.redis = redis_client
        self._waiting: list[dict] = []  # jobs that couldn't be matched yet
        self._running = False

    # ------------------------------------------------------------------
    # Part A: Synchronous matching logic
    # ------------------------------------------------------------------

    def find_worker_for_job(self, job: dict) -> dict | None:
        """Match a job to the best available worker.

        1. Resolve the job's requirements (generic / template / explicit).
        2. Get alive workers from the registry.
        3. Filter through matches_requirements.
        4. Select the best worker via select_best_worker.
        5. Return the worker dict or None.
        """
        job_reqs = job.get("requirements", {})
        resolved = resolve_requirements(job_reqs, self.template_registry)
        requirements = resolved["requirements"]

        alive = self.worker_registry.list_alive()
        if not alive:
            return None

        return select_best_worker(alive, requirements)

    async def _load_workers_from_redis(self) -> list[dict[str, Any]]:
        """Load worker registrations from Redis into memory and return alive workers.

        Uses the dispatcher's own active counters (laddr:workers:active:{wid})
        rather than the worker heartbeat's active_jobs, since the heartbeat
        only reflects jobs the worker has actually started processing — not
        jobs queued in its stream waiting to be picked up.
        """
        if self.redis is None:
            return self.worker_registry.list_alive()
        try:
            raw = await self.redis.hgetall("laddr:workers:registry")
            workers = []
            now = time.time()
            for _wid, data in raw.items():
                w = json.loads(data)
                # Consider alive if heartbeat within 120s
                if now - w.get("last_heartbeat", 0) < 120:
                    if "capabilities" not in w:
                        w["capabilities"] = {
                            "models": w.get("models", []),
                            "mcps": w.get("mcps", []),
                            "skills": w.get("skills", []),
                            "max_concurrent": w.get("max_concurrent", 1),
                        }
                    # Read the dispatcher's active counter — this reflects
                    # jobs dispatched but not yet completed, which is the
                    # correct backpressure signal.
                    wid = w.get("worker_id", "")
                    active_key = f"laddr:workers:active:{wid}"
                    try:
                        dispatched_active = await self.redis.get(active_key)
                        w["active_jobs"] = int(dispatched_active or 0)
                    except Exception:
                        w["active_jobs"] = w.get("active_jobs", 0)
                    workers.append(w)
            return workers
        except Exception as exc:
            logger.warning("Failed to load workers from Redis: %s", exc)
            return self.worker_registry.list_alive()

    async def async_find_worker_for_job(self, job: dict[str, Any]) -> dict[str, Any] | None:
        """Async version of find_worker_for_job that reads workers from Redis."""
        job_reqs = job.get("requirements", {})
        resolved = resolve_requirements(job_reqs, self.template_registry)
        requirements = resolved["requirements"]

        alive = await self._load_workers_from_redis()
        if not alive:
            return None

        return select_best_worker(alive, requirements)

    # ------------------------------------------------------------------
    # Part B: Async dispatch loop (production)
    # ------------------------------------------------------------------

    async def _ensure_consumer_groups(self) -> None:
        """Create consumer groups on each priority stream (idempotent)."""
        for priority in PRIORITY_LEVELS:
            stream = priority_stream_key(priority)
            try:
                await self.redis.xgroup_create(
                    stream, DISPATCHER_GROUP, id="0", mkstream=True,
                )
            except Exception:
                # Group already exists
                pass

    async def _reclaim_unacked(self) -> list[tuple[str, str, dict]]:
        """Reclaim unacknowledged messages on startup via XAUTOCLAIM."""
        reclaimed: list[tuple[str, str, dict]] = []
        for priority in PRIORITY_LEVELS:
            stream = priority_stream_key(priority)
            try:
                # XAUTOCLAIM: min-idle-time 30s, start from "0-0"
                result = await self.redis.xautoclaim(
                    stream, DISPATCHER_GROUP, DISPATCHER_CONSUMER,
                    min_idle_time=30_000, start_id="0-0", count=100,
                )
                # result format: [start_id, [(msg_id, fields), ...], deleted_ids]
                if result and len(result) >= 2:
                    for msg_id, fields in result[1]:
                        reclaimed.append((stream, msg_id, fields))
            except Exception as exc:
                logger.warning("XAUTOCLAIM failed on %s: %s", stream, exc)
        return reclaimed

    async def _get_queue_depth(self) -> int:
        """Get total pending job count across all priority streams."""
        if not self.redis:
            return 0
        total = 0
        for priority in PRIORITY_LEVELS:
            stream = priority_stream_key(priority)
            try:
                length = await self.redis.xlen(stream)
                total += length
            except Exception:
                pass
        return total

    async def _check_overflow_budget(self) -> bool:
        """Check if we're within the daily Venice overflow budget."""
        if not self.redis:
            return False
        try:
            today = time.strftime("%Y-%m-%d")
            budget_date = await self.redis.get(OVERFLOW_BUDGET_DATE_KEY)
            if budget_date != today:
                # New day — reset budget
                await self.redis.set(OVERFLOW_BUDGET_DATE_KEY, today)
                await self.redis.set(OVERFLOW_BUDGET_KEY, "0.0")
                return True
            spent = float(await self.redis.get(OVERFLOW_BUDGET_KEY) or "0.0")
            return spent < OVERFLOW_DAILY_BUDGET_USD
        except Exception:
            return False

    async def _record_overflow_cost(self, estimated_cost: float) -> None:
        """Record estimated cost of a Venice overflow job."""
        if not self.redis:
            return
        try:
            await self.redis.incrbyfloat(OVERFLOW_BUDGET_KEY, estimated_cost)
        except Exception:
            pass

    async def _triage_and_route(self, job: dict) -> dict | None:
        """Triage a job and find the best worker, considering overflow to Venice.

        1. Estimate complexity
        2. If queue is deep and budget allows, prefer Venice-capable workers for overflow
        3. Simple jobs → fastest local worker
        4. Complex jobs → most capable worker (Venice if overflowing)
        """
        complexity = estimate_job_complexity(job)
        queue_depth = await self._get_queue_depth()
        overflow_active = queue_depth > OVERFLOW_QUEUE_THRESHOLD

        # Log triage decision
        if overflow_active:
            budget_ok = await self._check_overflow_budget()
            if budget_ok:
                logger.info(
                    "TRIAGE: queue=%d complexity=%s → overflow to Venice",
                    queue_depth, complexity,
                )
                # Tag the job so workers know to use Venice
                job.setdefault("routing", {})["prefer_cloud"] = True
                job["routing"]["complexity"] = complexity
                if complexity == "simple":
                    # Estimate ~$0.001 per simple job
                    await self._record_overflow_cost(0.001)
                else:
                    await self._record_overflow_cost(0.005)
            else:
                logger.info(
                    "TRIAGE: queue=%d complexity=%s → budget exhausted, local only",
                    queue_depth, complexity,
                )
        else:
            logger.info("TRIAGE: queue=%d complexity=%s → normal routing", queue_depth, complexity)

        # Find worker (select_best_worker handles capacity checks)
        return await self.async_find_worker_for_job(job)

    async def _dispatch_job(self, job: dict, stream: str, msg_id: str) -> bool:
        """Try to route a single job. Returns True if dispatched."""
        worker = await self._triage_and_route(job)
        if worker is None:
            return False

        worker_id = worker["worker_id"]
        active_key = f"laddr:workers:active:{worker_id}"

        # Atomic INCR for back-pressure
        try:
            await self.redis.incr(active_key)
        except Exception as exc:
            logger.error("INCR failed for %s: %s", worker_id, exc)
            return False

        # Route to per-worker stream
        target_stream = worker_stream_key(worker_id)
        try:
            await self.redis.xadd(target_stream, {"job": json.dumps(job)})
        except Exception as exc:
            # XADD failed — DECR back to prevent counter leak
            logger.error("XADD to %s failed: %s — rolling back counter", target_stream, exc)
            try:
                await self.redis.decr(active_key)
            except Exception:
                logger.error("DECR rollback also failed for %s", worker_id)
            return False

        # ACK the message from the pending stream
        try:
            group = DISPATCHER_GROUP
            await self.redis.xack(stream, group, msg_id)
        except Exception as exc:
            logger.warning("XACK failed on %s/%s: %s", stream, msg_id, exc)

        logger.info("Dispatched job to worker %s via %s", worker_id, target_stream)
        return True

    async def _process_waiting(self) -> None:
        """Try to dispatch jobs from the in-memory waiting list."""
        still_waiting: list[dict] = []
        for entry in self._waiting:
            job = entry["job"]
            worker = await self.async_find_worker_for_job(job)
            if worker is None:
                still_waiting.append(entry)
                continue

            worker_id = worker["worker_id"]
            active_key = f"laddr:workers:active:{worker_id}"
            target_stream = worker_stream_key(worker_id)

            try:
                await self.redis.incr(active_key)
                await self.redis.xadd(target_stream, {"job": json.dumps(job)})
                logger.info("Dispatched waiting job to worker %s", worker_id)
            except Exception as exc:
                logger.error("Failed to dispatch waiting job: %s", exc)
                try:
                    await self.redis.decr(active_key)
                except Exception:
                    pass
                still_waiting.append(entry)

        self._waiting = still_waiting

    async def run(self) -> None:
        """Main dispatch loop — reads priority streams and routes jobs.

        Requires self.redis to be set.
        """
        if self.redis is None:
            raise RuntimeError("Dispatcher.run() requires a redis_client")

        self._running = True
        await self._ensure_consumer_groups()

        # Reclaim any unacked messages from previous run
        reclaimed = await self._reclaim_unacked()
        for stream, msg_id, fields in reclaimed:
            raw = fields.get("job", fields.get(b"job", "{}"))
            if isinstance(raw, bytes):
                raw = raw.decode()
            job = json.loads(raw)
            dispatched = await self._dispatch_job(job, stream, msg_id)
            if not dispatched:
                self._waiting.append({"job": job, "stream": stream, "msg_id": msg_id})
                logger.info("Reclaimed job queued to waiting list")

        # Build stream dict for XREADGROUP
        streams = {priority_stream_key(p): ">" for p in PRIORITY_LEVELS}

        # Counter sync timer — every 30s, reconcile active counters
        # with actual worker heartbeat data to prevent counter drift
        counter_sync_interval = 30.0
        counter_sync_timer = counter_sync_interval

        while self._running:
            # Periodic counter reconciliation
            counter_sync_timer -= 1.0  # ~1s per loop iteration (block=1000ms)
            if counter_sync_timer <= 0:
                counter_sync_timer = counter_sync_interval
                await self._sync_active_counters()

            # Check waiting queue first each iteration
            if self._waiting:
                await self._process_waiting()

            try:
                result = await self.redis.xreadgroup(
                    groupname=DISPATCHER_GROUP,
                    consumername=DISPATCHER_CONSUMER,
                    streams=streams,
                    count=10,
                    block=1000,  # 1s block
                )
            except Exception as exc:
                logger.error("XREADGROUP error: %s", exc)
                continue

            if not result:
                continue

            for stream_name, messages in result:
                if isinstance(stream_name, bytes):
                    stream_name = stream_name.decode()
                for msg_id, fields in messages:
                    if isinstance(msg_id, bytes):
                        msg_id = msg_id.decode()
                    raw = fields.get("job", fields.get(b"job", "{}"))
                    if isinstance(raw, bytes):
                        raw = raw.decode()
                    job = json.loads(raw)

                    try:
                        dispatched = await self._dispatch_job(job, stream_name, msg_id)
                    except Exception as exc:
                        logger.error("Failed to dispatch job %s: %s", msg_id, exc)
                        # ACK the poison message so it doesn't block the queue
                        try:
                            await self.redis.xack(stream_name, DISPATCHER_GROUP, msg_id)
                        except Exception:
                            pass
                        continue
                    if not dispatched:
                        # TODO: persist waiting list to Redis for crash recovery
                        self._waiting.append({
                            "job": job,
                            "stream": stream_name,
                            "msg_id": msg_id,
                        })
                        logger.info("No worker available — job added to waiting list")

    async def _sync_active_counters(self) -> None:
        """Reconcile dispatcher active counters with worker heartbeat data.

        Workers report their actual active_jobs in heartbeats. If the
        dispatcher counter is higher (due to crashed jobs that never
        decremented), reset it to the worker's reported value.
        """
        if not self.redis:
            return
        try:
            raw = await self.redis.hgetall("laddr:workers:registry")
            for _wid, data in raw.items():
                w = json.loads(data)
                wid = w.get("worker_id", "")
                if not wid:
                    continue
                actual_active = w.get("active_jobs", 0)
                if isinstance(actual_active, str):
                    actual_active = int(actual_active)
                active_key = f"laddr:workers:active:{wid}"
                try:
                    counter_val = int(await self.redis.get(active_key) or 0)
                except (ValueError, TypeError):
                    counter_val = 0
                # If counter is higher than reality, sync it down
                if counter_val > actual_active:
                    await self.redis.set(active_key, actual_active)
                    logger.info(
                        "Counter sync: %s was %d, actual %d — corrected",
                        wid, counter_val, actual_active,
                    )
        except Exception as exc:
            logger.warning("Counter sync failed: %s", exc)

    def stop(self) -> None:
        """Signal the dispatch loop to stop."""
        self._running = False


if __name__ == "__main__":
    import asyncio

    async def _main() -> None:
        import os

        import redis.asyncio as aioredis

        redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379")
        redis_client = aioredis.from_url(redis_url, decode_responses=True)
        worker_reg = WorkerRegistry()
        template_reg = TemplateRegistry()
        dispatcher = Dispatcher(worker_reg, template_reg, redis_client=redis_client)

        logger.info("Starting dispatcher...")
        try:
            await dispatcher.run()
        except KeyboardInterrupt:
            dispatcher.stop()
        finally:
            await redis_client.aclose()

    logging.basicConfig(level=logging.INFO)
    asyncio.run(_main())
