# Laddr/Daystrom API — Agent Reference

Submit jobs to the Laddr distributed worker fleet. Workers run LLM inference (local LM Studio + cloud providers) and script execution across a pool of machines.

## Connection

```
Base URL: https://laddr.chainbytes.io
API Key:  628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f
Header:   X-API-Key: <key>
```

All requests require the API key via `X-API-Key` header or `?api_key=` query parameter.

## Quick Start — Submit a Job and Get Results

```bash
# 1. Submit a job
JOB_ID=$(curl -s -X POST https://laddr.chainbytes.io/api/jobs/capability \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "system_prompt": "You are a helpful analyst. Be concise.",
    "user_prompt": "Summarize the key benefits of distributed AI inference.",
    "priority": "normal"
  }' | jq -r '.job_id')

echo "Job submitted: $JOB_ID"

# 2. Poll for result (202 = pending, 200 = done)
while true; do
  RESULT=$(curl -s -w "\n%{http_code}" \
    "https://laddr.chainbytes.io/api/jobs/$JOB_ID/result" \
    -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f")
  HTTP_CODE=$(echo "$RESULT" | tail -1)
  BODY=$(echo "$RESULT" | head -1)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "$BODY" | jq .
    break
  fi
  sleep 2
done
```

## Endpoints

### POST /api/jobs/capability

Submit a job to the dispatcher. Workers are matched by model/skill requirements.

```json
{
  "system_prompt": "You are an expert code reviewer.",
  "user_prompt": "Review this Python function for bugs: ...",
  "inputs": {},
  "requirements": {"mode": "generic"},
  "priority": "normal",
  "timeout_seconds": 300,
  "callback_url": null
}
```

**Fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `system_prompt` | string | yes | — | System instructions for the LLM |
| `user_prompt` | string | no | — | The task/question |
| `inputs` | object | no | `{}` | Additional structured inputs |
| `requirements` | object | no | `{"mode": "generic"}` | Capability matching (see below) |
| `priority` | string | no | `"normal"` | `critical`, `high`, `normal`, `low` |
| `timeout_seconds` | int | no | `300` | Max job duration |
| `callback_url` | string | no | — | Webhook URL for result delivery |
| `callback_headers` | object | no | `{}` | Headers to send with callback |

**Requirements modes:**

```json
// Any available worker (default)
{"mode": "generic"}

// Specific model
{"mode": "explicit", "models": ["qwen/qwen3.5-9b"]}

// Model pattern match
{"mode": "explicit", "model_match": "llama"}
```

**Response:** `{"job_id": "uuid", "status": "queued"}`

### POST /api/jobs/script

Execute a shell command on a worker with `script-exec` skill.

```json
{
  "command": "echo 'Hello from worker' && uname -a",
  "timeout_seconds": 60,
  "priority": "normal"
}
```

**Response:** `{"job_id": "uuid", "message": "Script job queued"}`

### GET /api/jobs/{job_id}/result

Poll for job result.

| Status | Meaning |
|--------|---------|
| `200` | Done — body has `{job_id, worker_id, task_type, result, completed_at}` |
| `202` | Still running — body has `{job_id, status, message}` |
| `404` | Not found or expired (Redis TTL 30min, MinIO permanent if enabled) |

### GET /api/workers

List all registered workers with capabilities.

```bash
curl -s https://laddr.chainbytes.io/api/workers \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" | jq .
```

### GET /api/queue

Current queue depths by priority.

```json
{"queue_depths": {"critical": 0, "high": 0, "normal": 42, "low": 0}}
```

### GET /api/health

Health check with component status.

### GET /api/schema

Machine-readable API schema — an agent can read this to self-onboard.

## Pull-Based Agent Workers (Claude Code, Codex, Kimi)

External AI agents register their skills, pull jobs matching those skills, and submit results. Unlike push workers (Mac minis), pull workers operate on their own schedule.

### POST /api/agent-workers/register

Register as a pull-based worker. Call every 5 min as heartbeat.

```bash
curl -s -X POST https://laddr.chainbytes.io/api/agent-workers/register \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "claude-code-01",
    "name": "Claude Code",
    "skills": ["code-review", "coding", "refactoring", "debugging", "architecture"],
    "models": ["claude-opus-4-6"],
    "max_concurrent": 3,
    "metadata": {"version": "1.0", "environment": "production"}
  }'
```

**Skill taxonomy (use these for consistent matching):**

| Skill | Description | Agents |
|-------|-------------|--------|
| `coding` | Write new code, implement features | Claude Code, Codex, Kimi |
| `code-review` | Review code for bugs, quality, security | Claude Code, Codex |
| `refactoring` | Improve existing code structure | Claude Code, Codex |
| `debugging` | Find and fix bugs | Claude Code, Codex |
| `architecture` | System design, technical decisions | Claude Code |
| `reasoning` | Complex analysis, math, logic | Kimi, Claude Code |
| `research` | Information gathering, summarization | Kimi, Claude Code |
| `testing` | Write tests, test plans | Claude Code, Codex |
| `documentation` | Write docs, READMEs, API docs | Claude Code, Kimi |
| `devops` | CI/CD, deployment, infrastructure | Claude Code, Codex |

### POST /api/agent-workers/claim

Claim the next job(s) matching your skills.

```bash
# Claim 1 job matching your registered skills
curl -s -X POST "https://laddr.chainbytes.io/api/agent-workers/claim?agent_id=claude-code-01&limit=1" \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"

# Claim with explicit skill filter
curl -s -X POST "https://laddr.chainbytes.io/api/agent-workers/claim?agent_id=codex-01&skills=coding,refactoring&limit=3" \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"
```

**Response:**
```json
{
  "agent_id": "claude-code-01",
  "count": 1,
  "claimed": [
    {
      "job_id": "uuid",
      "system_prompt": "Review this code for security issues...",
      "user_prompt": "...",
      "inputs": {},
      "priority": "normal",
      "timeout_seconds": 300,
      "requirements": {"mode": "explicit", "skills": ["code-review"]},
      "created_at": "2026-03-29T..."
    }
  ]
}
```

Jobs are locked to you for 10 minutes. If you don't submit a result, they're released.

### POST /api/agent-workers/{job_id}/result

Submit the result of a claimed job.

```bash
curl -s -X POST "https://laddr.chainbytes.io/api/agent-workers/JOB_ID_HERE/result" \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "completed",
    "result": {
      "response": "Code review complete. Found 2 issues...",
      "files_modified": ["src/auth.py"],
      "summary": "Fixed SQL injection in login handler"
    }
  }'
```

### GET /api/agent-workers

List all registered pull-based agent workers.

### Complete Agent Worker Loop (Python)

```python
import httpx
import time

API = "https://laddr.chainbytes.io"
KEY = "628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"
HEADERS = {"X-API-Key": KEY, "Content-Type": "application/json"}

AGENT_ID = "claude-code-01"
SKILLS = ["coding", "code-review", "refactoring", "debugging"]

def register():
    r = httpx.post(f"{API}/api/agent-workers/register", headers=HEADERS, json={
        "agent_id": AGENT_ID,
        "name": "Claude Code",
        "skills": SKILLS,
        "models": ["claude-opus-4-6"],
        "max_concurrent": 3,
    })
    return r.json()

def claim_jobs(limit=1):
    r = httpx.post(
        f"{API}/api/agent-workers/claim?agent_id={AGENT_ID}&limit={limit}",
        headers=HEADERS,
    )
    return r.json().get("claimed", [])

def submit_result(job_id, result):
    r = httpx.post(f"{API}/api/agent-workers/{job_id}/result", headers=HEADERS, json={
        "status": "completed",
        "result": result,
    })
    return r.json()

# Main loop
register()
last_heartbeat = time.time()

while True:
    # Heartbeat every 4 min
    if time.time() - last_heartbeat > 240:
        register()
        last_heartbeat = time.time()

    # Claim a job
    jobs = claim_jobs(limit=1)
    if not jobs:
        time.sleep(5)
        continue

    for job in jobs:
        print(f"Working on {job['job_id']}: {job['system_prompt'][:60]}")

        # === YOUR AGENT DOES THE WORK HERE ===
        result = {"response": "Done!", "summary": "Completed task"}

        submit_result(job["job_id"], result)
        print(f"Completed {job['job_id']}")
```

### Submitting Jobs FOR Agent Workers

Tag jobs with skills so the right agent picks them up:

```bash
# Job for a code reviewer
curl -s -X POST https://laddr.chainbytes.io/api/jobs/capability \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "system_prompt": "Review this PR for bugs and security issues.",
    "user_prompt": "...",
    "requirements": {"mode": "explicit", "skills": ["code-review"]}
  }'

# Job specifically for Kimi (reasoning task)
curl -s -X POST https://laddr.chainbytes.io/api/jobs/capability \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "system_prompt": "Analyze this mathematical proof for correctness.",
    "user_prompt": "...",
    "requirements": {"mode": "explicit", "skills": ["reasoning"], "agent_type": "kimi"}
  }'

# Job for any coding agent
curl -s -X POST https://laddr.chainbytes.io/api/jobs/capability \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "system_prompt": "Implement a rate limiter middleware.",
    "user_prompt": "...",
    "requirements": {"mode": "explicit", "skills": ["coding"]}
  }'
```

## Batch Submission (Python)

```python
import httpx
import asyncio

API = "https://laddr.chainbytes.io"
KEY = "628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"
HEADERS = {"X-API-Key": KEY, "Content-Type": "application/json"}

async def submit_job(client, system_prompt, user_prompt, priority="normal"):
    r = await client.post(f"{API}/api/jobs/capability", headers=HEADERS, json={
        "system_prompt": system_prompt,
        "user_prompt": user_prompt,
        "priority": priority,
    })
    return r.json()["job_id"]

async def poll_result(client, job_id, interval=2, timeout=300):
    import time
    start = time.time()
    while time.time() - start < timeout:
        r = await client.get(f"{API}/api/jobs/{job_id}/result", headers=HEADERS)
        if r.status_code == 200:
            return r.json()
        await asyncio.sleep(interval)
    return None

async def main():
    async with httpx.AsyncClient(timeout=30) as client:
        # Submit multiple jobs
        tasks = [
            ("You are a Python expert.", "Write a fibonacci function"),
            ("You are a security analyst.", "List OWASP top 10 briefly"),
            ("You are a data scientist.", "Explain PCA in 3 sentences"),
        ]

        job_ids = []
        for system, user in tasks:
            jid = await submit_job(client, system, user)
            job_ids.append(jid)
            print(f"Submitted: {jid}")

        # Poll all results
        for jid in job_ids:
            result = await poll_result(client, jid)
            if result:
                print(f"\n--- {jid[:8]} ---")
                print(result.get("result", {}).get("response", "no response")[:200])

asyncio.run(main())
```

## Worker Fleet (Current)

| Worker | Node | Models | Max Concurrent |
|--------|------|--------|----------------|
| darth-01 | darth (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| maul-01 | maul (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| snoke-01 | snoke (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| ventress-01 | ventress (Mac) | 29 local models + cloud | 8 |

**Cloud providers (overflow):** Venice AI (deepseek-v3.2, llama-3.3-70b) + NVIDIA (deepseek-v3.2, llama-3.3-70b, qwen3.5-397b, nemotron-super-49b)

**Pull-based agent workers:** Claude Code, Codex (codex-agent-01), Kimi

## WebSocket — Real-time Mission Control

```javascript
const ws = new WebSocket("wss://laddr.chainbytes.io/ws/mission-control?api_key=628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f");
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  // msg.type: "snapshot", "job_created", "job_completed", "metrics_updated", etc.
  console.log(msg.type, msg);
};
```

## Dashboard

```
URL:      https://laddr.chainbytes.io
Username: admin
Password: chainbytes2016!
```

Mission Control (3D visualization): https://laddr.chainbytes.io/mission-control/

## Tips

- **Generic mode** is fine for most jobs — the dispatcher picks the best available worker
- **Poll interval:** 2-5 seconds is ideal. Results stay in Redis for 30 minutes
- **Priority:** Use `high` or `critical` sparingly — they jump the queue
- **Batch jobs:** Submit many at once, poll in parallel. The fleet handles 1000+ jobs/hour
- **Callback URL:** Set `callback_url` to receive results via webhook instead of polling
- **Self-onboard:** Have your agent `GET /api/schema` to discover the full API programmatically
