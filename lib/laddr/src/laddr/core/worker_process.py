"""
Worker process — runs on each Mac to consume jobs from Redis,
build ephemeral agents, execute via LM Studio, and publish results.

Part A: Pure functions (select_model_for_job, build_agent_config, load_worker_config)
Part B: Async WorkerProcess lifecycle (Redis consumption, execution, heartbeat)
"""

from __future__ import annotations

import asyncio
import json
import logging
import signal
import time
from typing import Any

import yaml

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Part A: Pure functions
# ---------------------------------------------------------------------------


def select_model_for_job(
    available_models: list[dict], requirements: dict
) -> dict | None:
    """Pick best model from worker's available models for this job.

    Filtering rules (applied in order):
    - If requirements contains "models" (list of model id strings),
      only models whose "id" is in that list are considered.
    - If requirements contains "model_match" (substring), only models
      whose "id" contains that substring are considered.
    - If requirements contains "min_context_window", only models with
      context_window >= that value are considered.

    Among candidates, prefer models with ``loaded=True``.
    If no requirements are given (empty dict), pick the first loaded model,
    falling back to the first model overall.

    Returns None when *available_models* is empty or no candidate matches.
    """
    if not available_models:
        return None

    # Exclude embedding models — they can't do chat/completion
    EMBEDDING_PATTERNS = ("embed", "embedding", "nomic-embed", "text-embedding")
    candidates = [
        m for m in available_models
        if not any(p in m.get("id", "").lower() for p in EMBEDDING_PATTERNS)
    ]
    if not candidates:
        candidates = list(available_models)  # fallback if ALL models are embeddings

    # Filter by explicit model list
    model_ids = requirements.get("models")
    if model_ids:
        candidates = [m for m in candidates if m.get("id") in model_ids]

    # Filter by substring match
    model_match = requirements.get("model_match")
    if model_match:
        candidates = [m for m in candidates if model_match in m.get("id", "")]

    # Filter by minimum context window
    min_ctx = requirements.get("min_context_window")
    if min_ctx is not None:
        candidates = [m for m in candidates if m.get("context_window", 0) >= min_ctx]

    if not candidates:
        return None

    # Prefer loaded models
    loaded = [m for m in candidates if m.get("loaded")]
    if loaded:
        return loaded[0]

    return candidates[0]


def build_agent_config(job: dict, worker_id: str) -> dict:
    """Build Agent constructor kwargs from a job payload.

    Returns dict with keys expected by ``AgentConfig`` / ``Agent.__init__``.
    """
    job_id = job.get("job_id", "unknown")
    return {
        "name": f"worker-{worker_id}-{job_id[:8]}",
        "role": "worker",
        "goal": job.get("system_prompt", ""),
        "backstory": job.get("backstory", ""),
        "instructions": job.get("user_prompt", ""),
        "max_iterations": job.get("max_iterations", 5),
        "is_coordinator": False,
    }


def load_worker_config(config_path: str) -> dict:
    """Load worker config from a YAML file.

    Returns the parsed dict.  Raises ``FileNotFoundError`` if the path
    does not exist, or ``yaml.YAMLError`` on malformed YAML.
    """
    with open(config_path, "r") as fh:
        return yaml.safe_load(fh) or {}


async def _execute_script_job(job: dict) -> dict:
    """Execute a task_type='script' job directly via script_executor."""
    from laddr.core.script_executor import execute_script

    command = job.get("command") or job.get("user_prompt", "")
    if not command:
        return {
            "status": "error", "exit_code": -1, "stdout": "",
            "stderr": "No command provided in script job",
            "metrics": None, "artifacts": [], "duration_seconds": 0.0,
            "workspace_path": "",
        }

    raw_timeout = job.get("timeout_seconds", 300)
    timeout = float(raw_timeout) if raw_timeout is not None else 300.0

    result = await execute_script(
        command=command,
        timeout_seconds=timeout,
        experiment_id=job.get("experiment_id"),
        env=job.get("env"),
    )
    return result.to_dict()


def _should_register_exec_tool(config: dict) -> bool:
    """Check if this worker config should register the system_exec_script tool."""
    return "script-exec" in config.get("skills", [])


# ---------------------------------------------------------------------------
# Part B: Async process lifecycle
# ---------------------------------------------------------------------------


async def discover_lmstudio_models(endpoint: str) -> list[dict]:
    """GET ``{endpoint}/models`` and parse the loaded model list.

    Each returned dict contains at least ``id`` and ``loaded`` (True).
    """
    import httpx

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{endpoint}/models")
        resp.raise_for_status()
        data = resp.json()

    models: list[dict] = []
    for entry in data.get("data", []):
        models.append(
            {
                "id": entry.get("id", ""),
                "provider": "lmstudio",
                "context_window": entry.get("context_window", 0),
                "loaded": True,
            }
        )
    return models


class WorkerProcess:
    """Long-running worker process.

    Connects to Redis, discovers LM Studio models, consumes jobs from a
    per-worker stream, builds ephemeral agents, and publishes results.
    """

    def __init__(self, config_path: str):
        self.config = load_worker_config(config_path)
        self.worker_id: str = self.config["worker_id"]
        self.node: str = self.config.get("node", self.worker_id)
        self.llm_endpoint: str | None = self.config.get("llm", {}).get("endpoint")
        self.llm_api_key: str = self.config.get("llm", {}).get("api_key", "lm-studio")
        self.max_concurrent: int = self.config.get("max_concurrent", 2)
        self.redis_url: str = self.config["server"]["redis_url"]

        # Cloud LLM providers (optional, used as fallback or when job requires specific models)
        self.cloud_providers: list[dict] = self.config.get("cloud_providers", [])

        # MinIO/S3 storage config (optional)
        self.minio_endpoint: str | None = self.config.get("server", {}).get("minio_endpoint")
        self.minio_access_key: str = self.config.get("server", {}).get("minio_access_key", "minioadmin")
        self.minio_secret_key: str = self.config.get("server", {}).get("minio_secret_key", "minioadmin123")
        self.minio_bucket: str = self.config.get("server", {}).get("minio_bucket", "laddr")
        self.store_results_in_minio: bool = self.config.get("server", {}).get("store_results", False)

        self._running: bool = False
        self._redis: Any = None
        self._storage: Any = None
        self._models: list[dict] = []
        self._active_jobs: int = 0
        self._heartbeat_task: asyncio.Task | None = None
        self._seen_ids: set[str] = set()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self):
        """Main entry point — run until shutdown signal."""
        import redis.asyncio as aioredis

        self._redis = aioredis.from_url(self.redis_url, decode_responses=True)
        self._running = True

        # Initialize MinIO storage if configured
        if self.store_results_in_minio and self.minio_endpoint:
            try:
                from laddr.core.storage import S3Storage
                self._storage = S3Storage(
                    endpoint=self.minio_endpoint,
                    access_key=self.minio_access_key,
                    secret_key=self.minio_secret_key,
                    secure=False,
                )
                await self._storage.ensure_bucket(self.minio_bucket)
                logger.info("MinIO storage enabled: %s/%s", self.minio_endpoint, self.minio_bucket)
            except Exception as exc:
                logger.warning("Failed to initialize MinIO storage: %s", exc)
                self._storage = None

        # Discover models
        if self.llm_endpoint:
            try:
                self._models = await discover_lmstudio_models(self.llm_endpoint)
            except Exception:
                logger.warning("Failed to discover LM Studio models; continuing with empty list")
                self._models = []
        else:
            logger.info("No LLM endpoint configured — script-only worker")
            self._models = []

        # Register capabilities in Redis hash
        capabilities = self._build_capabilities()
        await self._redis.hset(
            "laddr:workers:registry",
            self.worker_id,
            json.dumps(capabilities),
        )

        # Signal handlers
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, self._shutdown)
        # Ignore SIGHUP so SSH disconnect doesn't kill the worker
        signal.signal(signal.SIGHUP, signal.SIG_IGN)

        # Consumer group on worker stream
        stream_key = f"laddr:worker:{self.worker_id}"
        group_name = f"worker-{self.worker_id}"
        try:
            await self._redis.xgroup_create(stream_key, group_name, id="0", mkstream=True)
        except Exception:
            # Group may already exist
            pass

        # Heartbeat task
        self._heartbeat_task = asyncio.create_task(
            self._heartbeat_loop(capabilities)
        )

        # Consume loop
        logger.info("Worker %s started, consuming from %s", self.worker_id, stream_key)
        try:
            while self._running:
                try:
                    results = await self._redis.xreadgroup(
                        groupname=group_name,
                        consumername=self.worker_id,
                        streams={stream_key: ">"},
                        count=1,
                        block=2000,
                    )
                except Exception as exc:
                    err_msg = str(exc)
                    if "NOGROUP" in err_msg:
                        # Stream or group was deleted (e.g. by flush) — recreate
                        logger.warning("Stream/group deleted, recreating %s", stream_key)
                        try:
                            await self._redis.xgroup_create(
                                stream_key, group_name, id="0", mkstream=True,
                            )
                        except Exception:
                            pass
                    else:
                        logger.error("XREADGROUP error: %s", exc)
                    await asyncio.sleep(1)
                    continue

                if not results:
                    continue

                for _stream, messages in results:
                    for msg_id, fields in messages:
                        # Dispatcher sends {"job": json.dumps(...)},
                        # API sends {"payload": json.dumps(...), "job_id": ...}
                        raw = fields.get("payload") or fields.get("job", "{}")
                        job = json.loads(raw)

                        job_id = fields.get("job_id", "") or job.get("job_id", "") or str(msg_id)
                        job.setdefault("job_id", job_id)

                        if job_id in self._seen_ids:
                            await self._redis.xack(stream_key, group_name, msg_id)
                            continue
                        self._seen_ids.add(job_id)

                        try:
                            await self._execute_job(job)
                        except Exception:
                            logger.exception("Job %s failed", job_id)
                        finally:
                            await self._redis.xack(stream_key, group_name, msg_id)
        finally:
            if self._heartbeat_task:
                self._heartbeat_task.cancel()
            await self._deregister()
            await self._redis.aclose()
            logger.info("Worker %s stopped", self.worker_id)

    # ------------------------------------------------------------------
    # Job execution
    # ------------------------------------------------------------------

    def _detect_task_type(self, job: dict) -> str:
        """Detect the actual task type from job payload.

        If the job explicitly sets task_type, use it.
        Otherwise, infer from context:
        - If system_prompt contains 'execute' / 'shell' / 'command' / 'run' AND
          this worker has the 'script-exec' skill, treat as a script job.
        """
        explicit = job.get("task_type", "")
        if explicit:
            return explicit

        has_script_skill = "script-exec" in self.config.get("skills", [])
        if not has_script_skill:
            return "llm"

        system_prompt = (job.get("system_prompt") or "").lower()
        user_prompt = (job.get("user_prompt") or "").lower()
        script_signals = ("execute", "shell", "command", "run script", "bash", "sh -c")

        if any(s in system_prompt for s in script_signals):
            return "script"
        # Also detect if user_prompt starts with common shell patterns
        stripped = user_prompt.strip()
        if stripped and (
            stripped.startswith("echo ") or
            stripped.startswith("cd ") or
            stripped.startswith("ls ") or
            stripped.startswith("python") or
            stripped.startswith("pip ") or
            stripped.startswith("npm ") or
            stripped.startswith("git ") or
            stripped.startswith("curl ") or
            stripped.startswith("wget ") or
            stripped.startswith("mkdir ") or
            stripped.startswith("cat ") or
            stripped.startswith("./") or
            stripped.startswith("bash ") or
            stripped.startswith("sh ")
        ):
            return "script"

        return "llm"

    async def _execute_job(self, job: dict):
        """Dispatch a job to the appropriate executor based on task_type."""
        job_id = job.get("job_id", "unknown")
        task_type = self._detect_task_type(job)

        logger.info("Job %s detected as task_type=%s", job_id, task_type)
        self._active_jobs += 1

        # Mark job as running in the database
        api_url = self.config.get("server", {}).get("api_url")
        if api_url:
            try:
                import httpx
                async with httpx.AsyncClient(timeout=3) as client:
                    await client.post(
                        f"{api_url}/api/prompts/{job_id}/complete",
                        json={"status": "running", "outputs": {}},
                        headers={"X-API-Key": "internal"},
                    )
            except Exception:
                pass  # non-critical

        try:
            if task_type == "script":
                result = await _execute_script_job(job)
            else:
                result = await self._execute_llm_job(job)
                if result is None:
                    # Re-enqueued; nothing more to do
                    return

            # Shared bookkeeping: persist result, fire callback
            result_key = f"laddr:results:{job_id}"
            result_payload = json.dumps({
                "job_id": job_id,
                "worker_id": self.worker_id,
                "task_type": task_type,
                "result": result,
                "completed_at": time.time(),
            })
            await self._redis.set(result_key, result_payload, ex=1800)

            # Store in MinIO if enabled
            if self._storage:
                try:
                    minio_key = f"results/{job_id}.json"
                    await self._storage.put_object(
                        self.minio_bucket,
                        minio_key,
                        result_payload.encode("utf-8"),
                        metadata={"content-type": "application/json", "worker": self.worker_id},
                    )
                    logger.info("Result stored in MinIO: %s/%s", self.minio_bucket, minio_key)
                except Exception as exc:
                    logger.warning("Failed to store result in MinIO: %s", exc)

            # Update database record so job shows as completed in API/Mission Control
            api_url = self.config.get("server", {}).get("api_url")
            if api_url:
                try:
                    import httpx
                    async with httpx.AsyncClient(timeout=5) as client:
                        status = "completed" if (isinstance(result, dict) and result.get("status") != "error") else "failed"
                        await client.post(
                            f"{api_url}/api/prompts/{job_id}/complete",
                            json={"status": status, "outputs": result},
                            headers={"X-API-Key": "internal"},
                        )
                except Exception as exc:
                    logger.debug("Could not update prompt status via API: %s", exc)

            callback_url = job.get("callback_url")
            callback_headers = job.get("callback_headers", {})
            if callback_url:
                await self._fire_callback(callback_url, callback_headers, result_payload)

            logger.info("Job %s (%s) completed", job_id, task_type)
        finally:
            self._active_jobs -= 1
            # Decrement both keys for compatibility with dispatcher backpressure
            for counter_key in (
                f"laddr:active:{self.worker_id}",
                f"laddr:workers:active:{self.worker_id}",
            ):
                try:
                    val = await self._redis.decr(counter_key)
                    # Don't let counter go negative
                    if val < 0:
                        await self._redis.set(counter_key, 0)
                except Exception:
                    pass

    async def _execute_llm_job(self, job: dict) -> dict | None:
        """Execute a task_type='llm' job by building an ephemeral agent.

        Returns the result dict, or None if the job was re-enqueued because no
        suitable model was available.
        """
        from laddr.core.config import AgentConfig, LaddrConfig
        from laddr.core.agent_runtime import Agent as CoreAgent
        from laddr.core.llm import OpenAILLM
        from laddr.core.job_templates import TemplateRegistry, resolve_requirements
        from laddr.core.message_bus import priority_stream_key

        job_id = job.get("job_id", "unknown")

        # Resolve requirements
        raw_reqs = job.get("requirements", {})
        registry = TemplateRegistry()
        resolved = resolve_requirements(raw_reqs, registry)
        requirements = resolved.get("requirements", {})

        # Pre-flight: try cloud providers first (use-it-or-lose-it credits), then local
        model = None
        cloud_provider = None

        # Cloud providers first (in config order — put Venice first to burn daily credits)
        if self.cloud_providers:
            for provider in self.cloud_providers:
                provider_models = provider.get("models", [])
                cloud_match = select_model_for_job(provider_models, requirements)
                if cloud_match:
                    model = cloud_match
                    cloud_provider = provider
                    break

            # If still no match but we have cloud providers, use first cloud provider's first model
            if model is None:
                for provider in self.cloud_providers:
                    provider_models = provider.get("models", [])
                    if provider_models:
                        model = provider_models[0]
                        cloud_provider = provider
                        break

        # Fall back to local LM Studio if no cloud match
        if model is None:
            model = select_model_for_job(self._models, requirements)

        if model is None:
            # Re-enqueue to priority stream so dispatcher can try another worker
            priority = job.get("priority", "normal")
            stream_key = priority_stream_key(priority)
            await self._redis.xadd(
                stream_key,
                {"job_id": job_id, "payload": json.dumps(job)},
            )
            logger.warning("No model for job %s — re-enqueued to %s", job_id, stream_key)
            return None

        # Build agent config
        config = build_agent_config(job, self.worker_id)

        # Select LLM backend: cloud provider or local LM Studio
        if cloud_provider:
            llm = OpenAILLM(
                api_key=cloud_provider["api_key"],
                model=model["id"],
                base_url=cloud_provider["endpoint"],
            )
            logger.info("Job %s using cloud provider %s model %s", job_id, cloud_provider.get("name", "cloud"), model["id"])
        else:
            llm = OpenAILLM(
                api_key=self.llm_api_key,
                model=model["id"],
                base_url=self.llm_endpoint,
            )

        # Minimal env config (agent itself doesn't need Redis/Postgres)
        env_config = LaddrConfig(
            queue_backend="memory",
            db_backend="sqlite",
            llm_backend="openai",
        )

        agent_config = AgentConfig(
            name=config["name"],
            role=config["role"],
            goal=config["goal"],
            backstory=config.get("backstory", ""),
            max_iterations=config["max_iterations"],
        )

        agent = CoreAgent(
            config=agent_config,
            env_config=env_config,
            llm=llm,
            instructions=config["instructions"],
        )

        # Run agent — autonomous_run expects a dict with 'query' key
        task_dict = {"query": config["instructions"]}
        result = await agent.autonomous_run(task_dict)

        logger.info("LLM job %s completed on model %s", job_id, model["id"])
        return result

    # ------------------------------------------------------------------
    # Callback
    # ------------------------------------------------------------------

    async def _fire_callback(self, url: str, headers: dict, result: str):
        """POST result to callback URL with 3 retry attempts."""
        import httpx

        delays = [5, 15, 45]
        for attempt in range(3):
            try:
                async with httpx.AsyncClient(timeout=30) as client:
                    resp = await client.post(url, headers=headers, content=result)
                    resp.raise_for_status()
                    return
            except Exception as exc:
                logger.warning(
                    "Callback attempt %d failed for %s: %s", attempt + 1, url, exc
                )
                if attempt < 2:
                    await asyncio.sleep(delays[attempt])
        logger.error("All callback attempts failed for %s", url)

    # ------------------------------------------------------------------
    # Heartbeat
    # ------------------------------------------------------------------

    async def _heartbeat_loop(self, capabilities: dict):
        """Every 30s: refresh models, update registry, reconcile counter."""
        while self._running:
            try:
                await asyncio.sleep(30)
                if not self._running:
                    break

                # Refresh models from LM Studio
                if self.llm_endpoint:
                    try:
                        self._models = await discover_lmstudio_models(self.llm_endpoint)
                    except Exception:
                        pass

                capabilities = self._build_capabilities()
                await self._redis.hset(
                    "laddr:workers:registry",
                    self.worker_id,
                    json.dumps(capabilities),
                )
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("Heartbeat error")

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _build_capabilities(self) -> dict:
        # Merge local models + cloud provider models
        all_models = list(self._models)
        for provider in self.cloud_providers:
            for m in provider.get("models", []):
                # Tag cloud models with their provider
                model_entry = dict(m)
                model_entry.setdefault("provider", provider.get("name", "cloud"))
                model_entry.setdefault("loaded", True)
                all_models.append(model_entry)

        return {
            "worker_id": self.worker_id,
            "node": self.node,
            "models": all_models,
            "mcps": self.config.get("mcps", []),
            "skills": self.config.get("skills", []),
            "max_concurrent": self.max_concurrent,
            "active_jobs": self._active_jobs,
            "last_heartbeat": time.time(),
        }

    def _shutdown(self):
        """Signal handler — set running flag to False."""
        logger.info("Shutdown signal received for worker %s", self.worker_id)
        self._running = False

    async def _deregister(self):
        """Remove worker from registry and active counter."""
        try:
            await self._redis.hdel("laddr:workers:registry", self.worker_id)
            await self._redis.delete(f"laddr:active:{self.worker_id}")
        except Exception:
            logger.exception("Deregister error")
