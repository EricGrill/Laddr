# Codex GPT-5.4 Worker Integration

**Date:** 2026-03-29
**Status:** Approved

## Summary

Add OpenAI's full model lineup (GPT-5.4, o3, o4-mini, gpt-4.1, gpt-4.1-mini) and Codex autonomous agent capabilities to the Laddr/Daystrom worker fleet via two new worker identities:

1. **`codex-01`** — Push worker on snoke that proxies LLM inference to the OpenAI API
2. **`codex-agent-01`** — Pull-based agent worker running in OpenAI's Codex sandbox for autonomous coding tasks

## Motivation

The fleet currently runs local LM Studio models (qwen, granite, llama) and cloud overflow via Venice/NVIDIA. Adding OpenAI's frontier models (GPT-5.4, o3) expands capability for complex reasoning, coding, and architecture tasks. The Codex sandbox adds a fully autonomous coding agent that can read files, write code, run tests, and submit results — complementing Claude Code as a pull-based worker.

## Architecture

### Component A: `codex-01` Push Worker (OpenAI API Backend)

A cloud API worker identical in structure to `venice-01`. Runs on snoke as a second worker process alongside `snoke-01`. Routes LLM inference calls to `https://api.openai.com/v1` via the existing `OpenAILLM` adapter.

```
Dispatcher → laddr:worker:codex-01 → OpenAI API → Result
```

**Config:** `deploy/workers/codex.yml`

Uses `cloud_providers` (not top-level `models`) because `WorkerProcess._build_capabilities()` reads models from `cloud_providers[].models` and LM Studio discovery. No `llm.endpoint` is set — this is a cloud-only worker, so LM Studio discovery is skipped.

```yaml
node: snoke
worker_id: codex-01

# No llm.endpoint — cloud-only worker, skips LM Studio discovery

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

**Notes:**
- `max_concurrent: 5` — API calls, not GPU-bound
- No MCPs — this worker proxies LLM calls only, no local tool access
- Context windows based on current OpenAI published limits
- Launched on snoke: `laddr-worker --config ~/.laddr/codex-worker.yml`
- No `llm.endpoint` means `discover_lmstudio_models()` is skipped — models come solely from `cloud_providers`

**Note on `venice.yml`:** The existing `venice.yml` uses a top-level `models` key which `WorkerProcess` does not read. It should be migrated to the `cloud_providers` pattern as part of this work.

### Component B: `codex-agent-01` Pull-Based Agent Worker (Codex Sandbox)

A launcher script + bootstrap prompt that spins up an OpenAI Codex CLI session. Codex registers as a pull-based agent worker, claims jobs, does autonomous coding work in its sandbox, and submits results back to Laddr.

**Launcher:** `deploy/agents/run-codex-agent.sh`

```bash
#!/bin/bash
# Launch Codex as a Laddr pull-based agent worker
codex --prompt-file deploy/agents/codex-bootstrap.md
```

**Bootstrap prompt:** `deploy/agents/codex-bootstrap.md`

Teaches Codex:
1. How to register with the Laddr API as `codex-agent-01`
2. Its skill set (`coding, code-review, refactoring, debugging, testing, devops`) and model identity
3. The claim → work → submit loop
4. Heartbeat every 2 minutes (registration TTL is 5 min — 2 min interval gives safe margin for network/sandbox latency)
5. Laddr API base URL and authentication

### Push vs Pull: When Each Is Used

| | `codex-01` (push) | `codex-agent-01` (pull) |
|---|---|---|
| **Where** | Snoke, Laddr worker process | OpenAI Codex sandbox |
| **What** | Proxies LLM inference to OpenAI API | Autonomous coding — files, shell, tests |
| **Best for** | Quick inference: Q&A, review, analysis | Multi-step: implement features, fix + verify bugs |
| **Tooling** | None (LLM-only) | Full sandbox: filesystem, shell, code execution |
| **Visibility** | `/api/workers` (push registry) | `/api/agent-workers` (pull registry) |

### Routing

No dispatcher changes needed. Existing capability matching handles all cases:

- `{"mode": "explicit", "models": ["gpt-5.4"]}` → routes to `codex-01` push worker
- `{"mode": "explicit", "skills": ["coding"]}` → any worker with that skill
- `{"mode": "explicit", "skills": ["coding"], "agent_type": "codex"}` → pull-based Codex agent (uses substring match on agent_id)
- `{"mode": "generic"}` → any available worker (codex-01 now in the pool)

**Skill vocabulary note:** Existing push workers (snoke, maul, darth) use skills like `code-gen, web-research, script-exec`. The new codex-01 worker uses the agent taxonomy (`coding, code-review, refactoring`, etc.). These are intentionally different — push workers use infra-level skills while agent workers use task-level skills. Jobs should use the appropriate vocabulary for their target worker type.

**`agent_type` routing caveat:** The pull-based claim endpoint matches `agent_type` via substring containment (`agent_type in agent_id`). This means `"codex"` matches `"codex-agent-01"`. This is functional but fragile — a future agent with "codex" in its name would also match. Acceptable for now; can be tightened to exact prefix match if needed later.

## Changes Required

### New Files

| File | Purpose |
|------|---------|
| `deploy/workers/codex.yml` | Push worker config for OpenAI models |
| `deploy/agents/run-codex-agent.sh` | Launcher script for Codex agent sessions |
| `deploy/agents/codex-bootstrap.md` | System prompt teaching Codex the agent worker loop |

### New Directory

- `deploy/agents/` — new directory for agent bootstrap scripts and prompts

### Modified Files

| File | Change |
|------|--------|
| `docs/laddr-agent-api.md` | Add codex-01 and codex-agent-01 to fleet table, update skill taxonomy |
| `lib/laddr/src/laddr/core/model_aliases.py` | Add aliases: `gpt-5.4` → `gpt-5.4`, `o3` → `o3`, `o4-mini` → `o4-mini`, `gpt-4.1` → `gpt-4.1`, `gpt-4.1-mini` → `gpt-4.1-mini` (canonical → openai provider mapping) |
| `deploy/workers/venice.yml` | Migrate from top-level `models` to `cloud_providers` pattern to match how `WorkerProcess` actually reads config |

### No Changes Needed

- Dispatcher (`dispatcher.py`) — existing routing handles OpenAI models
- Capability matcher (`capability_matcher.py`) — model/skill matching already works
- Worker process (`worker_process.py`) — `cloud_providers` config path + `OpenAILLM` adapter already support this
- Agent worker API (`main.py`) — pull-based registration/claim/submit already exists

## Cost Considerations

GPT-5.4 and o3 are expensive models. Unlike LM Studio (free) and Venice (capped plans), OpenAI charges per token. Mitigations:

- `max_concurrent: 5` limits parallel spend
- Job `timeout_seconds` caps individual job duration (default 300s)
- Monitor via OpenAI usage dashboard
- Consider adding per-model or per-day spend caps in a future iteration if costs become a concern

## Fleet After Integration

| Worker | Node | Type | Models | Max Concurrent |
|--------|------|------|--------|----------------|
| darth-01 | darth | push | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| maul-01 | maul | push | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| snoke-01 | snoke | push | qwen3.5-9b, granite-4-h-tiny + cloud | 4 |
| ventress-01 | ventress | push | 29 local models + cloud | 8 |
| venice-01 | bitlay | push | llama-3.3-70b, deepseek-r1-32b | 3 |
| **codex-01** | **snoke** | **push** | **gpt-5.4, o3, o4-mini, gpt-4.1, gpt-4.1-mini** | **5** |
| **codex-agent-01** | **codex-sandbox** | **pull** | **codex (gpt-5.4)** | **1** |

## Updated Skill Taxonomy

| Skill | Agents |
|-------|--------|
| `coding` | Claude Code, **Codex**, Kimi |
| `code-review` | Claude Code, **Codex** |
| `refactoring` | Claude Code, **Codex** |
| `debugging` | Claude Code, **Codex** |
| `testing` | Claude Code, **Codex** |
| `devops` | Claude Code, **Codex** |
| `architecture` | Claude Code |
| `reasoning` | Kimi, Claude Code |
| `research` | Kimi, Claude Code |
| `documentation` | Claude Code, Kimi |

## Prerequisites

- `OPENAI_API_KEY` environment variable set on snoke
- OpenAI API access to GPT-5.4, o3, o4-mini, gpt-4.1, gpt-4.1-mini
- Codex CLI installed on snoke (for pull-based agent)
- Redis and Laddr API accessible from snoke (already the case)

## Implementation Notes

**Env var expansion:** The YAML config uses `${OPENAI_API_KEY}` but `yaml.safe_load()` does not expand shell variables. The same pattern exists in `venice.yml` with `${VENICE_API_KEY}`. Verify how the existing workers handle this (envsubst wrapper, systemd env injection, or literal key in the deployed config). If none of these exist, `load_worker_config` may need a small enhancement to resolve `${...}` patterns from `os.environ`.

**Model aliases:** The `ModelAliasRegistry` is currently empty (no `.register()` calls in the codebase). The identity mappings (`gpt-5.4` → `gpt-5.4`) are technically no-ops. Consider registering shorthand aliases instead (e.g., `gpt5` → `gpt-5.4`) or skip the aliases file change if the dispatcher already matches on exact model IDs from `cloud_providers`.

**Venice migration:** `venice.yml` has the same top-level `models` bug — it should be migrated to `cloud_providers` as a prerequisite, not a side task, since it validates the pattern before applying it to codex.
