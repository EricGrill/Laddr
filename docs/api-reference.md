---
title: "API Reference"
description: "Complete REST API documentation for Laddr"
---

Complete documentation of all Laddr API endpoints.

---

## Base URL

All API requests should be made to:

**http://localhost:8000**

<Tip>
For production deployments, replace `localhost` with your server's hostname or IP address.
</Tip>

---

## Authentication

API key authentication is optional. If `LADDR_API_KEY` environment variable is set, all endpoints require authentication.

**Header Format:**
```http
X-API-Key: your-api-key
```

**Alternative (Bearer Token):**
```http
Authorization: Bearer your-api-key
```

**WebSocket Authentication:**
- Query parameter: `?api_key=your-api-key`
- Or use `X-API-Key` header
- Or use `Authorization: Bearer your-api-key` header

If `LADDR_API_KEY` is not set, authentication is disabled (no-op).

---

## Health

Check the system's health status.

```http
GET /api/health

```

**Response:**

```json
{
  "status": "ok",
  "version": "0.8.6",
  "components": {
    "database": "SQLite",
    "storage": "MinIO",
    "message_bus": "REDIS",
    "tracing": {
      "enabled": true,
      "backend": "database"
    }
  }
}
```

**Tracing Backend Values:**
- `"database"` - SQLite-based internal tracing
- `"langfuse"` - Langfuse external tracing
- `"disabled"` - Tracing not available

---

## Prompts (Preferred)

The prompts API is the recommended way to submit tasks to agents.

### Create Prompt

Submit a new prompt execution.

```http
POST /api/prompts
Content-Type: application/json

{
  "prompt_name": "researcher",
  "inputs": {
    "query": "What is Laddr?"
  },
  "mode": "single",
  "agents": null
}

```

**Request Body:**
- `prompt_name` (required) - Name of the agent to execute
- `inputs` (required) - Input data for the agent
- `mode` (optional) - Execution mode: `"single"` (default) or `"sequential"`
- `agents` (optional) - For sequential mode: ordered list of agent names to run in sequence

**Response:**

```json
{
  "prompt_id": "abc-123-def-456",
  "status": "running",
  "agent": "researcher",
  "mode": "single",
  "agents": ["researcher"]
}

```

**Sequential Mode Example:**

```http
POST /api/prompts
Content-Type: application/json

{
  "prompt_name": "coordinator",
  "inputs": {"topic": "AI research"},
  "mode": "sequential",
  "agents": ["researcher", "writer", "reviewer"]
}

```

This runs agents in order, piping output from one to the next.

### Get Prompt

Retrieve details of a specific prompt execution.

```http
GET /api/prompts/{prompt_id}

```

**Response:**

```json
{
  "prompt_id": "abc-123-def-456",
  "prompt_name": "researcher",
  "status": "completed",
  "inputs": {"query": "What is Laddr?"},
  "outputs": {"answer": "Laddr is..."},
  "created_at": "2024-01-01T00:00:00Z",
  "completed_at": "2024-01-01T00:00:05Z",
  "token_usage": {
    "prompt_tokens": 150,
    "completion_tokens": 75,
    "total_tokens": 225,
    "by_model": [
      {
        "provider": "openai",
        "model": "gpt-4",
        "prompt_tokens": 150,
        "completion_tokens": 75,
        "total_tokens": 225,
        "calls": 1
      }
    ]
  }
}

```

### List Prompts

List all prompt executions with pagination.

```http
GET /api/prompts?limit=50

```

**Query Parameters:**
- `limit` - Maximum number of results (default: 50)

**Response:**

```json
{
  "prompts": [
    {
      "prompt_id": "abc-123",
      "prompt_name": "researcher",
      "status": "completed",
      "created_at": "2024-01-01T00:00:00Z",
      "completed_at": "2024-01-01T00:00:05Z"
    }
  ],
  "limit": 50
}

```

### Cancel Prompt

Cancel a running prompt execution.

```http
POST /api/prompts/{prompt_id}/cancel

```

**Response:**

```json
{
  "ok": true,
  "prompt_id": "abc-123-def-456",
  "status": "canceled"
}

```

---

## Jobs (Legacy)

The jobs API is maintained for backward compatibility. Use the prompts API for new integrations.

### Submit Job

Submit a job using the legacy endpoint.

```http
POST /api/jobs
Content-Type: application/json

{
  "pipeline_name": "coordinator",
  "inputs": {"topic": "Latest AI agents"}
}

```

**Response:**

```json
{
  "job_id": "abc-123-def-456",
  "status": "success",
  "result": {"output": "..."},
  "error": null,
  "duration_ms": 1234,
  "agent": "coordinator"
}

```

### Get Job

Retrieve a specific job by ID.

```http
GET /api/jobs/{job_id}

```

**Response:**

```json
{
  "job_id": "abc-123-def-456",
  "status": "completed",
  "pipeline_name": "coordinator",
  "inputs": {"topic": "Latest AI agents"},
  "outputs": {"result": "..."},
  "created_at": "2024-01-01T00:00:00Z",
  "completed_at": "2024-01-01T00:00:05Z",
  "token_usage": {
    "prompt_tokens": 1000,
    "completion_tokens": 500,
    "total_tokens": 1500,
    "by_model": [...]
  }
}

```

### List Jobs

List all jobs with pagination support.

```http
GET /api/jobs?limit=50&offset=0

```

### Replay Job

Replay a previous job execution.

```http
POST /api/jobs/{job_id}/replay
Content-Type: application/json

{
  "reexecute": false
}

```

**Request Body:**
- `reexecute` - If `true`, re-run the job. If `false`, return stored result.

---

## Batches

Batch operations allow you to submit multiple tasks to an agent in parallel. Each task gets its own unique `job_id` and `trace_id`, but all tasks are grouped under a `batch_id` for tracking.

### Submit Batch Tasks

Submit multiple tasks to an agent's queue in parallel.

```http
POST /api/agents/{agent_name}/batch
Content-Type: application/json

{
  "tasks": [
    {"query": "What is Python?"},
    {"query": "What is JavaScript?"},
    {"query": "What is Rust?"}
  ],
  "wait": false,
  "batch_id": null
}

```

**Request Body:**
- `tasks` (required) - List of task payloads to execute in parallel
- `wait` (optional) - If `true`, wait for all responses before returning (default: `false`)
- `batch_id` (optional) - Existing batch ID to add tasks to, or `null` to create new batch

**Response (non-blocking):**

```json
{
  "batch_id": "batch-abc-123",
  "agent_name": "researcher",
  "status": "submitted",
  "task_count": 3,
  "task_ids": ["task-1", "task-2", "task-3"],
  "job_ids": ["job-1", "job-2", "job-3"],
  "trace_ids": ["trace-1", "trace-2", "trace-3"]
}

```

**Response (blocking, wait=true):**

```json
{
  "batch_id": "batch-abc-123",
  "agent_name": "researcher",
  "status": "completed",
  "task_count": 3,
  "task_ids": ["task-1", "task-2", "task-3"],
  "job_ids": ["job-1", "job-2", "job-3"],
  "trace_ids": ["trace-1", "trace-2", "trace-3"],
  "results": [
    {
      "task_id": "task-1",
      "response": {"status": "success", "result": "..."}
    },
    {
      "task_id": "task-2",
      "response": {"status": "success", "result": "..."}
    },
    {
      "task_id": "task-3",
      "response": {"status": "success", "result": "..."}
    }
  ]
}

```

### Add Tasks to Batch

Add more tasks to an existing batch (useful for adding aggregator tasks after evaluator workers complete).

```http
POST /api/batches/{batch_id}/add-tasks
Content-Type: application/json

{
  "agent_name": "aggregator",
  "tasks": [
    {"batch_id": "batch-abc-123", "operation": "summarize"}
  ],
  "wait": false
}

```

**Request Body:**
- `agent_name` (required) - Agent to run the new tasks
- `tasks` (required) - List of task payloads to add
- `wait` (optional) - If `true`, wait for responses (default: `false`)

**Response:**

```json
{
  "batch_id": "batch-abc-123",
  "status": "running",
  "added_job_ids": ["job-4"],
  "added_trace_ids": ["trace-4"],
  "added_task_ids": ["task-4"],
  "total_tasks": 4,
  "total_job_ids": 4
}

```

### Get Batch

Retrieve batch metadata and status.

```http
GET /api/batches/{batch_id}

```

**Response:**

```json
{
  "batch_id": "batch-abc-123",
  "agent_name": "researcher",
  "status": "completed",
  "task_count": 3,
  "job_ids": ["job-1", "job-2", "job-3"],
  "task_ids": ["task-1", "task-2", "task-3"],
  "inputs": {"tasks": [...]},
  "outputs": {
    "results": {
      "job-1": {"status": "success", "response": {...}},
      "job-2": {"status": "success", "response": {...}},
      "job-3": {"status": "success", "response": {...}}
    },
    "summary": {
      "total_expected": 3,
      "recorded": 3,
      "succeeded": 3,
      "failed": 0
    }
  },
  "created_at": "2024-01-01T00:00:00Z",
  "completed_at": "2024-01-01T00:00:05Z"
}

```

### List Batches

List recent batch operations.

```http
GET /api/batches?limit=50

```

**Query Parameters:**
- `limit` - Maximum number of batches to return (default: 50)

**Response:**

```json
{
  "batches": [
    {
      "batch_id": "batch-abc-123",
      "agent_name": "researcher",
      "status": "completed",
      "task_count": 3,
      "job_ids": ["job-1", "job-2", "job-3"],
      "task_ids": ["task-1", "task-2", "task-3"],
      "created_at": "2024-01-01T00:00:00Z",
      "completed_at": "2024-01-01T00:00:05Z"
    }
  ],
  "limit": 50
}

```

---

## Agents

### List Agents

List all registered agents with metadata.

```http
GET /api/agents

```

**Response:**

```json
{
  "agents": [
    {
      "name": "researcher",
      "role": "Research Assistant",
      "goal": "Conduct research on given topics",
      "status": "active",
      "tools": ["web_search", "read_document"],
      "last_seen": "2024-01-01T00:00:00Z",
      "trace_count": 150,
      "last_executed": "2024-01-01T00:00:00Z"
    }
  ]
}

```

### Chat with Agent

Send a message to an agent and optionally wait for response.

```http
GET /api/agents/{agent_name}/chat?message=Hello&wait=true&timeout=30

```

**Query Parameters:**
- `message` (required) - Message to send to the agent
- `wait` (optional) - If `true`, wait for response (default: `true`)
- `timeout` (optional) - Timeout in seconds when waiting (default: 30)

**Response (wait=true):**

```json
{
  "task_id": "task-abc-123",
  "status": "completed",
  "response": {"message": "Hello! How can I help you?"}
}

```

**Response (wait=false):**

```json
{
  "task_id": "task-abc-123",
  "status": "submitted"
}

```

### Get Agent Tools

Get detailed tool information for a specific agent.

```http
GET /api/agents/{agent_name}/tools

```

**Response:**

```json
{
  "agent": "researcher",
  "tools": [
    {
      "name": "web_search",
      "description": "Search the web for information",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Search query"
          }
        },
        "required": ["query"]
      }
    }
  ]
}

```

---

## Traces

Traces provide observability into agent execution, tool calls, and LLM interactions.

### List Traces

List trace events with optional filters.

```http
GET /api/traces?job_id=abc-123&agent_name=researcher&limit=100

```

**Query Parameters:**
- `job_id` (optional) - Filter traces by job ID
- `agent_name` (optional) - Filter traces by agent name
- `limit` (optional) - Maximum number of traces to return (default: 100)

**Response:**

```json
{
  "traces": [
    {
      "id": 1,
      "job_id": "abc-123",
      "agent_name": "researcher",
      "event_type": "task_start",
      "parent_id": null,
      "payload": {"task": "..."},
      "timestamp": "2024-01-01T00:00:00Z"
    },
    {
      "id": 2,
      "job_id": "abc-123",
      "agent_name": "researcher",
      "event_type": "tool_call",
      "parent_id": 1,
      "payload": {
        "tool_name": "web_search",
        "parameters": {"query": "..."},
        "result": {"status": "success"}
      },
      "timestamp": "2024-01-01T00:00:01Z"
    }
  ]
}

```

### Get Grouped Traces

Get traces grouped by job_id, showing complete multi-agent runs together.

```http
GET /api/traces/grouped?limit=50

```

**Query Parameters:**
- `limit` (optional) - Maximum number of job groups to return (default: 50)

**Response:**

```json
{
  "grouped_traces": [
    {
      "job_id": "abc-123",
      "trace_count": 15,
      "agents": ["coordinator", "researcher"],
      "start_time": "2024-01-01T00:00:00Z",
      "end_time": "2024-01-01T00:00:05Z",
      "traces": [...]
    }
  ]
}

```

### Get Trace

Get a single trace event by ID with full payload.

```http
GET /api/traces/{trace_id}

```

**Response:**

```json
{
  "id": 1,
  "job_id": "abc-123",
  "agent_name": "researcher",
  "event_type": "tool_call",
  "payload": {
    "tool_name": "web_search",
    "parameters": {"query": "Python async"},
    "result": {"status": "success", "data": "..."},
    "duration_ms": 245
  },
  "timestamp": "2024-01-01T00:00:01Z"
}

```

---

## Metrics

### Get Metrics

Get aggregated system metrics.

```http
GET /api/metrics

```

**Response:**

```json
{
  "total_jobs": 150,
  "completed_jobs": 140,
  "failed_jobs": 10,
  "avg_latency_ms": 1250,
  "active_agents_count": 5,
  "tool_calls": 500,
  "cache_hits": 50,
  "total_tokens": 100000,
  "timestamp": "2024-01-01T00:00:00Z"
}

```

---

## Responses

### Get Resolved Response

Resolve a task response. If the response was offloaded to storage (MinIO/S3), this endpoint fetches the full payload.

```http
GET /api/responses/{task_id}/resolved

```

**Response (inline):**

```json
{
  "task_id": "task-abc-123",
  "offloaded": false,
  "pointer": null,
  "data": {"status": "success", "result": "..."}
}

```

**Response (offloaded):**

```json
{
  "task_id": "task-abc-123",
  "offloaded": true,
  "pointer": {
    "bucket": "laddr",
    "key": "responses/task-abc-123.json",
    "size_bytes": 1024000
  },
  "data": {"status": "success", "result": "..."}
}

```

---

## Container Logs

### List Containers

List all Docker containers (project-agnostic).

```http
GET /api/logs/containers

```

**Response:**

```json
{
  "containers": [
    {
      "id": "abc123def456",
      "name": "laddr-api",
      "service_name": "api",
      "project_name": "laddr",
      "type": "api",
      "status": "running",
      "image": "laddr:latest",
      "created": "2024-01-01T00:00:00Z"
    }
  ],
  "total": 5
}

```

**Container Types:**
- `api` - API server containers
- `worker` - Agent worker containers
- `infrastructure` - Database, Redis, MinIO, etc.
- `other` - Other containers

### Get Container Logs

Get logs from a specific container.

```http
GET /api/logs/containers/{container_name}?tail=100&since=5m&timestamps=true

```

**Query Parameters:**
- `tail` (optional) - Number of lines to return (default: 100)
- `since` (optional) - Only logs since this timestamp (e.g., "5m", "1h", or ISO8601)
- `timestamps` (optional) - Include timestamps in logs (default: `true`)

**Response:**

```json
{
  "container": "laddr-api",
  "container_id": "abc123def456",
  "status": "running",
  "logs": [
    {
      "timestamp": "2024-01-01T00:00:00.000000000Z",
      "message": "Laddr API server started"
    }
  ],
  "total": 100
}

```

---

## WebSockets

### Prompt Traces

Stream live trace events for a specific prompt execution.

```http
WS /ws/prompts/{prompt_id}

```

**Message Format:**

```json
{
  "type": "traces",
  "data": {
    "spans": [
      {
        "id": 1,
        "name": "researcher",
        "type": "agent",
        "start_time": "2024-01-01T00:00:00Z",
        "agent": "researcher",
        "event_type": "task_start",
        "input": {"query": "..."},
        "output": null,
        "metadata": {...},
        "children": [
          {
            "id": 2,
            "name": "web_search",
            "type": "tool",
            "input": {"query": "..."},
            "output": {"result": "..."},
            "children": []
          }
        ]
      }
    ],
    "count": 15
  }
}

```

**Completion Event:**

```json
{
  "type": "complete",
  "data": {
    "status": "completed",
    "outputs": {"result": "..."},
    "error": null,
    "spans": [...]
  }
}

```

### Batch Traces

Stream live trace events for a batch operation (all job_ids in the batch).

```http
WS /ws/batches/{batch_id}

```

**Message Format:**

Same as prompt traces, but includes traces from all `job_ids` in the batch, grouped by `job_id`.

### Container Logs

Stream container logs in real-time.

```http
WS /ws/logs/{container_name}

```

**Message Format:**

```json
{
  "type": "log",
  "data": {
    "timestamp": "2024-01-01T00:00:00.000000000Z",
    "message": "Laddr API server started"
  }
}

```

### Events

Stream real-time system events (throttled).

```http
WS /ws/events

```

**Message Format:**

```json
{
  "type": "trace",
  "data": {
    "job_id": "abc-123",
    "agent_name": "researcher",
    "event_type": "tool_call",
    "timestamp": "2024-01-01T00:00:00Z"
  }
}

```

**Batch Events:**

```json
{
  "type": "batch",
  "events": [
    {"type": "trace", "data": {...}},
    {"type": "trace", "data": {...}}
  ]
}

```

---

## Error Responses

All endpoints may return error responses in the following format:

```json
{
  "detail": "Error message"
}

```

**Common Status Codes:**
- `200` - Success
- `400` - Bad Request
- `401` - Unauthorized (invalid or missing API key)
- `404` - Not Found
- `500` - Internal Server Error
- `502` - Bad Gateway (storage fetch failed)
- `503` - Service Unavailable (Docker SDK not available)

---

## Rate Limiting

Currently, there are no rate limits. For production deployments, consider implementing rate limiting.

---

## Event Types

Trace events use the following `event_type` values:

- `task_start` - Agent task execution begins
- `task_complete` - Agent task execution completes
- `tool_call` - Tool invocation with parameters and results
- `llm_usage` - LLM API call with token usage
- `cache_hit` - Cached result used
- `delegation` - Task delegation to another agent
- `error` - Error occurrence with stack trace
- `task_cancel_requested` - Task cancellation requested

## Next Steps

- [Traces and Database](/traces-and-database) - Understanding traces, SQLite, Langfuse, and Postgres
- [CLI Reference](/reference/cli) - Command-line interface
- [Agent Configuration](/guides/agents/agent-config) - Configure agents
- [Getting Started](/getting-started/install) - Setup guide
