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
