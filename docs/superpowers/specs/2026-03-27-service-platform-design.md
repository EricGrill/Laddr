# Service Platform — Unified Service Discovery & Agent Injection

## Overview

A centralized service registry that auto-discovers MCP tools, merges them with human-authored playbooks, advertises capabilities to agents via prompt injection, and exposes a service catalog in the dashboard for operator visibility and direct job submission.

## Problem

Laddr workers connect to MCP servers (holocron, nano-banana) that provide powerful tools — image generation, knowledge management, deployments, system operations — but agents don't know these services exist unless explicitly told. Operators have no visibility into what services the platform offers. There's no way to submit service-specific jobs from the dashboard.

## Goals

1. Agents automatically know what platform services are available and how to use them.
2. Operators can see all services, their availability, and submit jobs through the dashboard.
3. Adding a new service requires only a YAML config entry and an MCP connection — no code changes.
4. The system degrades gracefully when MCPs are unavailable.

## Non-Goals

1. Not building a general-purpose MCP marketplace or plugin system.
2. Not replacing the existing capability matcher — services layer on top of it.
3. Not building per-tool UIs in the dashboard — job submission is prompt-based, not form-per-tool.

## Architecture

### Approach: Centralized Service Registry

A single new module (`service_registry.py`) owns the service catalog. It merges a static YAML config (service definitions, categories, playbooks) with dynamic MCP tool discovery (schemas, availability). Both the dashboard and agent prompt builder consume the same registry.

```
┌─────────────────────────────────────────────────────────┐
│                    services.yml                          │
│  (names, categories, playbooks, tool lists)             │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              ServiceRegistry (singleton)                 │
│                                                         │
│  ┌──────────────┐    ┌───────────────────┐              │
│  │ Static Config │───▶│  Merged Catalog   │              │
│  └──────────────┘    │                   │              │
│  ┌──────────────┐    │  ServiceDefinition│              │
│  │ MCP Discovery │───▶│  per service      │              │
│  └──────────────┘    └───────────────────┘              │
└───────────┬──────────────────┬──────────────────────────┘
            │                  │
      ┌─────▼─────┐    ┌──────▼──────┐
      │  Agent     │    │  Dashboard  │
      │  Prompt    │    │  /services  │
      │  Builder   │    │  page       │
      └───────────┘    └─────────────┘
```

## Components

### 1. Service Registry Module

**File:** `lib/laddr/src/laddr/core/service_registry.py`

Singleton initialized at API startup. Responsibilities:

- Load `services.yml` config at startup
- Connect to declared MCPs and discover available tools + schemas
- Merge config with discovery: config provides human context, MCP provides tool reality
- Cache the merged catalog in memory
- Refresh periodically (every 60s) and on-demand
- Expose methods for API endpoints and prompt builder

**Core data structure:**

```python
@dataclass
class ServiceDefinition:
    id: str                    # e.g. "image-generation"
    name: str                  # e.g. "Image Generation"
    category: str              # creative | data | ops | system
    description: str           # one-line summary
    mcp: str                   # MCP server name, e.g. "nano-banana"
    playbook: str              # full agent instructions (markdown)
    tools: list[str]           # tool names from config
    available: bool            # from MCP discovery
    tool_schemas: dict         # from MCP discovery, keyed by tool name
    icon: str                  # emoji for dashboard display
```

**Key methods:**

```python
class ServiceRegistry:
    def __init__(self, config_path: str, mcp_providers: dict)
    async def discover(self) -> None            # connect to MCPs, merge catalog
    def get_all(self) -> list[ServiceDefinition]
    def get(self, service_id: str) -> ServiceDefinition | None
    def get_available(self) -> list[ServiceDefinition]
    def get_by_category(self, category: str) -> list[ServiceDefinition]
    def build_playbook(self, job: dict) -> str  # build prompt injection for a job
    async def refresh(self) -> None             # force rediscovery
```

### 2. Service Configuration

**File:** `lib/laddr/src/laddr/config/services.yml`

Each service entry defines the human-authored layer:

```yaml
services:
  - id: image-generation
    name: Image Generation
    category: creative
    icon: "🎨"
    description: Generate images from text prompts using Gemini.
    mcp: nano-banana
    tools:
      - generate_image
      - generate_blog_images
    playbook: |
      ## When to use
      Use when a task requires creating, illustrating, or visualizing something
      as an image. Supports single images and coordinated blog image sets.

      ## When NOT to use
      - Don't use for diagrams, charts, or data visualizations — generate SVG or
        use a charting library instead.
      - Don't use for screenshots or screen captures.
      - Don't use when text description is sufficient.

      ## Tools
      - `generate_image(prompt, filename, aspectRatio)` — Generate a single image.
        - aspectRatio options: 1:1, 16:9, 9:16, 4:3, 3:4
        - prompt should be specific: include style, mood, composition, lighting.
      - `generate_blog_images(slug, heroPrompt, sectionPrompts, style)` — Generate
        a coordinated set of images for a blog post.
        - Applies consistent style across all images.
        - sectionPrompts is an array of {heading, prompt} objects.

      ## Patterns
      - Be specific and descriptive in prompts. "A sunset" → "A warm golden sunset
        over calm ocean water, watercolor style, wide composition, soft light."
      - Choose aspect ratio based on context: 16:9 for headers/banners, 1:1 for
        avatars/thumbnails, 9:16 for mobile/stories.
      - For blog sets, define a style string that unifies the visual language.

      ## Error handling
      If generation fails, simplify the prompt (remove complex details) and retry
      once. If it fails again, report the error — don't keep retrying.

  - id: knowledge-base
    name: Knowledge Base
    category: data
    icon: "📚"
    description: Persistent markdown storage with semantic search via Fulcrum.
    mcp: holocron
    tools:
      - knowledge_search
      - knowledge_get
      - knowledge_create
      - knowledge_update
      - knowledge_delete
      - knowledge_list
    playbook: |
      ## When to use
      Use when a task requires finding, storing, or updating persistent information
      that should survive beyond a single conversation. The knowledge base contains
      device profiles, service configs, guides, plans, and general documentation.

      ## When NOT to use
      - Don't use for ephemeral/temporary data — use agent memory instead.
      - Don't use for large binary files or images.
      - Don't store secrets, credentials, or API keys.

      ## Tools
      - `knowledge_search(query)` — Semantic search across all entries. Start here
        to discover what exists before creating new entries.
      - `knowledge_get(slug)` — Fetch a specific entry. Slugs contain slashes
        (e.g., "command-deck/darth"). Do not URL-encode them.
      - `knowledge_create(slug, title, type, category, content, metadata)` — Create
        a new entry. Types: device, service, stack, network, plan, guide.
      - `knowledge_update(slug, ...)` — Update an entry. Metadata is auto-merged,
        not replaced.
      - `knowledge_delete(slug)` — Remove an entry.
      - `knowledge_list(category, type)` — Browse entries by category or type.

      ## Patterns
      - Always `knowledge_search` before `knowledge_create` to avoid duplicates.
      - Use descriptive slugs with category prefixes: "devices/router-main",
        "guides/deployment-checklist".
      - Keep entries focused — one topic per entry, link between them.

      ## Error handling
      If a slug is not found, search for it — it may have been renamed. If search
      returns nothing, confirm with the user before creating a new entry.

  - id: deployments
    name: Deployments
    category: ops
    icon: "🚀"
    description: Deploy Docker stacks, static sites, manage SSL, and upload assets.
    mcp: holocron
    tools:
      - deploy_docker_stack
      - deploy_static_site
      - get_deployment
      - list_deployments
      - remove_deployment
      - renew_ssl
      - upload_asset
    playbook: |
      ## When to use
      Use when a task involves deploying, updating, or managing hosted services
      and websites on the Fulcrum infrastructure.

      ## When NOT to use
      - Don't deploy without explicit user confirmation.
      - Don't remove deployments without double-checking with the user.
      - Don't use for local development — these are production operations.

      ## Tools
      - `deploy_docker_stack(name, compose, env)` — Deploy a Docker Compose stack.
      - `deploy_static_site(name, path)` — Deploy static files as a website.
      - `list_deployments()` — List all active deployments.
      - `get_deployment(name)` — Get details of a specific deployment.
      - `remove_deployment(name)` — Remove a deployment. REQUIRES user confirmation.
      - `renew_ssl(domain)` — Renew SSL certificate for a domain.
      - `upload_asset(file, destination)` — Upload a file to the asset store.

      ## Patterns
      - Always `list_deployments` first to understand current state.
      - Before deploying, confirm the name and configuration with the user.
      - After deploying, verify with `get_deployment` that it's healthy.

      ## Error handling
      Deployment failures should be reported with full error context. Do not
      retry deployments automatically — report and let the user decide.

  - id: job-orchestration
    name: Job Orchestration
    category: ops
    icon: "🔄"
    description: Submit, monitor, escalate, and manage jobs across Fulcrum.
    mcp: holocron
    tools:
      - submit_job
      - execute_job
      - list_jobs
      - get_job
      - get_job_tree
      - update_job
      - stop_job
      - resubmit_job
      - reassign_job
      - brainstorm_job
      - escalate_job
      - create_children
      - job_claim
      - job_complete
      - job_inbox
      - job_post
      - job_status
      - job_thread
    playbook: |
      ## When to use
      Use when a task requires coordinating work across the Fulcrum platform —
      submitting jobs to other workers, monitoring job progress, or managing
      complex multi-step workflows.

      ## When NOT to use
      - Don't use for tasks you can complete directly — only delegate when needed.
      - Don't create circular job dependencies.

      ## Tools
      - `submit_job(type, payload, priority)` — Submit a new job to the queue.
      - `execute_job(type, payload)` — Submit and wait for result (synchronous).
      - `list_jobs(status, limit)` — List jobs with optional status filter.
      - `get_job(id)` — Get full job details including history.
      - `get_job_tree(id)` — Get job and all child jobs as a tree.
      - `update_job(id, status, result)` — Update job status or result.
      - `stop_job(id)` — Cancel a running job.
      - `resubmit_job(id)` — Retry a failed job.
      - `reassign_job(id, worker)` — Move a job to a different worker.
      - `brainstorm_job(id)` — Generate approaches for a job.
      - `escalate_job(id, reason)` — Escalate to supervisor/human.
      - `create_children(parent_id, children)` — Break a job into sub-jobs.

      ## Patterns
      - Use `execute_job` for simple delegate-and-wait. Use `submit_job` +
        polling via `get_job` for long-running work.
      - For complex tasks, use `brainstorm_job` first, then `create_children`
        to decompose into parallel sub-jobs.
      - Monitor with `get_job_tree` to see overall progress.

      ## Error handling
      If a submitted job fails, check the error via `get_job`. Consider
      `resubmit_job` for transient failures, or `escalate_job` for
      persistent issues.

  - id: system-operations
    name: System Operations
    category: system
    icon: "⚙️"
    description: Server health, metrics, SSH execution, file operations, and diagnostics.
    mcp: holocron
    tools:
      - server_health
      - server_metrics
      - system_info
      - ssh_exec
      - exec_command
      - list_directory
      - read_file
    playbook: |
      ## When to use
      Use when a task requires checking infrastructure health, running commands
      on remote servers, or reading files from the Fulcrum system.

      ## When NOT to use
      - Don't run destructive commands (rm -rf, drop database, etc.) without
        explicit user confirmation.
      - Don't use for local operations — these target the Fulcrum server.

      ## Tools
      - `server_health()` — Quick health check of all services.
      - `server_metrics()` — Detailed CPU, memory, disk, network metrics.
      - `system_info()` — OS, uptime, installed packages.
      - `ssh_exec(command)` — Execute a shell command on the server.
      - `exec_command(command)` — Execute a command in the Fulcrum environment.
      - `list_directory(path)` — List files in a directory.
      - `read_file(path)` — Read a file's contents.

      ## Patterns
      - Start with `server_health` for a quick overview before diving deeper.
      - Use `server_metrics` when investigating performance issues.
      - Prefer `read_file` over `ssh_exec cat` for reading files.

      ## Error handling
      If SSH commands fail, check `server_health` first — the server may be
      unreachable. Report connection failures clearly.

  - id: plans
    name: Project Plans
    category: data
    icon: "📋"
    description: Create and manage structured project plans with lifecycle tracking.
    mcp: holocron
    tools:
      - plan_upsert
      - plan_get
      - plan_list
    playbook: |
      ## When to use
      Use when a task involves creating, reviewing, or updating project plans
      that track multi-step initiatives with status.

      ## When NOT to use
      - Don't use for simple task lists — use knowledge base entries instead.
      - Don't use for ephemeral plans that won't be referenced again.

      ## Tools
      - `plan_upsert(slug, title, project, status, steps)` — Create or update
        a plan. Idempotent — safe to call multiple times. Statuses: draft,
        active, completed, archived.
      - `plan_get(slug)` — Fetch a plan by slug.
      - `plan_list(status, project)` — List plans with optional filters.

      ## Patterns
      - Use descriptive slugs: "2026-q1-auth-rewrite", "migration-postgres-15".
      - Update plan status as work progresses — don't leave stale plans as active.
      - Link plans to knowledge base entries for detailed documentation.

      ## Error handling
      Plans are idempotent — upsert won't fail on duplicates. If a plan isn't
      found, list plans to check for renamed slugs.

  - id: qa
    name: Q&A
    category: system
    icon: "💬"
    description: Ask questions to and answer questions from humans in the loop.
    mcp: holocron
    tools:
      - ask_question
      - answer_question
    playbook: |
      ## When to use
      Use when you need human input to proceed, or when a human has asked a
      question that needs an agent response.

      ## When NOT to use
      - Don't use for questions you can answer from available context.
      - Don't spam questions — batch related questions into one ask.

      ## Tools
      - `ask_question(question, context)` — Ask a human a question. Include
        enough context for them to answer without guessing.
      - `answer_question(question_id, answer)` — Respond to a pending question.

      ## Patterns
      - Frame questions clearly. Include what you've already tried and what
        specific input you need.
      - Check `job_inbox` for pending questions before asking new ones.

      ## Error handling
      Questions may go unanswered. If no response after a reasonable wait,
      escalate via `escalate_job` rather than re-asking.
```

### 3. API Endpoints

**New endpoints added to `lib/laddr/src/laddr/api/main.py`:**

```
GET  /api/services                 — Full service catalog
GET  /api/services/{service_id}    — Single service with full playbook
GET  /api/services/{service_id}/tools — Tool schemas for a service
POST /api/services/refresh         — Force MCP rediscovery
```

**Response format for `GET /api/services`:**

```json
{
  "services": [
    {
      "id": "image-generation",
      "name": "Image Generation",
      "category": "creative",
      "icon": "🎨",
      "description": "Generate images from text prompts using Gemini.",
      "mcp": "nano-banana",
      "tools": ["generate_image", "generate_blog_images"],
      "available": true
    }
  ],
  "summary": {
    "total": 7,
    "available": 6,
    "unavailable": 1,
    "last_discovered": "2026-03-27T10:30:00Z"
  }
}
```

**Response format for `GET /api/services/{service_id}`:**

```json
{
  "id": "image-generation",
  "name": "Image Generation",
  "category": "creative",
  "icon": "🎨",
  "description": "Generate images from text prompts using Gemini.",
  "mcp": "nano-banana",
  "playbook": "## When to use\n...",
  "tools": ["generate_image", "generate_blog_images"],
  "available": true,
  "tool_schemas": {
    "generate_image": { "type": "object", "properties": { ... } },
    "generate_blog_images": { "type": "object", "properties": { ... } }
  }
}
```

### 4. Agent Prompt Injection

**Integration point:** `lib/laddr/src/laddr/core/worker_process.py` — in the agent build step.

When `build_agent_config()` constructs an agent for a job:

1. Call `registry.build_playbook(job)` to get the injection block
2. Append to agent's `instructions` field

**Playbook builder logic:**

```python
def build_playbook(self, job: dict) -> str:
    """Build prompt injection block for a job's available services."""
    # If job specifies services, inject only those
    requested = job.get("services", [])
    if requested:
        services = [self.get(sid) for sid in requested if self.get(sid)]
    else:
        # Inject all available services
        services = self.get_available()

    if not services:
        return ""

    sections = ["# Available Platform Services\n"]
    sections.append(
        "You have access to the following services via MCP tools. "
        "Use them when your task requires their capabilities.\n"
    )

    for svc in services:
        sections.append(f"---\n\n## {svc.icon} {svc.name} ({svc.mcp})\n")
        sections.append(f"{svc.description}\n")
        sections.append(svc.playbook)
        sections.append("")

    return "\n".join(sections)
```

**Filtering modes:**
- Job specifies `services: ["image-generation"]` → inject only that service's playbook (focused)
- Job specifies `mcps: ["nano-banana"]` → inject all services from that MCP
- No service/MCP specified → inject full catalog (agent decides what to use)

**Token budget:** Each playbook targets 200-400 tokens. With 7 services, full injection is ~2-3K tokens.

### 5. Dashboard UI

**New files:**

| File | Purpose |
|------|---------|
| `dashboard/src/pages/Services.tsx` | Services catalog page |
| `dashboard/src/components/ServiceCard.tsx` | Individual service card |
| `dashboard/src/components/ServiceJobModal.tsx` | Job submission modal |
| `dashboard/src/components/PlaybookDrawer.tsx` | Playbook slide-out viewer |
| `dashboard/src/lib/queries/services.ts` | React Query hooks for `/api/services` |

**Services page layout:**

- **Top bar:** Title, summary stats ("5 available, 1 unavailable, last discovered 2m ago"), category filter pills
- **Card grid:** 2-column responsive grid of service cards
- **Each card shows:** icon, name, MCP source, description, tool tags (with "+N more" overflow), availability badge, "Submit Job" and "View Playbook" buttons
- **Unavailable services:** shown at 50% opacity, no submit button, "MCP connection unavailable" message

**Category filters:** All | Creative | Data | Ops | System — pill buttons in the top bar.

**Submit Job modal:**
- Service name and description at top
- Text area for the job prompt/instructions
- Priority selector (low/normal/high/critical)
- Optional: timeout override
- Submit button creates a job via `POST /api/jobs` with the service context

**Playbook Drawer:**
- Slide-out panel from the right
- Renders the playbook markdown
- Shows tool schemas in expandable sections
- Read-only — editing happens in `services.yml`

**Sidebar update:** Add "Services" link to `dashboard/src/components/Sidebar.tsx`.

## Startup & Refresh Flow

1. **API startup:** `ServiceRegistry(config_path, mcp_providers)` → loads YAML → calls `discover()`
2. **Discovery:** For each unique MCP in config, connect → list tools → match against config tool lists → set `available` and `tool_schemas`
3. **Periodic refresh:** Every 60 seconds, re-run discovery. Update availability and schemas. Log changes.
4. **Manual refresh:** `POST /api/services/refresh` triggers immediate rediscovery.
5. **Graceful degradation:** If an MCP is unreachable during discovery, mark its services as `available: false`. Config data (name, playbook, etc.) remains intact. Agents still get the playbook but with a note that tools are currently unavailable.

## Initial Service Catalog

| Service | Category | MCP | Tools |
|---------|----------|-----|-------|
| Image Generation | creative | nano-banana | generate_image, generate_blog_images |
| Knowledge Base | data | holocron | knowledge_search, knowledge_get, knowledge_create, knowledge_update, knowledge_delete, knowledge_list |
| Project Plans | data | holocron | plan_upsert, plan_get, plan_list |
| Deployments | ops | holocron | deploy_docker_stack, deploy_static_site, get_deployment, list_deployments, remove_deployment, renew_ssl, upload_asset |
| Job Orchestration | ops | holocron | submit_job, execute_job, list_jobs, get_job, get_job_tree, update_job, stop_job, resubmit_job, reassign_job, brainstorm_job, escalate_job, create_children, job_claim, job_complete, job_inbox, job_post, job_status, job_thread |
| System Operations | system | holocron | server_health, server_metrics, system_info, ssh_exec, exec_command, list_directory, read_file |
| Q&A | system | holocron | ask_question, answer_question |

## File Layout Summary

```
lib/laddr/src/laddr/
  core/
    service_registry.py              # NEW — registry module
  config/
    services.yml                     # NEW — service definitions + playbooks
  api/
    main.py                          # MODIFIED — add /api/services endpoints

dashboard/src/
  pages/
    Services.tsx                     # NEW — catalog page
  components/
    ServiceCard.tsx                  # NEW — card component
    ServiceJobModal.tsx              # NEW — job submission modal
    PlaybookDrawer.tsx               # NEW — playbook slide-out viewer
    Sidebar.tsx                      # MODIFIED — add Services link
  lib/
    queries/
      services.ts                   # NEW — API hooks
    api.ts                          # MODIFIED — add service API calls
```

## Testing Strategy

- **Unit tests** for `ServiceRegistry`: config loading, merge logic, playbook builder, filtering
- **Integration test**: registry with mock MCP provider → verify discovery and availability
- **API tests**: `/api/services` endpoint returns correct catalog shape
- **E2E test**: submit a job via dashboard → verify agent receives playbook injection
