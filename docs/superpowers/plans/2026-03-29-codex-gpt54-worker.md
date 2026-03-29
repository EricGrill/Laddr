# Codex GPT-5.4 Worker Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenAI's full model lineup and Codex autonomous agent to the Laddr worker fleet.

**Architecture:** Two new worker identities: `codex-01` (push worker proxying LLM calls to OpenAI API via `cloud_providers` config) and `codex-agent-01` (pull-based agent worker running in OpenAI's Codex sandbox). No changes to dispatcher, capability matcher, or worker process code.

**Tech Stack:** YAML config, Bash, Python (existing `WorkerProcess` + `OpenAILLM`), Codex CLI

**Spec:** `docs/superpowers/specs/2026-03-29-codex-gpt54-worker-design.md`

**Spec deviations:**
- `model_aliases.py` changes are intentionally omitted — the `ModelAliasRegistry` has no registered entries anywhere in the codebase, and the spec's proposed mappings are identity no-ops (`gpt-5.4` -> `gpt-5.4`). Not worth adding until aliases that actually differ are needed.

**Prerequisites:**
- `laddr` package must be installed in the test environment (`pip install -e lib/laddr`) for Task 6's capability matcher import
- The Codex CLI flag `--prompt-file` should be verified against current Codex docs at implementation time — adjust the launcher script if the actual flag differs

**Env var expansion:** YAML configs use `${OPENAI_API_KEY}` / `${VENICE_API_KEY}` / `${REDIS_PASSWORD}`. `yaml.safe_load()` does NOT expand these. In Docker, `env_file: .env` injects them as environment variables, and the `${...}` strings are passed literally in the config. `WorkerProcess` reads them as literal strings. For Docker deployments, the actual API key must go in `deploy/.env`. For bare-metal (snoke), write the literal key value directly in `~/.laddr/codex-worker.yml`.

**API key in bootstrap prompt:** The Laddr API key appears in plaintext in `codex-bootstrap.md`. This is the same internal key already committed in `docs/laddr-agent-api.md`. It is an internal/non-production key and is acceptable to commit.

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Fix | `deploy/workers/venice.yml` | Migrate from broken top-level `models` to `cloud_providers` pattern |
| Create | `deploy/workers/codex.yml` | Push worker config for OpenAI models on snoke |
| Create | `deploy/agents/run-codex-agent.sh` | Launcher script for Codex sandbox agent |
| Create | `deploy/agents/codex-bootstrap.md` | System prompt teaching Codex the Laddr agent worker loop |
| Modify | `docs/laddr-agent-api.md` | Update fleet table + skill taxonomy with new workers |
| Create | `lib/laddr/tests/test_codex_worker_config.py` | Validate codex.yml loads and builds capabilities correctly |

---

## Task 1: Fix `venice.yml` Config Structure (Prerequisite)

The existing `venice.yml` uses a top-level `models` key that `WorkerProcess._build_capabilities()` never reads. Fix it to use the `cloud_providers` pattern that the code actually supports. This validates the pattern before applying it to `codex.yml`.

**Files:**
- Modify: `deploy/workers/venice.yml`
- Test: `lib/laddr/tests/test_codex_worker_config.py`

- [ ] **Step 1: Write a test that loads venice.yml and verifies cloud_providers models appear in capabilities**

```python
# lib/laddr/tests/test_codex_worker_config.py
"""Tests for worker config loading and capability building."""
from __future__ import annotations

import yaml
import pathlib

DEPLOY_DIR = pathlib.Path(__file__).resolve().parents[3] / "deploy" / "workers"


def _load_config(name: str) -> dict:
    """Load a worker YAML config by filename."""
    path = DEPLOY_DIR / name
    with open(path) as fh:
        return yaml.safe_load(fh)


class TestVeniceConfig:
    def test_venice_uses_cloud_providers(self):
        config = _load_config("venice.yml")
        assert "cloud_providers" in config, "venice.yml must use cloud_providers, not top-level models"
        providers = config["cloud_providers"]
        assert len(providers) >= 1
        models = providers[0].get("models", [])
        assert len(models) >= 1
        assert models[0]["id"] == "llama-3.3-70b"

    def test_venice_no_toplevel_models(self):
        config = _load_config("venice.yml")
        assert "models" not in config, "top-level models key is not read by WorkerProcess"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/eric/code/Laddr && python -m pytest lib/laddr/tests/test_codex_worker_config.py -v`
Expected: FAIL — venice.yml still has top-level `models` and no `cloud_providers`

- [ ] **Step 3: Migrate venice.yml to cloud_providers pattern**

Replace the contents of `deploy/workers/venice.yml` with:

```yaml
node: bitlay
worker_id: venice-01

cloud_providers:
  - name: venice
    endpoint: https://api.venice.ai/v1
    api_key: ${VENICE_API_KEY}
    models:
      - id: llama-3.3-70b
        provider: venice
        context_window: 131072
        loaded: true
      - id: deepseek-r1-32b
        provider: venice
        context_window: 65536
        loaded: true

mcps: []
skills: []
max_concurrent: 3

server:
  redis_url: redis://:${REDIS_PASSWORD}@redis:6379
  minio_endpoint: minio:9000
  api_url: http://api:8000
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/eric/code/Laddr && python -m pytest lib/laddr/tests/test_codex_worker_config.py -v`
Expected: PASS — both tests green

- [ ] **Step 5: Commit**

```bash
git add deploy/workers/venice.yml lib/laddr/tests/test_codex_worker_config.py
git commit -m "fix: migrate venice.yml from top-level models to cloud_providers pattern"
```

---

## Task 2: Create `codex.yml` Push Worker Config

Create the OpenAI push worker config using the same `cloud_providers` pattern validated in Task 1.

**Files:**
- Create: `deploy/workers/codex.yml`
- Modify: `lib/laddr/tests/test_codex_worker_config.py`

- [ ] **Step 1: Add tests for codex.yml config**

Append to `lib/laddr/tests/test_codex_worker_config.py`:

```python
class TestCodexPushConfig:
    def test_codex_uses_cloud_providers(self):
        config = _load_config("codex.yml")
        assert "cloud_providers" in config
        providers = config["cloud_providers"]
        assert len(providers) >= 1
        assert providers[0]["name"] == "openai"

    def test_codex_no_llm_endpoint(self):
        """No llm.endpoint means LM Studio discovery is skipped."""
        config = _load_config("codex.yml")
        llm_endpoint = config.get("llm", {}).get("endpoint")
        assert llm_endpoint is None, "codex.yml should not have llm.endpoint — cloud-only worker"

    def test_codex_has_expected_models(self):
        config = _load_config("codex.yml")
        models = config["cloud_providers"][0]["models"]
        model_ids = [m["id"] for m in models]
        assert "gpt-5.4" in model_ids
        assert "o3" in model_ids
        assert "o4-mini" in model_ids
        assert "gpt-4.1" in model_ids
        assert "gpt-4.1-mini" in model_ids

    def test_codex_has_expected_skills(self):
        config = _load_config("codex.yml")
        skills = config.get("skills", [])
        for expected in ["coding", "code-review", "refactoring", "debugging", "testing", "devops"]:
            assert expected in skills, f"Missing skill: {expected}"

    def test_codex_worker_id(self):
        config = _load_config("codex.yml")
        assert config["worker_id"] == "codex-01"
        assert config["node"] == "snoke"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/eric/code/Laddr && python -m pytest lib/laddr/tests/test_codex_worker_config.py::TestCodexPushConfig -v`
Expected: FAIL — `codex.yml` does not exist yet

- [ ] **Step 3: Create codex.yml**

Create `deploy/workers/codex.yml`:

```yaml
# OpenAI cloud worker — runs on snoke alongside snoke-01
# No llm.endpoint — cloud-only worker, skips LM Studio discovery
node: snoke
worker_id: codex-01

cloud_providers:
  - name: openai
    endpoint: https://api.openai.com/v1
    api_key: ${OPENAI_API_KEY}
    models:
      - id: gpt-5.4
        provider: openai
        context_window: 1048576
        loaded: true
      - id: o3
        provider: openai
        context_window: 200000
        loaded: true
      - id: o4-mini
        provider: openai
        context_window: 200000
        loaded: true
      - id: gpt-4.1
        provider: openai
        context_window: 1048576
        loaded: true
      - id: gpt-4.1-mini
        provider: openai
        context_window: 1048576
        loaded: true

mcps: []

skills:
  - coding
  - code-review
  - refactoring
  - debugging
  - testing
  - devops

max_concurrent: 5

server:
  redis_url: redis://:${REDIS_PASSWORD}@100.x.x.x:6379
  minio_endpoint: 100.x.x.x:9000
  api_url: http://100.x.x.x:8000
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/eric/code/Laddr && python -m pytest lib/laddr/tests/test_codex_worker_config.py::TestCodexPushConfig -v`
Expected: PASS — all 5 tests green

- [ ] **Step 5: Commit**

```bash
git add deploy/workers/codex.yml lib/laddr/tests/test_codex_worker_config.py
git commit -m "feat: add codex-01 push worker config for OpenAI models"
```

---

## Task 3: Add Docker Compose Service for `codex-01`

Add a `codex-worker` service to `docker-compose.yml` following the `venice-worker` pattern, so `codex-01` can also run in Docker (not just bare metal on snoke).

**Files:**
- Modify: `deploy/docker-compose.yml`

- [ ] **Step 1: Add `OPENAI_API_KEY` to `deploy/.env`**

Append to `deploy/.env` (create if it doesn't exist):

```
OPENAI_API_KEY=sk-your-actual-openai-key-here
```

Do NOT commit `.env` — it should already be in `.gitignore`.

- [ ] **Step 2: Add codex-worker service**

Add after the `venice-worker` service block in `deploy/docker-compose.yml`:

```yaml
  codex-worker:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    command: laddr worker start --config /config/codex.yml
    volumes:
      - ./workers/codex.yml:/config/codex.yml
    env_file: .env
    depends_on:
      redis:
        condition: service_healthy
```

- [ ] **Step 3: Verify compose file parses**

Run: `cd /Users/eric/code/Laddr/deploy && docker compose config --quiet 2>&1; echo "exit: $?"`
Expected: exit 0, no parse errors

- [ ] **Step 4: Commit**

```bash
git add deploy/docker-compose.yml
git commit -m "feat: add codex-worker service to docker-compose"
```

---

## Task 4: Create Codex Agent Bootstrap Files

Create the launcher script and bootstrap prompt for the pull-based Codex sandbox agent.

**Files:**
- Create: `deploy/agents/run-codex-agent.sh`
- Create: `deploy/agents/codex-bootstrap.md`

- [ ] **Step 1: Create deploy/agents directory**

Run: `mkdir -p /Users/eric/code/Laddr/deploy/agents`

- [ ] **Step 2: Create the bootstrap prompt**

Create `deploy/agents/codex-bootstrap.md`:

```markdown
# Laddr Agent Worker — Codex

You are a pull-based agent worker in the Laddr/Daystrom distributed AI fleet.
Your job: register with the Laddr API, claim tasks matching your skills, do the
work, and submit results. Repeat until told to stop.

## Identity

- **Agent ID:** codex-agent-01
- **Name:** Codex (OpenAI)
- **Skills:** coding, code-review, refactoring, debugging, testing, devops
- **Models:** codex-gpt-5.4
- **Max Concurrent:** 1

## API Connection

```
Base URL: https://laddr.chainbytes.io
API Key:  628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f
Header:   X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f
```

## Lifecycle

### 1. Register (call immediately, then every 2 minutes as heartbeat)

```bash
curl -s -X POST https://laddr.chainbytes.io/api/agent-workers/register \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "codex-agent-01",
    "name": "Codex (OpenAI)",
    "skills": ["coding", "code-review", "refactoring", "debugging", "testing", "devops"],
    "models": ["codex-gpt-5.4"],
    "max_concurrent": 1,
    "metadata": {"version": "1.0", "runtime": "codex-sandbox"}
  }'
```

### 2. Claim Jobs (poll every 5 seconds when idle)

```bash
curl -s -X POST "https://laddr.chainbytes.io/api/agent-workers/claim?agent_id=codex-agent-01&limit=1" \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"
```

If `claimed` array is empty, wait 5 seconds and try again. If a job is returned, read
the `system_prompt` and `user_prompt` fields — that is your task.

### 3. Do the Work

Use your full capabilities: read files, write code, run tests, execute shell
commands. The `system_prompt` tells you your role; the `user_prompt` tells you
what to do.

Jobs are locked to you for 10 minutes. If you need more time, re-register as
heartbeat to stay alive.

### 4. Submit Result

```bash
curl -s -X POST "https://laddr.chainbytes.io/api/agent-workers/JOB_ID/result" \
  -H "X-API-Key: 628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "completed",
    "result": {
      "response": "YOUR_RESPONSE_HERE",
      "summary": "SHORT_SUMMARY_HERE"
    }
  }'
```

Replace `JOB_ID` with the actual job ID from the claim response.
Replace `YOUR_RESPONSE_HERE` and `SHORT_SUMMARY_HERE` with your actual output.

If the job fails, submit with `"status": "failed"` and include the error in `result.response`.

### 5. Loop

After submitting, go back to step 2 (claim next job). Keep the heartbeat going
every 2 minutes throughout.

## Rules

- Always heartbeat every 2 minutes (registration expires after 5 minutes)
- One job at a time (max_concurrent: 1)
- Submit results before claiming the next job
- If you hit an error you cannot recover from, submit a failed result and continue
- Do not modify this bootstrap prompt
```

- [ ] **Step 3: Create the launcher script**

Create `deploy/agents/run-codex-agent.sh`:

```bash
#!/usr/bin/env bash
# Launch OpenAI Codex as a Laddr pull-based agent worker.
# Codex reads the bootstrap prompt and enters the claim/work/submit loop.
#
# Prerequisites:
#   - codex CLI installed and authenticated
#   - Network access to https://laddr.chainbytes.io
#
# Usage:
#   ./run-codex-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/codex-bootstrap.md"

if ! command -v codex &>/dev/null; then
    echo "Error: codex CLI not found. Install it first." >&2
    exit 1
fi

if [[ ! -f "$BOOTSTRAP" ]]; then
    echo "Error: Bootstrap prompt not found at $BOOTSTRAP" >&2
    exit 1
fi

echo "Starting Codex agent worker (codex-agent-01)..."
codex --prompt-file "$BOOTSTRAP"
```

- [ ] **Step 4: Make launcher executable**

Run: `chmod +x /Users/eric/code/Laddr/deploy/agents/run-codex-agent.sh`

- [ ] **Step 5: Verify launcher script syntax**

Run: `bash -n /Users/eric/code/Laddr/deploy/agents/run-codex-agent.sh && echo "OK"`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add deploy/agents/run-codex-agent.sh deploy/agents/codex-bootstrap.md
git commit -m "feat: add Codex agent worker bootstrap prompt and launcher script"
```

---

## Task 5: Update Fleet Documentation

Update the agent API docs with the new workers and updated skill taxonomy.

**Files:**
- Modify: `docs/laddr-agent-api.md`

- [ ] **Step 1: Update the Worker Fleet table**

In `docs/laddr-agent-api.md`, find the `## Worker Fleet (Current)` section (around line 387) and replace the table with:

```markdown
| Worker | Node | Models | Max Concurrent |
|--------|------|--------|----------------|
| darth-01 | darth (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| maul-01 | maul (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| snoke-01 | snoke (Mac mini) | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| ventress-01 | ventress (Mac) | 29 local models + cloud | 8 |
| codex-01 | snoke | gpt-5.4, o3, o4-mini, gpt-4.1, gpt-4.1-mini | 5 |

**Cloud providers (overflow):** Venice AI (deepseek-v3.2, llama-3.3-70b) + NVIDIA (deepseek-v3.2, llama-3.3-70b, qwen3.5-397b, nemotron-super-49b) + OpenAI (gpt-5.4, o3, o4-mini, gpt-4.1, gpt-4.1-mini)

**Pull-based agent workers:** Claude Code, Codex (codex-agent-01), Kimi
```

- [ ] **Step 2: Update the Skill taxonomy table**

In the same file, find the `**Skill taxonomy**` section (around line 162) and update the Agents column to include Codex. Preserve the existing 3-column format (Skill | Description | Agents):

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

- [ ] **Step 3: Commit**

```bash
git add -f docs/laddr-agent-api.md
git commit -m "docs: add codex-01 and codex-agent-01 to fleet and skill taxonomy"
```

---

## Task 6: Smoke Test — Load Config and Build Capabilities

Write an integration-style test that simulates what `WorkerProcess.__init__` and `_build_capabilities` do with the codex config, without needing Redis.

**Files:**
- Modify: `lib/laddr/tests/test_codex_worker_config.py`

- [ ] **Step 1: Add capability-building test**

Append to `lib/laddr/tests/test_codex_worker_config.py`:

```python
class TestCodexCapabilityBuilding:
    """Simulate WorkerProcess._build_capabilities with codex config."""

    def test_cloud_only_worker_has_no_local_models(self):
        config = _load_config("codex.yml")
        # WorkerProcess sets llm_endpoint from config.llm.endpoint
        llm_endpoint = config.get("llm", {}).get("endpoint")
        assert llm_endpoint is None
        # This means _models stays empty — no LM Studio discovery

    def test_build_capabilities_includes_cloud_models(self):
        config = _load_config("codex.yml")
        cloud_providers = config.get("cloud_providers", [])

        # Simulate _build_capabilities logic (worker_process.py:688-708)
        local_models = []  # no llm_endpoint means no local models
        all_models = list(local_models)
        for provider in cloud_providers:
            for m in provider.get("models", []):
                model_entry = dict(m)
                model_entry.setdefault("provider", provider.get("name", "cloud"))
                model_entry.setdefault("loaded", True)
                all_models.append(model_entry)

        capabilities = {
            "worker_id": config["worker_id"],
            "node": config["node"],
            "models": all_models,
            "mcps": config.get("mcps", []),
            "skills": config.get("skills", []),
            "max_concurrent": config.get("max_concurrent", 2),
            "active_jobs": 0,
        }

        assert capabilities["worker_id"] == "codex-01"
        assert len(capabilities["models"]) == 5
        model_ids = [m["id"] for m in capabilities["models"]]
        assert "gpt-5.4" in model_ids
        assert "o3" in model_ids
        assert all(m["provider"] == "openai" for m in capabilities["models"])
        assert "coding" in capabilities["skills"]

    def test_capability_matcher_accepts_codex_worker(self):
        """The existing capability matcher should match codex-01 for OpenAI model jobs."""
        from laddr.core.capability_matcher import matches_requirements

        config = _load_config("codex.yml")
        cloud_providers = config.get("cloud_providers", [])

        # Build models the same way WorkerProcess does
        all_models = []
        for provider in cloud_providers:
            for m in provider.get("models", []):
                model_entry = dict(m)
                model_entry.setdefault("provider", provider.get("name", "cloud"))
                model_entry.setdefault("loaded", True)
                all_models.append(model_entry)

        worker = {
            "worker_id": "codex-01",
            "capabilities": {
                "models": all_models,
                "mcps": [],
                "skills": config.get("skills", []),
                "max_concurrent": 5,
            },
            "active_jobs": 0,
        }

        # Should match a job requesting gpt-5.4
        assert matches_requirements(worker, {"models": ["gpt-5.4"]}) is True
        # Should match a job requesting coding skill
        assert matches_requirements(worker, {"skills": ["coding"]}) is True
        # Should NOT match a job requesting a model we don't have
        assert matches_requirements(worker, {"models": ["llama-3.3-70b"]}) is False
```

- [ ] **Step 2: Run all tests**

Run: `cd /Users/eric/code/Laddr && python -m pytest lib/laddr/tests/test_codex_worker_config.py -v`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add lib/laddr/tests/test_codex_worker_config.py
git commit -m "test: add capability-building and matcher tests for codex-01 worker"
```

---

## Summary

| Task | What | Files | Commits |
|------|------|-------|---------|
| 1 | Fix venice.yml config | `deploy/workers/venice.yml`, test file | 1 |
| 2 | Create codex.yml push worker | `deploy/workers/codex.yml`, test file | 1 |
| 3 | Docker Compose service | `deploy/docker-compose.yml` | 1 |
| 4 | Codex agent bootstrap | `deploy/agents/run-codex-agent.sh`, `deploy/agents/codex-bootstrap.md` | 1 |
| 5 | Update fleet docs | `docs/laddr-agent-api.md` | 1 |
| 6 | Smoke test capabilities | test file | 1 |

**Total: 6 tasks, 6 commits, 0 code changes to core Laddr modules.**

After all tasks, deploy by:
1. Adding `OPENAI_API_KEY` to `deploy/.env`
2. Running `docker compose up -d codex-worker` or `laddr worker start --config ~/.laddr/codex-worker.yml` on snoke
3. Running `./deploy/agents/run-codex-agent.sh` to start the Codex sandbox agent
4. Verifying with `curl https://laddr.chainbytes.io/api/workers` — codex-01 should appear
