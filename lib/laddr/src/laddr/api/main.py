"""
FastAPI server for Laddr.

Refactored API with:
- New REST endpoints for jobs, agents, traces, metrics
- WebSocket for real-time events (throttled)
- No OTEL/Prometheus (internal observability only)
- Uses new Agent/AgentRunner architecture
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
from datetime import datetime
import importlib
import json
import logging
import time
import uuid
from typing import Any

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

try:
    import docker
    DOCKER_AVAILABLE = True
except ImportError:
    DOCKER_AVAILABLE = False
    logger.warning("Docker SDK not available. Container logs endpoints will be disabled.")

from laddr import __version__ as pkg_version
from laddr.api.mission_control import router as mission_control_router, set_deps as set_mc_deps
from laddr.core import (
    AgentRunner,
    BackendFactory,
    LaddrConfig,
    run_agent,
)
from laddr.core.langfuse_tracer import get_langfuse_client
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Depends, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel


# Request/Response models
class SubmitJobRequest(BaseModel):
    """Request to submit a new job (legacy)."""
    pipeline_name: str
    inputs: dict[str, Any]


class SubmitPromptRequest(BaseModel):
    """Request to submit a new prompt execution."""
    prompt_name: str
    inputs: dict[str, Any]
    mode: str = "single"  # "single" or "sequential"
    agents: list[str] | None = None  # For sequential mode: ordered list of agents


class CancelPromptResponse(BaseModel):
    ok: bool
    prompt_id: str
    status: str


class ReplayJobRequest(BaseModel):
    """Request to replay a job."""
    reexecute: bool = False


class AgentChatRequest(BaseModel):
    """Request to chat with an agent."""
    message: str
    wait: bool = True
    timeout: int = 30


class BatchTasksRequest(BaseModel):
    """Request to submit multiple tasks to an agent's queue."""
    tasks: list[dict[str, Any]]  # List of task payloads
    wait: bool = False  # Whether to wait for responses
    batch_id: str | None = None  # Optional: use existing batch_id for trace grouping


class AddTasksToBatchRequest(BaseModel):
    """Request to add more tasks to an existing batch."""
    agent_name: str  # Agent to run (e.g., "aggregator")
    tasks: list[dict[str, Any]]  # Tasks to add (usually 1 task for aggregator)
    wait: bool = False


class AgentInfo(BaseModel):
    """Agent information."""
    name: str
    role: str
    goal: str
    status: str
    tools: list[str]
    last_seen: str | None = None
    trace_count: int = 0
    last_executed: str | None = None


# Capability routing request models
from pydantic import Field as PydanticField


class SubmitCapabilityJobRequest(BaseModel):
    system_prompt: str
    user_prompt: str = ""
    inputs: dict = PydanticField(default_factory=dict)
    requirements: dict = PydanticField(default_factory=dict)
    priority: str = "normal"
    timeout_seconds: int = 300
    max_iterations: int = 5
    max_tool_calls: int = 20
    callback_url: str | None = None
    callback_headers: dict = PydanticField(default_factory=dict)


class SubmitScriptJobRequest(BaseModel):
    """Request body for submitting a direct script execution job."""
    command: str
    timeout_seconds: int = 300
    experiment_id: str | None = None
    env: dict = PydanticField(default_factory=dict)
    priority: str = "normal"
    callback_url: str | None = None
    callback_headers: dict = PydanticField(default_factory=dict)


class JobTemplateRequest(BaseModel):
    name: str
    description: str = ""
    requirements: dict = PydanticField(default_factory=dict)
    defaults: dict = PydanticField(default_factory=dict)


class ModelAliasRequest(BaseModel):
    canonical: str
    aliases: dict = PydanticField(default_factory=dict)
    family: str = ""


# Global services
config: LaddrConfig
factory: BackendFactory
database: Any
message_bus: Any
_db_executor: Any = None  # ThreadPoolExecutor for non-blocking DB calls


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize and cleanup services."""
    global config, factory, database, message_bus, _db_executor
    from concurrent.futures import ThreadPoolExecutor

    # Load configuration
    config = LaddrConfig()
    factory = BackendFactory(config)

    # Initialize services
    database = factory.create_database_backend()
    message_bus = factory.create_queue_backend()

    # Create database tables
    database.create_tables()

    # Create thread pool executor for non-blocking database operations
    _db_executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="db")

    # Inject dependencies into Mission Control WebSocket endpoint
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
    except Exception:
        redis_client = None
    set_mc_deps({
        "worker_registry": None,
        "redis": redis_client,
        "database": database,
        "verify_ws_key": verify_websocket_api_key,
    })

    logger.info("Laddr API server started")
    logger.info(f"Database: {config.database_url}")
    logger.info(f"Queue: {config.queue_backend}")

    yield

    # Shutdown executor
    if _db_executor:
        _db_executor.shutdown(wait=True)

    logger.info("Laddr API server shutting down")


async def _run_sequential_chain(runner: AgentRunner, agent_names: list[str], inputs: dict, job_id: str) -> dict:
    """
    Run agents sequentially, piping output from one to the next.
    
    Args:
        runner: AgentRunner instance
        agent_names: List of agent names in execution order
        inputs: Initial inputs
        job_id: Job ID to use for all agents in the chain
    
    Returns:
        Final result dict with sequential execution metadata
    """
    current_input = inputs
    last_result = None
    results = []
    
    for agent_name in agent_names:
        try:
            result = await runner.run(current_input, agent_name=agent_name, job_id=job_id)
            
            if result.get("status") == "error":
                return {
                    "status": "error",
                    "error": f"Sequential chain failed at {agent_name}: {result.get('error')}",
                    "agent": agent_name,
                    "results": results
                }
            
            # Extract result for next agent
            last_result = result.get("result", result)
            results.append({
                "agent": agent_name,
                "result": last_result
            })
            
            # Next agent receives previous output
            if isinstance(last_result, dict):
                current_input = last_result
            else:
                current_input = {"input": last_result, "text": str(last_result)}
        
        except Exception as e:
            return {
                "status": "error",
                "error": f"Sequential chain failed at {agent_name}: {e}",
                "agent": agent_name,
                "results": results
            }
    
    return {
        "status": "success",
        "result": last_result,
        "mode": "sequential",
        "agents": agent_names,
        "results": results
    }


# Create FastAPI app
app = FastAPI(
    title="Laddr API",
    description="API for Laddr distributed agent framework",
    version=pkg_version,
    lifespan=lifespan,
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://dashboard:5173",
        "*",  # Configure appropriately for production
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# API Key Authentication Dependency
def verify_api_key(request: Request) -> None:
    """
    Verify API key from request headers.
    If LADDR_API_KEY is not set, authentication is disabled (no-op).
    If LADDR_API_KEY is set, validates the key from X-API-Key or Authorization header.
    Raises HTTPException(401) if invalid or missing.
    """
    # If API key is not configured, skip authentication
    if not config.laddr_api_key:
        return
    
    # Extract API key from headers
    api_key = request.headers.get("X-API-Key")
    if not api_key:
        # Fallback to Authorization: Bearer <key>
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            api_key = auth_header[7:].strip()
    
    # Validate API key
    if not api_key or api_key != config.laddr_api_key:
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing API key"
        )


# Alias for cleaner usage in route decorators
require_api_key = Depends(verify_api_key)

# Mount sub-routers
app.include_router(mission_control_router)


def _merge_batch_inputs(existing_inputs: dict | None, new_tasks: list[dict[str, Any]]) -> dict:
    """Merge new tasks into the stored batch inputs."""
    merged: dict[str, Any] = {}
    if isinstance(existing_inputs, dict):
        merged = dict(existing_inputs)
    existing_tasks = []
    if isinstance(merged.get("tasks"), list):
        existing_tasks = list(merged["tasks"])
    existing_tasks.extend(new_tasks)
    merged["tasks"] = existing_tasks
    return merged


async def verify_websocket_api_key(websocket: WebSocket) -> None:
    """
    Verify API key for WebSocket connections.
    Checks query parameter 'api_key' or 'X-API-Key' header.
    If LADDR_API_KEY is not set, authentication is disabled.
    """
    # If API key is not configured, skip authentication
    if not config.laddr_api_key:
        return
    
    # Extract API key from query parameter or headers
    api_key = websocket.query_params.get("api_key")
    if not api_key:
        # Fallback to X-API-Key header
        api_key = websocket.headers.get("X-API-Key")
    if not api_key:
        # Fallback to Authorization: Bearer <key>
        auth_header = websocket.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            api_key = auth_header[7:].strip()
    
    # Validate API key
    if not api_key or api_key != config.laddr_api_key:
        await websocket.close(code=1008, reason="Invalid or missing API key")
        raise ValueError("Invalid or missing API key")


@app.get("/")
async def root():
    """Root endpoint - API information."""
    return {
        "service": "Laddr API",
        "version": pkg_version,
        "status": "running",
        "dashboard": "http://localhost:5173",
        "docs": "/docs",
    }


@app.get("/api/health")
async def health():
    """Return API health status with system components."""
    # Determine database type
    db_type = "PostgreSQL" if "postgresql" in config.database_url else "SQLite"
    
    # Determine storage type from endpoint
    if "s3.amazonaws.com" in config.storage_endpoint:
        storage_type = "AWS S3"
    elif ":" in config.storage_endpoint and not config.storage_secure:
        storage_type = "MinIO"  # Local MinIO typically uses port like :9000
    else:
        storage_type = "S3-Compatible"
    
    # Get queue backend
    queue_type = config.queue_backend.upper()

    # Tracing status
    tracing_backend = "disabled"
    tracing_enabled = False
    try:
        # First, detect Langfuse client if integration is enabled.
        if getattr(config, "langfuse_enabled", True):
            lf_client = get_langfuse_client()
            if lf_client is not None:
                tracing_backend = "langfuse"
                tracing_enabled = True
        # If Langfuse is not configured, fall back to DB-based tracing.
        if not tracing_enabled and getattr(config, "enable_tracing", True) and getattr(
            database, "tracing_backend_enabled", False
        ):
            tracing_backend = "database"
            tracing_enabled = True
    except Exception:
        # Health endpoint must never fail because of tracing introspection
        tracing_backend = "unknown"
        tracing_enabled = False

    return {
        "status": "ok",
        "version": "0.8.6",
        "components": {
            "database": db_type,
            "storage": storage_type,
            "message_bus": queue_type,
            "tracing": {
                "enabled": tracing_enabled,
                "backend": tracing_backend,
            },
        },
    }


@app.post("/api/jobs")
async def submit_job(request: SubmitJobRequest, _: None = require_api_key):
    """
    Submit a new job for execution.

    Creates job, executes agent, stores results and traces.

    Args:
        request: Job submission request

    Returns:
        Job result with job_id, status, result/error
    """
    try:
        result = await run_agent(
            agent_name=request.pipeline_name,
            inputs=request.inputs,
            env_config=config
        )

        return {
            "job_id": result["job_id"],
            "status": result["status"],
            "result": result.get("result"),
            "error": result.get("error"),
            "duration_ms": result.get("duration_ms"),
            "agent": result.get("agent")
        }

    except Exception as e:
        logger.error(f"Error submitting job: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/jobs/{job_id}")
async def get_job(job_id: str, _: None = require_api_key):
    """
    Get job status and result.

    Args:
        job_id: Job identifier

    Returns:
        Job information
    """
    try:
        result = database.get_result(job_id)

        if not result:
            raise HTTPException(status_code=404, detail="Job not found")

        # Aggregate token usage
        usage = {}
        try:
            usage = database.get_token_usage(job_id)
        except Exception:
            usage = {}

        return {
            "job_id": job_id,
            "status": result.get("status"),
            "pipeline_name": result.get("pipeline_name"),
            "inputs": result.get("inputs"),
            "outputs": result.get("outputs"),
            "error": result.get("error"),
            "created_at": result.get("created_at"),
            "completed_at": result.get("completed_at"),
            "token_usage": usage,
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to fetch job")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/jobs")
async def list_jobs(limit: int = 50, offset: int = 0, _: None = require_api_key):
    """
    List recent jobs.

    Args:
        limit: Maximum number of jobs to return
        offset: Number of jobs to skip

    Returns:
        List of jobs
    """
    try:
        # DatabaseService currently supports only limit; offset not implemented
        jobs = database.list_jobs(limit=limit)

        return {
            "jobs": [
                {
                    "job_id": job.get("job_id"),
                    "status": job.get("status"),
                    "pipeline_name": job.get("pipeline_name"),
                    "created_at": job.get("created_at"),
                    "completed_at": job.get("completed_at")
                }
                for job in jobs
            ],
            "limit": limit,
            "offset": offset
        }

    except Exception as e:
        logger.exception("Failed to list jobs")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/jobs/{job_id}/replay")
async def replay_job(job_id: str, request: ReplayJobRequest, _: None = require_api_key):
    """
    Replay a previous job.

    Args:
        job_id: Job identifier
        request: Replay configuration

    Returns:
        Job result (stored or re-executed)
    """
    try:
        runner = AgentRunner(env_config=config)
        result = runner.replay(job_id, reexecute=request.reexecute)

        return result

    except Exception as e:
        logger.exception("Failed to replay job")
        raise HTTPException(status_code=500, detail=str(e))


# --- New Prompt Endpoints (preferred terminology) ---

@app.post("/api/prompts")
async def submit_prompt(request: SubmitPromptRequest, _: None = require_api_key):
    """
    Submit a new prompt execution (non-blocking).

    - Creates a prompt record immediately
    - Kicks off background agent execution using the same prompt_id as job_id
    - Returns promptly with status 'running' and the prompt_id
    - Supports sequential mode: runs multiple agents in order, piping output
    """
    try:
        # Create prompt record first and mark as running
        prompt_id = database.create_prompt(None, request.prompt_name, request.inputs)
        database.update_prompt_status(prompt_id, "running")

        async def _run_in_background(pid: str):
            try:
                runner = AgentRunner(env_config=config)
                
                # Sequential mode: run multiple agents in order
                if request.mode == "sequential" and request.agents and len(request.agents) > 1:
                    result = await _run_sequential_chain(runner, request.agents, request.inputs, pid)
                else:
                    # Single agent mode (default)
                    # For single-mode prompt executions initiated from the API UI,
                    # disable delegation for non-coordinator agents to prevent unwanted
                    # cross-agent delegation (e.g., researcher delegating to coordinator).
                    # However, allow delegation if the user is directly prompting the
                    # coordinator, since delegation is the coordinator's primary function.
                    inputs_for_run = dict(request.inputs or {})
                    
                    # Only disable delegation if NOT prompting the coordinator
                    if request.prompt_name != "coordinator":
                        inputs_for_run["_allow_delegation"] = False

                    result = await runner.run(
                        inputs=inputs_for_run,
                        agent_name=request.prompt_name,
                        job_id=pid,
                    )

                # Map status to prompt status
                status = result.get("status", "failed")
                outputs = result.get("result") or {}
                error = result.get("error")

                # Prefer explicit outputs; if only error present, store that
                if error and not outputs:
                    outputs = {"error": error}

                # Normalize success to 'completed'
                prompt_status = "completed" if status == "success" else status
                # Sanitize outputs before saving to prevent JSON serialization errors
                from laddr.core.runtime_entry import _sanitize_for_json
                sanitized_outputs = _sanitize_for_json(outputs)
                database.save_prompt_result(pid, sanitized_outputs, status=prompt_status)
            except Exception as e:
                logger.exception("Background prompt run failed")
                from laddr.core.runtime_entry import _sanitize_for_json
                sanitized_error = _sanitize_for_json({"error": str(e)})
                database.save_prompt_result(pid, sanitized_error, status="failed")

        # Fire-and-forget background task
        asyncio.create_task(_run_in_background(prompt_id))

        return {
            "prompt_id": prompt_id,
            "status": "running",
            "agent": request.prompt_name,
            "mode": request.mode,
            "agents": request.agents if request.mode == "sequential" else [request.prompt_name]
        }

    except Exception as e:
        logger.error(f"Error submitting prompt: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/prompts/{prompt_id}")
async def get_prompt(prompt_id: str, _: None = require_api_key):
    """
    Get prompt execution status and result.

    Args:
        prompt_id: Prompt execution identifier

    Returns:
        Prompt information
    """
    try:
        result = database.get_prompt_result(prompt_id)

        if not result:
            raise HTTPException(status_code=404, detail="Prompt execution not found")

        # Aggregate token usage for this prompt/job
        usage = {}
        try:
            usage = database.get_token_usage(prompt_id)
        except Exception:
            usage = {}

        return {
            "prompt_id": prompt_id,
            "status": result.get("status"),
            "prompt_name": result.get("prompt_name"),
            "inputs": result.get("inputs"),
            "outputs": result.get("outputs"),
            "error": result.get("error"),
            "created_at": result.get("created_at"),
            "completed_at": result.get("completed_at"),
            "token_usage": usage,
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to fetch prompt")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/prompts")
async def list_prompts(limit: int = 50, _: None = require_api_key):
    """
    List recent prompt executions.

    Args:
        limit: Maximum number of prompts to return

    Returns:
        List of prompt executions
    """
    try:
        prompts = database.list_prompts(limit=limit)

        return {
            "prompts": [
                {
                    "prompt_id": prompt.get("prompt_id"),
                    "status": prompt.get("status"),
                    "prompt_name": prompt.get("prompt_name"),
                    "created_at": prompt.get("created_at"),
                    "completed_at": prompt.get("completed_at")
                }
                for prompt in prompts
            ],
            "limit": limit
        }

    except Exception as e:
        logger.exception("Failed to list prompts")
        raise HTTPException(status_code=500, detail=str(e))


# --- Legacy Job Endpoints (backward compatibility) ---

@app.get("/api/agents")
async def list_agents(_: None = require_api_key):
    """
    List registered agents.

    Returns:
        List of agents with metadata, trace counts, and last execution time
    """
    try:
        # Query database for agent metadata (registered by workers)
        agents_list = database.list_agents()

        return {
            "agents": [
                AgentInfo(
                    name=agent["agent_name"],
                    role=agent["metadata"].get("role", "unknown"),
                    goal=agent["metadata"].get("goal", ""),
                    status=agent["metadata"].get("status", "unknown"),
                    tools=agent["metadata"].get("tools", []),
                    last_seen=agent.get("last_seen"),
                    trace_count=agent.get("trace_count", 0),
                    last_executed=agent.get("last_executed")
                ).dict()
                for agent in agents_list
            ]
        }

    except Exception as e:
        logger.exception("Failed to list agents")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/agents/{agent_name}/chat")
async def chat_with_agent(agent_name: str, request: AgentChatRequest, _: None = require_api_key):
    """
    Send a message to an agent.

    Args:
        agent_name: Agent name
        request: Chat request with message

    Returns:
        Agent response or task_id
    """
    try:
        # Publish task
        task_id = await message_bus.publish_task(
            agent_name,
            {"message": request.message}
        )

        if request.wait:
            # Wait for response
            # Message bus expects positional timeout in seconds (timeout_sec)
            response = await message_bus.wait_for_response(
                task_id,
                request.timeout
            )

            if response:
                return {
                    "task_id": task_id,
                    "status": "completed",
                    "response": response
                }
            return {
                "task_id": task_id,
                "status": "timeout",
                "message": "Agent did not respond in time"
            }
        # Return task_id immediately
        return {
            "task_id": task_id,
            "status": "submitted"
        }

    except Exception as e:
        logger.exception("Failed to chat with agent")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/agents/{agent_name}/batch")
async def batch_submit_tasks(agent_name: str, request: BatchTasksRequest, _: None = require_api_key):
    """
    Submit multiple tasks to an agent's queue in parallel.
    
    Each task will be distributed to available workers via Redis Consumer Groups.
    Each task gets its own unique job_id, but all are grouped under a batch_id.
    
    Returns immediately with task IDs (non-blocking by default).
    """
    try:
        # Generate batch_id (unique identifier for the batch)
        batch_id = request.batch_id or str(uuid.uuid4())
        
        # Check if batch already exists
        existing_batch = database.get_batch(batch_id)
        is_new_batch = existing_batch is None
        
        task_ids = []
        job_ids = []  # Each task gets its own job_id
        trace_ids = []  # Each task gets its own trace_id
        
        for i, task_payload in enumerate(request.tasks):
            # Generate unique job_id and trace_id for each task
            job_id = str(uuid.uuid4())  # Unique job_id for each task
            trace_id = str(uuid.uuid4())  # Unique trace_id for each task
            job_ids.append(job_id)
            trace_ids.append(trace_id)
            
            # Include job_id, trace_id, and batch_id in task payload
            task_with_job = {
                **task_payload,
                "job_id": job_id,  # Unique job_id for each task
                "trace_id": trace_id,  # Unique trace_id for each task
                "_batch_id": batch_id,  # Link back to the batch
                "_batch_index": (existing_batch["task_count"] if existing_batch else 0) + i,
            }
            
            task_id = await message_bus.publish_task(agent_name, task_with_job)
            task_ids.append(task_id)
            
            logger.debug(
                f"Published task {i+1}/{len(request.tasks)} to {agent_name}: "
                f"task_id={task_id}, job_id={job_id}, trace_id={trace_id}, batch_id={batch_id}"
            )
        
        # Create or update batch entry in database
        if is_new_batch:
            # Create new batch entry
            database.create_batch(
                batch_id=batch_id,
                agent_name=agent_name,
                task_count=len(request.tasks),
                job_ids=job_ids,
                task_ids=task_ids,
                inputs={"tasks": request.tasks},
            )
            # Update status to "submitted" if not waiting
            if not request.wait:
                database.update_batch_status(batch_id, "submitted")
        else:
            # Add tasks to existing batch (batch_id was provided, reuse existing batch)
            database.add_tasks_to_batch(
                batch_id,
                job_ids,
                task_ids,
                inputs=_merge_batch_inputs(existing_batch.get("inputs"), request.tasks),
            )
        
        logger.info(f"Published {len(task_ids)} tasks to {agent_name} workers with batch_id={batch_id}")
        
        if request.wait:
            # Wait for all responses
            results = []
            for task_id in task_ids:
                response = await message_bus.wait_for_response(task_id, timeout_sec=300)
                results.append({
                    "task_id": task_id,
                    "response": response
                })
            
            # Update batch status
            database.update_batch_status(
                batch_id,
                "completed",
                outputs={"results": results}
            )
            
            return {
                "batch_id": batch_id,
                "agent_name": agent_name,
                "status": "completed",
                "task_count": len(job_ids),
                "task_ids": task_ids,
                "job_ids": job_ids,
                "trace_ids": trace_ids,
                "results": results
            }
        
        return {
            "batch_id": batch_id,
            "agent_name": agent_name,
            "status": "submitted",
            "task_count": len(job_ids),
            "task_ids": task_ids,
            "job_ids": job_ids,
            "trace_ids": trace_ids
        }
    
    except Exception as e:
        logger.exception("Failed to batch submit tasks")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/batches/{batch_id}/add-tasks")
async def add_tasks_to_batch(batch_id: str, request: AddTasksToBatchRequest, _: None = require_api_key):
    """
    Add more tasks to an existing batch.
    
    Useful for adding an aggregator agent to a batch after evaluator workers complete.
    Each new task gets its own unique job_id, but all are grouped under the batch_id.
    """
    try:
        # Verify batch exists and is still running
        batch = database.get_batch(batch_id)
        if not batch:
            raise HTTPException(status_code=404, detail="Batch not found")
        if batch["status"] not in ("running", "submitted"):
            raise HTTPException(
                status_code=400,
                detail=f"Cannot add tasks to batch with status: {batch['status']}"
            )
        
        # Generate new job_ids and trace_ids for the new tasks
        new_job_ids = []
        new_trace_ids = []
        new_task_ids = []
        
        for i, task_payload in enumerate(request.tasks):
            job_id = str(uuid.uuid4())  # Unique job_id for each new task
            trace_id = str(uuid.uuid4())
            new_job_ids.append(job_id)
            new_trace_ids.append(trace_id)
            
            # Each task gets its own job_id, but links back to the batch
            task_with_job = {
                **task_payload,
                "job_id": job_id,  # Unique job_id for each task
                "trace_id": trace_id,
                "_batch_id": batch_id,  # Link back to the batch
                "_batch_index": batch["task_count"] + i,  # Continue indexing
            }
            
            task_id = await message_bus.publish_task(request.agent_name, task_with_job)
            new_task_ids.append(task_id)
            
            logger.debug(
                f"Added task {i+1}/{len(request.tasks)} to batch {batch_id}: "
                f"task_id={task_id}, job_id={job_id}, trace_id={trace_id}"
            )
        
        # Update batch record with new job_ids, task_ids, and merged inputs
        database.add_tasks_to_batch(
            batch_id,
            new_job_ids,
            new_task_ids,
            inputs=_merge_batch_inputs(batch.get("inputs"), request.tasks),
        )
        
        if request.wait:
            # Wait for all responses
            results = []
            for task_id in new_task_ids:
                response = await message_bus.wait_for_response(task_id, timeout_sec=300)
                results.append({
                    "task_id": task_id,
                    "response": response
                })
            
            return {
                "batch_id": batch_id,
                "status": batch["status"],
                "added_job_ids": new_job_ids,
                "added_trace_ids": new_trace_ids,
                "added_task_ids": new_task_ids,
                "total_tasks": batch["task_count"] + len(new_task_ids),
                "total_job_ids": len(batch["job_ids"]) + len(new_job_ids),
                "results": results,
            }
        
        updated_batch = database.get_batch(batch_id)
        return {
            "batch_id": batch_id,
            "status": updated_batch["status"] if updated_batch else batch["status"],
            "added_job_ids": new_job_ids,
            "added_trace_ids": new_trace_ids,
            "added_task_ids": new_task_ids,
            "total_tasks": updated_batch["task_count"] if updated_batch else batch["task_count"] + len(new_task_ids),
            "total_job_ids": len(updated_batch["job_ids"]) if updated_batch else len(batch["job_ids"]) + len(new_job_ids),
        }
    
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to add tasks to batch")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/batches/{batch_id}")
async def get_batch(batch_id: str, _: None = require_api_key):
    """Get batch metadata by ID."""
    batch = database.get_batch(batch_id)
    if not batch:
        raise HTTPException(status_code=404, detail="Batch not found")
    return batch


@app.get("/api/batches")
async def list_batches(limit: int = 50, _: None = require_api_key):
    """List recent batches."""
    batches = database.list_batches(limit=limit)
    return {"batches": batches, "limit": limit}


@app.get("/api/agents/{agent_name}/tools")
async def get_agent_tools(agent_name: str, _: None = require_api_key):
    """
    Get detailed tool information for a specific agent.

    Args:
        agent_name: Agent name

    Returns:
        List of tools with name, description, and parameters schema
    """
    try:
        # Get agent metadata
        agents_list = database.list_agents()
        agent_data = next((a for a in agents_list if a["agent_name"] == agent_name), None)
        
        if not agent_data:
            raise HTTPException(status_code=404, detail="Agent not found")
        
        # Load the agent module to access tool registry
        try:
            # Import the agent module dynamically
            agent_module = importlib.import_module(f"agents.{agent_name}")
            agent_instance = getattr(agent_module, agent_name, None)
            
            if agent_instance and hasattr(agent_instance, 'tools'):
                # Ensure MCP tools are registered if agent has MCP providers
                # This is needed because MCP tools are registered asynchronously
                if hasattr(agent_instance, '_mcp_providers') and agent_instance._mcp_providers:
                    try:
                        # Directly register MCP tools without requiring full agent initialization
                        # This works even if agent hasn't called connect_bus() yet
                        for provider in agent_instance._mcp_providers:
                            if not provider.is_connected():
                                try:
                                    await asyncio.wait_for(provider.connect(), timeout=5.0)
                                except Exception as conn_err:
                                    logger.debug(f"Could not connect to MCP server {provider.server_name}: {conn_err}")
                                    continue
                            
                            # Register tools directly into the agent's tool registry
                            try:
                                await asyncio.wait_for(
                                    provider.register_tools(agent_instance.tools),
                                    timeout=3.0
                                )
                            except Exception as reg_err:
                                logger.debug(f"Could not register MCP tools from {provider.server_name}: {reg_err}")
                    except Exception as e:
                        logger.debug(f"Could not register MCP tools for API query: {e}")
                
                tools_list = []
                # Check if tools is a ToolRegistry
                if hasattr(agent_instance.tools, 'list'):
                    # It's a ToolRegistry, use the list() method
                    for tool_obj in agent_instance.tools.list():
                        tools_list.append({
                            "name": tool_obj.name,
                            "description": tool_obj.description,
                            "parameters": tool_obj.parameters_schema or {}
                        })
                else:
                    # It's a list of tools
                    for tool_obj in agent_instance.tools:
                        # Extract tool metadata
                        if hasattr(tool_obj, '__laddr_tool__'):
                            tool_meta = tool_obj.__laddr_tool__
                            tools_list.append({
                                "name": tool_meta.name,
                                "description": tool_meta.description,
                                "parameters": tool_meta.parameters_schema or {}
                            })
                        elif callable(tool_obj):
                            # Fallback for tools without decorator
                            tools_list.append({
                                "name": getattr(tool_obj, '__name__', str(tool_obj)),
                                "description": (getattr(tool_obj, '__doc__', '') or '').strip().split('\n')[0],
                                "parameters": {}
                            })
                
                return {"agent": agent_name, "tools": tools_list}
        except ImportError:
            # Agent module not found, fall back to tool names only
            pass
        
        # Fallback: return tool names from metadata with placeholder descriptions
        tool_names = agent_data["metadata"].get("tools", [])
        return {
            "agent": agent_name,
            "tools": [
                {"name": name, "description": f"Tool: {name}", "parameters": {}}
                for name in tool_names
            ]
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.exception(f"Failed to get tools for agent {agent_name}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/responses/{task_id}/resolved")
async def get_resolved_response(task_id: str, _: None = require_api_key):
    """
    Resolve and return a task response. If the response was offloaded to storage,
    this endpoint fetches the full payload from MinIO/S3 and returns it.

    Args:
        task_id: Task identifier as returned by delegation/chat APIs

    Returns:
        JSON object containing either the inline response or the resolved payload
        when the response was offloaded. Shape:
        {
          "task_id": str,
          "offloaded": bool,
          "pointer": {"bucket": str, "key": str, "size_bytes": int} | None,
          "data": Any  # full response payload
        }
    """
    try:
        # Try to read existing response without blocking
        response: dict | None = None

        # MemoryBus fast-path
        if hasattr(message_bus, "_responses"):
            try:
                response = getattr(message_bus, "_responses", {}).get(task_id)
            except Exception:
                response = None

        # RedisBus path: read key directly to avoid pub/sub
        if response is None and hasattr(message_bus, "_get_client"):
            try:
                client = await message_bus._get_client()  # type: ignore[attr-defined]
                raw = await client.get(f"laddr:response:{task_id}")
                if raw:
                    response = json.loads(raw)
            except Exception:
                response = None

        # Fallback minimal wait
        if response is None:
            with suppress(Exception):
                response = await message_bus.wait_for_response(task_id, 1)

        if not response:
            raise HTTPException(status_code=404, detail="Response not found or expired")

        # If it's a pointer to offloaded content, fetch and return full data
        if isinstance(response, dict) and response.get("offloaded") and response.get("bucket") and response.get("key"):
            bucket = response.get("bucket")
            key = response.get("key")

            storage = factory.create_storage_backend()
            try:
                blob = await storage.get_object(bucket, key)
                try:
                    data = json.loads(blob.decode("utf-8"))
                except Exception:
                    # Return raw text if not valid JSON
                    data = blob.decode("utf-8", errors="replace")
            except Exception as e:
                raise HTTPException(status_code=502, detail=f"Failed to fetch offloaded artifact: {e}")

            return {
                "task_id": task_id,
                "offloaded": True,
                "pointer": {
                    "bucket": bucket,
                    "key": key,
                    "size_bytes": response.get("size_bytes")
                },
                "data": data
            }

        # Inline payload already present
        return {
            "task_id": task_id,
            "offloaded": False,
            "pointer": None,
            "data": response
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to resolve response")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/jobs/{job_id}/result", dependencies=[require_api_key])
async def get_job_result(job_id: str):
    """Poll for a job result.

    Workers store results at ``laddr:results:{job_id}`` in Redis (30 min TTL)
    and optionally in MinIO at ``results/{job_id}.json``.

    Returns 200 with the result if ready, 202 if still pending, 404 if expired.
    Agents should poll this endpoint until they get a 200.
    """
    try:
        # 1. Try Redis (fast, 30min TTL)
        if hasattr(message_bus, "_get_client"):
            client = await message_bus._get_client()  # type: ignore[attr-defined]
            raw = await client.get(f"laddr:results:{job_id}")
            if raw:
                return json.loads(raw)

        # 2. Try MinIO (permanent storage)
        try:
            storage = factory.create_storage_backend()
            minio_key = f"results/{job_id}.json"
            bucket = config.storage_bucket or config.minio_bucket or "laddr"
            if await storage.object_exists(bucket, minio_key):
                blob = await storage.get_object(bucket, minio_key)
                return json.loads(blob)
        except Exception:
            pass

        # 3. Check if job exists but hasn't completed yet
        prompt = database.get_prompt_result(job_id)
        if prompt:
            status = prompt.get("status", "unknown")
            if status in ("pending", "running"):
                return JSONResponse(
                    status_code=202,
                    content={"job_id": job_id, "status": status, "message": "Job is still running"}
                )
            if status == "failed":
                return {
                    "job_id": job_id,
                    "status": "failed",
                    "error": prompt.get("error") or prompt.get("outputs", {}).get("error", "Unknown error"),
                }

        # Not found anywhere
        raise HTTPException(status_code=404, detail="Result not found — job may have expired or never existed")

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to get job result")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/traces")
async def list_traces(
    job_id: str | None = None,
    _: None = require_api_key,
    agent_name: str | None = None,
    limit: int = 100,
):
    """List trace events with optional filters and include payload."""
    try:
        if job_id:
            traces = database.get_job_traces(job_id)
        else:
            traces = database.list_traces(agent=agent_name, limit=limit)

        return {"traces": traces}

    except Exception as e:
        logger.exception("Failed to list traces")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/traces/grouped")
async def get_grouped_traces(limit: int = 50, _: None = require_api_key):
    """
    Get traces grouped by job_id.
    
    Returns traces organized by job_id, showing complete multi-agent runs together.
    Each group contains all traces (coordinator, researcher, etc.) for that job.
    """
    try:
        # Get recent traces with job_id
        all_traces = database.list_traces(limit=limit * 10)  # Get more to ensure we have enough jobs
        
        # Group traces by job_id
        grouped: dict[str, list] = {}
        for trace in all_traces:
            job_id = trace.get('job_id')
            if job_id:
                if job_id not in grouped:
                    grouped[job_id] = []
                grouped[job_id].append(trace)
        
        # Convert to list format with metadata
        result = []
        for job_id, traces in list(grouped.items())[:limit]:
            # Sort traces by timestamp
            traces.sort(key=lambda t: t.get('timestamp', ''))
            
            # Extract metadata
            agents = list(set(t.get('agent_name') for t in traces if t.get('agent_name')))
            start_time = traces[0].get('timestamp') if traces else None
            end_time = traces[-1].get('timestamp') if traces else None
            
            result.append({
                'job_id': job_id,
                'trace_count': len(traces),
                'agents': agents,
                'start_time': start_time,
                'end_time': end_time,
                'traces': traces
            })
        
        # Sort by most recent first
        result.sort(key=lambda g: g.get('start_time', ''), reverse=True)
        
        return {'grouped_traces': result}
        
    except Exception as e:
        logger.exception("Failed to get grouped traces")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/traces/{trace_id}")
async def get_trace(trace_id: str, _: None = require_api_key):
    """Get a single trace by id with full payload."""
    try:
        trace = database.get_trace(trace_id)
        if not trace:
            raise HTTPException(status_code=404, detail="Trace not found")
        return trace
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to get trace")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/metrics")
async def get_metrics(_: None = require_api_key):
    """
    Get system metrics.

    Returns:
        Aggregated metrics from traces and jobs
    """
    try:
        metrics = database.get_metrics()

        return {
            "total_jobs": metrics.get("total_jobs", 0),
            "completed_jobs": metrics.get("completed_jobs", 0),
            "failed_jobs": metrics.get("failed_jobs", 0),
            "avg_latency_ms": metrics.get("avg_latency_ms", 0),
            "active_agents_count": metrics.get("active_agents_count", 0),
            "cache_hits": metrics.get("cache_hits", 0),
            "tool_calls": metrics.get("tool_calls", 0),
            "total_tokens": metrics.get("total_tokens", 0),
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }

    except Exception as e:
        logger.exception("Failed to get metrics")
        raise HTTPException(status_code=500, detail=str(e))


# --- Container Logs Endpoints ---

@app.get("/api/logs/containers")
async def list_containers(_: None = require_api_key):
    """
    List all Docker containers (project-agnostic).
    
    Returns containers running in the same Docker network,
    automatically detecting API and worker containers.
    """
    if not DOCKER_AVAILABLE:
        raise HTTPException(
            status_code=503,
            detail="Docker SDK not available. Install with: pip install docker"
        )
    
    try:
        client = docker.from_env()
        
        # Get all running containers
        all_containers = client.containers.list(all=True)
        
        # Group containers by type
        containers_list = []
        
        for container in all_containers:
            # Get container info
            name = container.name
            labels = container.labels
            status = container.status
            
            # Detect container type based on labels or name patterns
            container_type = "other"
            if "api" in name.lower():
                container_type = "api"
            elif "worker" in name.lower() or any(w in name.lower() for w in ["coordinator", "researcher", "analyzer", "writer", "validator"]):
                container_type = "worker"
            elif any(s in name.lower() for s in ["postgres", "redis", "minio", "mysql", "mongo"]):
                container_type = "infrastructure"
            
            # Get compose service name if available
            service_name = labels.get("com.docker.compose.service", name)
            project_name = labels.get("com.docker.compose.project", "")
            
            containers_list.append({
                "id": container.id[:12],
                "name": name,
                "service_name": service_name,
                "project_name": project_name,
                "type": container_type,
                "status": status,
                "image": container.image.tags[0] if container.image.tags else "unknown",
                "created": container.attrs.get("Created", ""),
            })
        
        # Sort: API first, then workers, then infrastructure, then others
        type_order = {"api": 0, "worker": 1, "infrastructure": 2, "other": 3}
        containers_list.sort(key=lambda c: (type_order.get(c["type"], 99), c["name"]))
        
        return {
            "containers": containers_list,
            "total": len(containers_list)
        }
        
    except Exception as e:
        logger.exception("Failed to list containers")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/logs/containers/{container_name}")
async def get_container_logs(
    container_name: str,
    _: None = require_api_key,
    tail: int = 100,
    since: str | None = None,
    timestamps: bool = True
):
    """
    Get logs from a specific container.
    
    Args:
        container_name: Container name or ID
        tail: Number of lines to return (default: 100)
        since: Only logs since this timestamp (e.g., "5m", "1h", or ISO8601)
        timestamps: Include timestamps in logs
    
    Returns:
        Container logs with metadata
    """
    if not DOCKER_AVAILABLE:
        raise HTTPException(
            status_code=503,
            detail="Docker SDK not available. Install with: pip install docker"
        )
    
    try:
        client = docker.from_env()
        
        # Find container by name or ID
        try:
            container = client.containers.get(container_name)
        except docker.errors.NotFound:
            # Try partial match
            containers = client.containers.list(all=True)
            matching = [c for c in containers if container_name in c.name or container_name in c.id]
            if not matching:
                raise HTTPException(status_code=404, detail=f"Container '{container_name}' not found")
            container = matching[0]
        
        # Get logs
        logs_bytes = container.logs(
            tail=tail,
            since=since,
            timestamps=timestamps,
            follow=False
        )
        
        # Decode and parse logs
        logs_text = logs_bytes.decode('utf-8', errors='replace')
        log_lines = []
        
        for line in logs_text.strip().split('\n'):
            if not line:
                continue
            
            # Parse timestamp if present (format: 2024-01-01T12:00:00.000000000Z message)
            if timestamps and ' ' in line:
                parts = line.split(' ', 1)
                if len(parts) == 2 and 'T' in parts[0]:
                    timestamp_str, message = parts
                    log_lines.append({
                        "timestamp": timestamp_str,
                        "message": message
                    })
                else:
                    log_lines.append({
                        "timestamp": "",
                        "message": line
                    })
            else:
                log_lines.append({
                    "timestamp": "",
                    "message": line
                })
        
        return {
            "container": container.name,
            "container_id": container.id[:12],
            "status": container.status,
            "logs": log_lines,
            "total": len(log_lines)
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(f"Failed to get logs for container: {container_name}")
        raise HTTPException(status_code=500, detail=str(e))


@app.websocket("/ws/logs/{container_name}")
async def websocket_container_logs(websocket: WebSocket, container_name: str):
    """
    Stream container logs in real-time via WebSocket.
    
    Args:
        container_name: Container name or ID to stream logs from
    """
    await verify_websocket_api_key(websocket)
    await websocket.accept()
    logger.info(f"WebSocket connected for container logs: {container_name}")
    
    if not DOCKER_AVAILABLE:
        await websocket.send_json({
            "type": "error",
            "data": {"error": "Docker SDK not available"}
        })
        await websocket.close()
        return
    
    try:
        client = docker.from_env()
        
        # Find container
        try:
            container = client.containers.get(container_name)
        except docker.errors.NotFound:
            containers = client.containers.list(all=True)
            matching = [c for c in containers if container_name in c.name or container_name in c.id]
            if not matching:
                await websocket.send_json({
                    "type": "error",
                    "data": {"error": f"Container '{container_name}' not found"}
                })
                await websocket.close()
                return
            container = matching[0]
        
        # Send initial status
        await websocket.send_json({
            "type": "connected",
            "data": {
                "container": container.name,
                "container_id": container.id[:12],
                "status": container.status
            }
        })
        
        # Stream logs
        log_stream = container.logs(
            stream=True,
            follow=True,
            timestamps=True
        )
        
        for log_chunk in log_stream:
            try:
                decoded = log_chunk.decode('utf-8', errors='replace').strip()
                if not decoded:
                    continue
                
                # Parse timestamp
                parts = decoded.split(' ', 1)
                if len(parts) == 2 and 'T' in parts[0]:
                    timestamp_str, message = parts
                else:
                    timestamp_str = ""
                    message = decoded
                
                await websocket.send_json({
                    "type": "log",
                    "data": {
                        "timestamp": timestamp_str,
                        "message": message
                    }
                })
            except WebSocketDisconnect:
                logger.info(f"WebSocket disconnected for container logs: {container_name}")
                break
            except Exception as e:
                logger.error(f"Error processing log line: {e}")
                continue
                
    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected for container logs: {container_name}")
    except Exception as e:
        logger.error(f"WebSocket error for container logs: {e}")
        try:
            await websocket.send_json({
                "type": "error",
                "data": {"error": str(e)}
            })
        except:
            pass
    finally:
        try:
            await websocket.close()
        except:
            pass


# WebSocket for real-time events (throttled)
class EventThrottler:
    """Throttle WebSocket events to avoid overwhelming clients."""

    def __init__(self, max_per_second: int = 10):
        self.max_per_second = max_per_second
        self.last_sent = 0.0
        self.buffer: list[dict] = []

    def add(self, event: dict) -> dict | None:
        """Add event, return it if should be sent immediately."""
        now = time.time()
        elapsed = now - self.last_sent

        if elapsed >= (1.0 / self.max_per_second):
            self.last_sent = now
            return event
        # Buffer for batching
        self.buffer.append(event)
        if len(self.buffer) >= 5:  # Batch size
            batch = self.buffer[:]
            self.buffer.clear()
            self.last_sent = now
            return {"type": "batch", "events": batch}

        return None


@app.websocket("/ws/events")
async def websocket_events(websocket: WebSocket):
    """
    WebSocket endpoint for real-time events.

    Streams job submissions, completions, trace events with throttling.
    """
    await verify_websocket_api_key(websocket)
    await websocket.accept()
    throttler = EventThrottler(max_per_second=10)

    try:
        while True:
            # Poll for recent traces (last 5 seconds)
            traces = database.list_traces(limit=20)
            recent: list[dict] = []
            now = datetime.utcnow()
            for t in traces:
                ts = t.get("timestamp")
                if not ts:
                    continue
                try:
                    # Support ISO strings
                    ts_dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).replace(tzinfo=None)
                    if (now - ts_dt).total_seconds() < 5:
                        recent.append(t)
                except Exception:
                    continue

            for trace in recent:
                event = {
                    "type": "trace",
                    "data": {
                        "job_id": trace.get("job_id"),
                        "agent_name": trace.get("agent_name"),
                        "event_type": trace.get("event_type"),
                        "timestamp": trace.get("timestamp")
                    }
                }

                to_send = throttler.add(event)
                if to_send:
                    await websocket.send_json(to_send)

            # Sleep before next poll
            await asyncio.sleep(0.5)

    except WebSocketDisconnect:
        logger.info("WebSocket client disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")


@app.websocket("/ws/prompts/{prompt_id}")
async def websocket_prompt_traces(websocket: WebSocket, prompt_id: str):
    """
    WebSocket endpoint for live trace streaming for a specific prompt execution.
    
    Sends hierarchical trace spans similar to LangSmith/Langfuse structure.
    """
    try:
        await verify_websocket_api_key(websocket)
        await websocket.accept()
        logger.info(f"WebSocket connected for prompt {prompt_id}")
        # Small delay to ensure connection is fully established
        await asyncio.sleep(0.01)
    except Exception as e:
        logger.error(f"Failed to accept WebSocket connection for {prompt_id}: {e}", exc_info=True)
        return
    
    last_trace_id = 0
    
    def _parse_ts(ts: str | None) -> datetime | None:
        if not ts:
            return None
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).replace(tzinfo=None)
        except Exception:
            return None
    
    def _build_trace_tree(traces: list[dict]) -> list[dict]:
        """
        Build hierarchical trace tree from flat traces.
        Groups by agent runs and nests tool calls/LLM calls within them.
        
        Prevents task_start events from being children of other task_start events.
        """
        # Index traces by ID for quick lookup
        trace_map = {t['id']: t for t in traces}
        roots = []
        
        # First pass: identify parent-child relationships
        # But prevent task_start events from being children of other task_start events
        for trace in traces:
            event_type = trace.get('event_type', '')
            parent_id = trace.get('parent_id')
            
            # Prevent task_start events from being children of other task_start events
            if event_type == 'task_start' and parent_id and parent_id in trace_map:
                parent = trace_map[parent_id]
                parent_event_type = parent.get('event_type', '')
                if parent_event_type == 'task_start':
                    # This task_start should be a root, not a child of another task_start
                    roots.append(trace)
                    continue
            
            if parent_id and parent_id in trace_map:
                parent = trace_map[parent_id]
                if 'children' not in parent:
                    parent['children'] = []
                parent['children'].append(trace)
            else:
                # Root level trace
                roots.append(trace)
        
        # Build span structure
        def build_span(trace: dict) -> dict:
            event_type = trace.get('event_type', '')
            payload = trace.get('payload', {})
            agent_name = trace.get('agent_name', '')
            timestamp = trace.get('timestamp', '')
            
            # Extract metrics
            duration_ms = None
            tokens = None
            cost = None
            
            # Calculate duration if we have start/end events
            if event_type == 'task_complete':
                # Look for matching task_start to calculate duration
                start_trace = next((t for t in traces if t.get('agent_name') == agent_name 
                                   and t.get('event_type') == 'task_start' 
                                   and t.get('id') < trace['id']), None)
                if start_trace:
                    start_ts = _parse_ts(start_trace.get('timestamp'))
                    end_ts = _parse_ts(timestamp)
                    if start_ts and end_ts:
                        duration_ms = int((end_ts - start_ts).total_seconds() * 1000)
            
            # Extract token usage
            if event_type == 'llm_usage' or 'usage' in payload:
                usage = payload.get('usage', payload)
                tokens = usage.get('total_tokens', 0)
                cost = usage.get('cost')
            
            # Build span object
            span = {
                'id': trace['id'],
                'name': agent_name if event_type.startswith('task_') else payload.get('tool', event_type),
                'type': _get_span_type(event_type, payload),
                'start_time': timestamp,
                'agent': agent_name,
                'event_type': event_type,
                'input': payload.get('inputs', payload.get('params', {})),
                'output': payload.get('result', payload.get('outputs')),
                'metadata': {
                    'duration_ms': duration_ms,
                    'tokens': tokens,
                    'cost': cost,
                    **payload
                },
                'children': []
            }
            
            # Add children recursively
            if 'children' in trace:
                span['children'] = [build_span(child) for child in trace['children']]
            
            return span
        
        return [build_span(root) for root in roots]
    
    def _get_span_type(event_type: str, payload: dict) -> str:
        """Determine span type for UI rendering."""
        if event_type.startswith('task_'):
            return 'agent'
        elif event_type in ('tool_call', 'tool_result'):
            return 'tool'
        elif event_type in ('llm_call', 'llm_usage'):
            return 'llm'
        elif 'think' in event_type:
            return 'reasoning'
        else:
            return 'event'
    
    # Get event loop once for all executor calls
    loop = asyncio.get_running_loop()
    last_trace_id = 0
    is_complete = False
    
    # Helper to safely send WebSocket messages
    async def safe_send(data: dict) -> bool:
        try:
            # Try to send - if connection is closed, it will raise an exception
            await websocket.send_json(data)
            logger.debug(f"Sent WebSocket message type={data.get('type')} for prompt {prompt_id}")
            return True
        except RuntimeError as e:
            # RuntimeError usually means connection is closed
            if "closed" in str(e).lower() or "disconnect" in str(e).lower():
                logger.debug(f"WebSocket connection closed for prompt {prompt_id}")
            else:
                logger.warning(f"RuntimeError sending WebSocket message for prompt {prompt_id}: {e}")
            return False
        except Exception as e:
            logger.warning(f"Failed to send WebSocket message for prompt {prompt_id}: {e}", exc_info=True)
            return False
    
    # Load initial traces immediately on connection
    # Note: For prompt executions, prompt_id is used as job_id
    try:
        initial_traces = await loop.run_in_executor(_db_executor, database.get_job_traces, prompt_id)
        logger.info(f"Loaded {len(initial_traces)} initial traces for prompt {prompt_id} (using as job_id)")
        if initial_traces:
            last_trace_id = max(t.get('id', 0) for t in initial_traces)
            trace_tree = _build_trace_tree(initial_traces)
            logger.info(f"Built trace tree with {len(trace_tree)} root spans for prompt {prompt_id}")
            sent = await safe_send({
                "type": "traces",
                "data": {
                    "spans": trace_tree,
                    "count": len(initial_traces)
                }
            })
            if sent:
                logger.info(f"Successfully sent {len(initial_traces)} initial traces for prompt {prompt_id}")
            else:
                logger.warning(f"Failed to send initial traces for prompt {prompt_id} - connection may be closed")
        else:
            logger.info(f"No initial traces found for prompt {prompt_id}")
            # Send empty traces to let frontend know we're connected
            await safe_send({
                "type": "traces",
                "data": {
                    "spans": [],
                    "count": 0
                }
            })
    except Exception as e:
        logger.error(f"Failed to load initial traces for {prompt_id}: {e}", exc_info=True)
    
    # Check initial completion status
    try:
        prompt_result = await loop.run_in_executor(_db_executor, database.get_prompt_result, prompt_id)
        if prompt_result and prompt_result.get('status') in ['completed', 'failed', 'error', 'canceled']:
            is_complete = True
            logger.info(f"Prompt {prompt_id} is already {prompt_result.get('status')}, sending completion event")
            # Send completion event with final tree (all traces)
            all_traces = await loop.run_in_executor(_db_executor, database.get_job_traces, prompt_id)
            final_tree = _build_trace_tree(all_traces)
            sent = await safe_send({
                "type": "complete",
                "data": {
                    "status": prompt_result.get('status'),
                    "outputs": prompt_result.get('outputs'),
                    "error": prompt_result.get('error'),
                    "spans": final_tree
                }
            })
            if sent:
                logger.info(f"Sent completion event for prompt {prompt_id}, closing WebSocket")
            else:
                logger.warning(f"Failed to send completion event for prompt {prompt_id}")
            return
    except Exception as e:
        logger.warning(f"Failed to check prompt status for {prompt_id}: {e}", exc_info=True)
    
    # Poll for new traces while prompt is running
    try:
        while not is_complete:
            # Get all traces for this prompt/job (non-blocking)
            # Note: For prompt executions, prompt_id is used as job_id
            traces = await loop.run_in_executor(_db_executor, database.get_job_traces, prompt_id)
            
            # Filter to only new traces
            new_traces = [t for t in traces if t.get('id', 0) > last_trace_id]
            
            if new_traces:
                # Update last seen ID
                last_trace_id = max(t.get('id', 0) for t in new_traces)
                
                # Build hierarchical tree structure
                trace_tree = _build_trace_tree(new_traces)
                
                logger.debug(f"Sending {len(new_traces)} new traces ({len(trace_tree)} root spans) for prompt {prompt_id}")
                
                # Send tree structure to client
                sent = await safe_send({
                    "type": "traces",
                    "data": {
                        "spans": trace_tree,
                        "count": len(new_traces)
                    }
                })
                if sent:
                    logger.debug(f"Successfully sent {len(new_traces)} new traces for prompt {prompt_id}")
                else:
                    logger.warning(f"Failed to send new traces for prompt {prompt_id} - connection may be closed")
            
            # Check if prompt is complete (non-blocking)
            prompt_result = await loop.run_in_executor(_db_executor, database.get_prompt_result, prompt_id)
            if prompt_result and prompt_result.get('status') in ['completed', 'failed', 'error', 'canceled']:
                is_complete = True
                logger.info(f"Prompt {prompt_id} completed with status {prompt_result.get('status')}")
                # Send completion event with final tree (all traces)
                all_traces = await loop.run_in_executor(_db_executor, database.get_job_traces, prompt_id)
                final_tree = _build_trace_tree(all_traces)
                
                await safe_send({
                    "type": "complete",
                    "data": {
                        "status": prompt_result.get('status'),
                        "outputs": prompt_result.get('outputs'),
                        "error": prompt_result.get('error'),
                        "spans": final_tree
                    }
                })
                logger.info(f"Prompt {prompt_id} completed, closing WebSocket")
                break
            
            # Poll interval
            await asyncio.sleep(0.3)
    
    except WebSocketDisconnect:
        logger.info(f"WebSocket client disconnected for prompt {prompt_id}")
    except Exception as e:
        logger.error(f"WebSocket error for prompt {prompt_id}: {e}", exc_info=True)
        try:
            await websocket.send_json({
                "type": "error",
                "data": {"error": str(e)}
            })
        except:
            pass


@app.websocket("/ws/batches/{batch_id}")
async def websocket_batch_traces(websocket: WebSocket, batch_id: str):
    """
    WebSocket endpoint for live trace streaming for a batch operation.
    
    Continuously fetches traces for all job_ids in the batch and streams them to the client.
    Each job_id represents a separate task/job within the batch.
    """
    try:
        await verify_websocket_api_key(websocket)
        await websocket.accept()
        logger.info(f"WebSocket connected for batch {batch_id}")
        await asyncio.sleep(0.01)
    except Exception as e:
        logger.error(f"Failed to accept WebSocket connection for batch {batch_id}: {e}", exc_info=True)
        return
    
    last_trace_id = 0
    
    def _parse_ts(ts: str | None) -> datetime | None:
        if not ts:
            return None
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).replace(tzinfo=None)
        except Exception:
            return None
    
    def _build_trace_tree(traces: list[dict]) -> list[dict]:
        """Build hierarchical trace tree from flat traces.
        
        For parallel batch tasks:
        - Groups traces by job_id (each task has its own job_id)
        - Each job_id group builds its own tree
        - All task_start events are root-level siblings (one per job_id)
        - Explicit parent_id relationships are preserved within each group
        """
        # Group traces by job_id
        traces_by_job_id: dict[str, list[dict]] = {}
        traces_without_job_id: list[dict] = []
        
        for trace in traces:
            job_id = trace.get('job_id')
            if job_id:
                if job_id not in traces_by_job_id:
                    traces_by_job_id[job_id] = []
                traces_by_job_id[job_id].append(trace)
            else:
                traces_without_job_id.append(trace)
        
        # Build a tree for each job_id group
        all_roots = []
        
        def build_tree_for_group(group_traces: list[dict]) -> list[dict]:
            """Build hierarchical tree for a single job_id group."""
            trace_map = {t['id']: t for t in group_traces}
            roots = []
            
            # First pass: identify parent-child relationships
            # Prevent task_start events from being children of other task_start events
            for trace in group_traces:
                event_type = trace.get('event_type', '')
                parent_id = trace.get('parent_id')
                
                # Prevent task_start events from being children of other task_start events
                if event_type == 'task_start' and parent_id and parent_id in trace_map:
                    parent = trace_map[parent_id]
                    parent_event_type = parent.get('event_type', '')
                    if parent_event_type == 'task_start':
                        # This task_start should be a root, not a child of another task_start
                        roots.append(trace)
                        continue
                
                if parent_id and parent_id in trace_map:
                    parent = trace_map[parent_id]
                    if 'children' not in parent:
                        parent['children'] = []
                    parent['children'].append(trace)
                else:
                    roots.append(trace)
            
            return roots
        
        # Build tree for each job_id group
        for job_id, group_traces in traces_by_job_id.items():
            group_spans = build_tree_for_group(group_traces)
            all_roots.extend(group_spans)
        
        # Handle traces without job_id (legacy or non-batch traces)
        if traces_without_job_id:
            legacy_spans = build_tree_for_group(traces_without_job_id)
            all_roots.extend(legacy_spans)
        
        return all_roots
    
    # Get event loop once for all executor calls
    loop = asyncio.get_running_loop()
    
    # Helper to safely send WebSocket messages
    async def safe_send(data: dict) -> bool:
        try:
            await websocket.send_json(data)
            logger.debug(f"Sent WebSocket message type={data.get('type')} for batch {batch_id}")
            return True
        except RuntimeError as e:
            if "closed" in str(e).lower() or "disconnect" in str(e).lower():
                logger.debug(f"WebSocket connection closed for batch {batch_id}")
            else:
                logger.debug(f"RuntimeError sending WebSocket message for batch {batch_id}: {e}")
            return False
        except (ConnectionError, OSError) as e:
            logger.debug(f"WebSocket connection error for batch {batch_id}: {e}")
            return False
        except Exception as e:
            error_msg = str(e).lower()
            if "close message" in error_msg or "closed" in error_msg:
                logger.debug(f"WebSocket closed for batch {batch_id}")
            else:
                logger.warning(f"Failed to send WebSocket message for batch {batch_id}: {e}")
            return False
    
    # Load initial traces immediately on connection
    try:
        # Get batch record to fetch all job_ids
        batch_record = await loop.run_in_executor(_db_executor, database.get_batch, batch_id)
        if not batch_record:
            raise HTTPException(status_code=404, detail="Batch not found")
        
        job_ids_in_batch = batch_record.get("job_ids", [])
        if not job_ids_in_batch:
            logger.info(f"No job_ids found in batch {batch_id}, sending empty traces")
            await safe_send({
                "type": "traces",
                "data": {
                    "spans": [],
                    "count": 0
                }
            })
        else:
            # Fetch traces for all job_ids in the batch
            initial_traces = await loop.run_in_executor(_db_executor, database.get_job_traces, job_ids_in_batch)
            logger.info(f"Loaded {len(initial_traces)} initial traces for batch {batch_id} (job_ids: {len(job_ids_in_batch)})")
            if initial_traces:
                last_trace_id = max(t.get('id', 0) for t in initial_traces)
                trace_tree = _build_trace_tree(initial_traces)
                logger.info(f"Built trace tree with {len(trace_tree)} root spans for batch {batch_id}")
                sent = await safe_send({
                    "type": "traces",
                    "data": {
                        "spans": trace_tree,
                        "count": len(initial_traces)
                    }
                })
                if sent:
                    logger.info(f"Successfully sent {len(initial_traces)} initial traces for batch {batch_id}")
                else:
                    logger.debug(f"Could not send initial traces for batch {batch_id} - connection may be closed")
            else:
                logger.info(f"No initial traces found for batch {batch_id}")
                # Send empty traces to let frontend know we're connected
                await safe_send({
                    "type": "traces",
                    "data": {
                        "spans": [],
                        "count": 0
                    }
                })
    except Exception as e:
        logger.error(f"Failed to load initial traces for batch {batch_id}: {e}", exc_info=True)
    
    # Poll for new traces continuously
    try:
        while True:
            # Check connection state
            if websocket.client_state.name != "CONNECTED":
                logger.info(f"WebSocket disconnected for batch {batch_id}")
                break
            
            # Get batch record to fetch current job_ids (may have been updated)
            batch_record = await loop.run_in_executor(_db_executor, database.get_batch, batch_id)
            if not batch_record:
                logger.warning(f"Batch {batch_id} disappeared during streaming.")
                break
            
            job_ids_in_batch = batch_record.get("job_ids", [])
            if not job_ids_in_batch:
                await asyncio.sleep(0.5)
                continue
            
            # Get all traces for all job_ids in this batch (non-blocking)
            traces = await loop.run_in_executor(_db_executor, database.get_job_traces, job_ids_in_batch)
            
            # Filter to only new traces
            new_traces = [t for t in traces if t.get('id', 0) > last_trace_id]
            
            if new_traces:
                # Update last seen ID
                last_trace_id = max(t.get('id', 0) for t in new_traces)
                
                # Build hierarchical tree structure
                trace_tree = _build_trace_tree(new_traces)
                
                logger.debug(f"Sending {len(new_traces)} new traces ({len(trace_tree)} root spans) for batch {batch_id}")
                
                # Send tree structure to client
                sent = await safe_send({
                    "type": "traces",
                    "data": {
                        "spans": trace_tree,
                        "count": len(new_traces)
                    }
                })
                if sent:
                    logger.debug(f"Successfully sent {len(new_traces)} new traces for batch {batch_id}")
                else:
                    # Connection closed, exit loop
                    break
            
            # Poll interval
            await asyncio.sleep(0.5)
    
    except WebSocketDisconnect:
        logger.info(f"WebSocket client disconnected for batch {batch_id}")
    except Exception as e:
        logger.error(f"WebSocket error for batch {batch_id}: {e}", exc_info=True)
        try:
            await websocket.send_json({
                "type": "error",
                "data": {"error": str(e)}
            })
        except:
            pass


@app.post("/api/prompts/{prompt_id}/cancel", response_model=CancelPromptResponse)
async def cancel_prompt(prompt_id: str, _: None = require_api_key):
        """Request cancellation of a running prompt. This sets a cancel flag and updates status."""
        try:
            # Signal cancel to runtime via message bus
            with suppress(Exception):
                # message_bus may not implement cancel in all backends; best-effort
                await message_bus.cancel_job(prompt_id)

            # Update prompt status to canceled
            database.update_prompt_status(prompt_id, "canceled")
            # Trace cancel request
            try:
                database.append_trace(prompt_id, "api", "task_cancel_requested", {"by": "user"})
            except Exception:
                pass

            return CancelPromptResponse(ok=True, prompt_id=prompt_id, status="canceled")
        except Exception as e:
            logger.exception("Failed to cancel prompt")
            raise HTTPException(status_code=500, detail=str(e))


# ---------------------------------------------------------------------------
# Capability routing endpoints
# ---------------------------------------------------------------------------

@app.post("/api/jobs/capability", dependencies=[require_api_key])
async def submit_capability_job(request: SubmitCapabilityJobRequest):
    """Submit a job with capability-based routing to the priority stream."""
    from laddr.core.message_bus import priority_stream_key, PRIORITY_LEVELS

    job_id = str(uuid.uuid4())
    created_at = datetime.utcnow().isoformat()

    job_payload = {
        "job_id": job_id,
        "system_prompt": request.system_prompt,
        "user_prompt": request.user_prompt,
        "inputs": json.dumps(request.inputs),
        "requirements": json.dumps(request.requirements),
        "priority": request.priority,
        "timeout_seconds": str(request.timeout_seconds),
        "max_iterations": str(request.max_iterations),
        "max_tool_calls": str(request.max_tool_calls),
        "created_at": created_at,
    }
    if request.callback_url:
        job_payload["callback_url"] = request.callback_url
        job_payload["callback_headers"] = json.dumps(request.callback_headers)

    priority = request.priority if request.priority in PRIORITY_LEVELS else "normal"
    stream_key = priority_stream_key(priority)

    # Write as {"job_id": ..., "job": json.dumps(...)} to match dispatcher's read format
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        await redis_client.xadd(stream_key, {"job_id": job_id, "job": json.dumps(job_payload)})
    except AttributeError:
        # message_bus is not Redis-backed; log and continue
        logger.warning("message_bus does not expose a Redis client; job not enqueued to stream")

    return {
        "job_id": job_id,
        "status": "queued",
        "priority": priority,
        "stream": stream_key,
        "created_at": created_at,
    }


@app.post("/api/jobs/script", dependencies=[require_api_key])
async def submit_script_job(request: SubmitScriptJobRequest):
    """Submit a direct script execution job with capability-based routing."""
    from laddr.core.message_bus import priority_stream_key, PRIORITY_LEVELS

    job_id = str(uuid.uuid4())
    created_at = datetime.utcnow().isoformat()

    job_payload = {
        "job_id": job_id,
        "task_type": "script",
        "command": request.command,
        "timeout_seconds": int(request.timeout_seconds),
        "experiment_id": request.experiment_id or "",
        "env": request.env,
        "requirements": {"mode": "explicit", "skills": ["script-exec"]},
        "priority": request.priority,
        "created_at": created_at,
    }
    if request.callback_url:
        job_payload["callback_url"] = request.callback_url
        job_payload["callback_headers"] = request.callback_headers

    priority = request.priority if request.priority in PRIORITY_LEVELS else "normal"
    stream_key = priority_stream_key(priority)

    # Write as {"job_id": ..., "job": json.dumps(...)} to match dispatcher's read format
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        await redis_client.xadd(stream_key, {"job_id": job_id, "job": json.dumps(job_payload)})
    except AttributeError:
        logger.warning("message_bus does not expose a Redis client; job not enqueued to stream")

    return {
        "job_id": job_id,
        "task_type": "script",
        "status": "queued",
        "priority": priority,
        "stream": stream_key,
        "created_at": created_at,
    }


@app.get("/api/workers", dependencies=[require_api_key])
async def list_workers_capability():
    """List registered workers from Redis."""
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        raw = await redis_client.hgetall("laddr:workers:registry")
        workers = {}
        for k, v in raw.items():
            key = k.decode() if isinstance(k, bytes) else k
            val = v.decode() if isinstance(v, bytes) else v
            try:
                workers[key] = json.loads(val)
            except Exception:
                workers[key] = val
        return {"workers": workers}
    except AttributeError:
        return {"workers": {}}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/workers/{worker_id}", dependencies=[require_api_key])
async def get_worker_capability(worker_id: str):
    """Get a single registered worker by ID."""
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        raw = await redis_client.hget("laddr:workers:registry", worker_id)
        if raw is None:
            raise HTTPException(status_code=404, detail=f"Worker '{worker_id}' not found")
        val = raw.decode() if isinstance(raw, bytes) else raw
        return json.loads(val)
    except HTTPException:
        raise
    except AttributeError:
        raise HTTPException(status_code=503, detail="Redis not available")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/templates", dependencies=[require_api_key])
async def create_template(request: JobTemplateRequest):
    """Store a job template in Redis."""
    template = {
        "name": request.name,
        "description": request.description,
        "requirements": request.requirements,
        "defaults": request.defaults,
    }
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        await redis_client.hset("laddr:templates", request.name, json.dumps(template))
    except AttributeError:
        logger.warning("message_bus does not expose a Redis client; template not persisted")

    return {"ok": True, "name": request.name}


@app.get("/api/templates", dependencies=[require_api_key])
async def list_templates():
    """List all job templates from Redis."""
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        raw = await redis_client.hgetall("laddr:templates")
        templates = []
        for v in raw.values():
            val = v.decode() if isinstance(v, bytes) else v
            try:
                templates.append(json.loads(val))
            except Exception:
                pass
        return {"templates": templates}
    except AttributeError:
        return {"templates": []}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/queue", dependencies=[require_api_key])
async def get_queue_depths():
    """Show queue depths for each priority stream."""
    from laddr.core.message_bus import PRIORITY_LEVELS, priority_stream_key

    depths = {}
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        for level in PRIORITY_LEVELS:
            key = priority_stream_key(level)
            try:
                # Use XPENDING to get actual unprocessed count, not XLEN
                groups = await redis_client.xinfo_groups(key)
                if groups:
                    # lag = messages not yet delivered to any consumer
                    # pending = delivered but not ACKed
                    lag = groups[0].get("lag", 0) or 0
                    pending = groups[0].get("pending", 0) or 0
                    depths[level] = lag + pending
                else:
                    # No consumer group — all messages are unprocessed
                    depths[level] = await redis_client.xlen(key)
            except Exception:
                depths[level] = 0
    except AttributeError:
        for level in PRIORITY_LEVELS:
            depths[level] = 0

    return {"queue_depths": depths}


@app.get("/api/dispatcher/stats", dependencies=[require_api_key])
async def get_dispatcher_stats():
    """Return dispatcher statistics (queue depths + stub metadata)."""
    from laddr.core.message_bus import PRIORITY_LEVELS, priority_stream_key

    depths = {}
    total = 0
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        for level in PRIORITY_LEVELS:
            key = priority_stream_key(level)
            try:
                length = await redis_client.xlen(key)
                depths[level] = length
                total += length
            except Exception:
                depths[level] = 0
    except AttributeError:
        for level in PRIORITY_LEVELS:
            depths[level] = 0

    return {
        "queue_depths": depths,
        "total_pending": total,
        "dispatcher": "capability-router",
    }


@app.post("/api/models/aliases", dependencies=[require_api_key])
async def create_model_alias(request: ModelAliasRequest):
    """Store a model alias in Redis."""
    alias = {
        "canonical": request.canonical,
        "aliases": request.aliases,
        "family": request.family,
    }
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        await redis_client.hset("laddr:model_aliases", request.canonical, json.dumps(alias))
    except AttributeError:
        logger.warning("message_bus does not expose a Redis client; model alias not persisted")

    return {"ok": True, "canonical": request.canonical}


@app.get("/api/models/aliases", dependencies=[require_api_key])
async def list_model_aliases():
    """List all model aliases from Redis."""
    try:
        redis_client = await message_bus._get_client()  # type: ignore[attr-defined]
        raw = await redis_client.hgetall("laddr:model_aliases")
        aliases = []
        for v in raw.values():
            val = v.decode() if isinstance(v, bytes) else v
            try:
                aliases.append(json.loads(val))
            except Exception:
                pass
        return {"aliases": aliases}
    except AttributeError:
        return {"aliases": []}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
