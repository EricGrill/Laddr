# Godot Mission Control — Design Spec

## Overview

A 2D isometric Godot 4.x (GDScript) office simulation that visualizes the live Laddr job orchestration system. Fat, wobbly, Claude-styled blob agents fetch jobs from mailboxes, carry them to stations, process work, and deliver results. The world layout is data-driven from JSON files. Real-time state comes from the existing `/ws/mission-control` WebSocket event stream.

The existing Pixi.js 2D Mission Control in the React dashboard is preserved — users choose between the two views.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Full MVP (Phases 1-3) | Filters, focus controls, bottleneck alerts, polished animations |
| Location | `godot-mission-control/` in Laddr repo | Colocated with backend and dashboard |
| Existing 2D | Keep both views | Transition period, different use cases |
| Data source | Live backend, no internal simulation | Backend already handles orchestration |
| Engine | Godot 4.x, GDScript | Best 2D tooling, native language |
| Art style | Cozy Claude-like blobs | Fat, wobbly, expressive, warm palette |
| Camera | Isometric (45-degree) | Classic sim feel, good depth + charm |
| Architecture | Data-driven layout | JSON defines world, WorldBuilder spawns it |
| Backend connection | Existing `/ws/mission-control` WebSocket | Same event model as React dashboard |

## Project Structure

```
godot-mission-control/
├── project.godot
├── assets/
│   ├── sprites/              # Agent blobs, stations, items, effects
│   ├── tilesets/             # Isometric floor tiles
│   └── audio/               # SFX (pickup, drop, complete, error)
├── data/
│   ├── office_layout.json   # Station positions, waypoints, desk locations
│   └── station_types.json   # Station metadata (capacity, icon, role)
├── scenes/
│   ├── main.tscn            # Root scene — camera, UI layer, world container
│   ├── agents/
│   │   └── blob_agent.tscn  # Reusable agent scene
│   ├── stations/
│   │   └── station.tscn     # Generic station scene (configured by type)
│   ├── items/
│   │   └── job_packet.tscn  # Job visual (envelope/package)
│   └── ui/
│       ├── hud.tscn         # Top bar — connection, metrics
│       ├── inspector.tscn   # Click-to-inspect panel
│       └── mission_panel.tscn  # Side panel — roster, queues, alerts
├── scripts/
│   ├── autoloads/
│   │   ├── web_socket_client.gd  # WebSocket connection to Laddr
│   │   ├── world_state.gd       # Normalized state store
│   │   └── event_bus.gd         # Signal hub
│   ├── world/
│   │   ├── world_builder.gd     # Reads layout JSON, spawns everything
│   │   ├── nav_graph.gd         # Waypoint graph + pathfinding
│   │   └── isometric_utils.gd   # Grid-to-screen coordinate conversion
│   ├── agents/
│   │   ├── agent_controller.gd  # FSM brain
│   │   ├── agent_animator.gd    # Squash/stretch, wobble, emotes
│   │   └── agent_mover.gd      # Path following
│   ├── stations/
│   │   ├── station_controller.gd  # Queue management, visual state
│   │   └── station_effects.gd    # Activity particles, lights
│   └── ui/
│       ├── hud_controller.gd
│       ├── inspector_controller.gd
│       └── mission_panel_controller.gd
```

## System 1: Data-Driven World & Navigation

### Office Layout (office_layout.json)

Defines the full world: floor dimensions, station placements, waypoints, and valid paths between stations.

```json
{
  "floor": {
    "width": 20,
    "height": 14,
    "tile_size": 64
  },
  "stations": [
    {
      "id": "intake",
      "type": "intake",
      "label": "Mailroom",
      "grid_pos": [3, 2],
      "capacity": 10,
      "visual": "mailbox"
    },
    {
      "id": "dispatcher",
      "type": "router",
      "label": "Dispatch Desk",
      "grid_pos": [10, 7],
      "capacity": 5,
      "visual": "dispatch_hub"
    },
    {
      "id": "llm_station",
      "type": "research",
      "label": "Think Tank",
      "grid_pos": [5, 10],
      "capacity": 3,
      "visual": "research_pod"
    },
    {
      "id": "code_forge",
      "type": "code",
      "label": "Code Forge",
      "grid_pos": [15, 10],
      "capacity": 3,
      "visual": "terminal_desk"
    },
    {
      "id": "review_deck",
      "type": "review",
      "label": "Review Bay",
      "grid_pos": [15, 4],
      "capacity": 2,
      "visual": "scanner_gate"
    },
    {
      "id": "output_dock",
      "type": "output",
      "label": "Ship It!",
      "grid_pos": [18, 7],
      "capacity": 8,
      "visual": "output_chute"
    },
    {
      "id": "supervisor",
      "type": "supervisor",
      "label": "Boss Desk",
      "grid_pos": [10, 2],
      "capacity": 1,
      "visual": "command_chair"
    },
    {
      "id": "error_chamber",
      "type": "error",
      "label": "Oops Corner",
      "grid_pos": [2, 12],
      "capacity": 5,
      "visual": "error_bin"
    }
  ],
  "waypoints": [
    { "id": "wp_center", "grid_pos": [10, 7] },
    { "id": "wp_top", "grid_pos": [10, 3] },
    { "id": "wp_left", "grid_pos": [4, 7] },
    { "id": "wp_right", "grid_pos": [16, 7] },
    { "id": "wp_bottom", "grid_pos": [10, 11] }
  ],
  "paths": [
    ["intake", "wp_left", "wp_center", "dispatcher"],
    ["dispatcher", "wp_center", "wp_bottom", "llm_station"],
    ["dispatcher", "wp_center", "wp_bottom", "code_forge"],
    ["dispatcher", "wp_center", "wp_top", "review_deck"],
    ["dispatcher", "wp_center", "wp_right", "output_dock"],
    ["dispatcher", "wp_top", "supervisor"],
    ["dispatcher", "wp_left", "error_chamber"]
  ]
}
```

### WorldBuilder

- Reads `office_layout.json` at `_ready()`
- Spawns station scenes at isometric screen positions derived from `grid_pos`
- Builds the `NavGraph` from waypoints and paths
- Isometric conversion: `screen_x = (x - y) * tile_half_w`, `screen_y = (x + y) * tile_half_h`

### NavGraph

- Weighted graph over waypoints + station positions
- Agents request path from station A to station B → get ordered list of world positions
- Paths array defines valid routes — agents don't free-roam
- Adding a new station = add an entry to JSON + a visual scene, no code changes

## System 2: WebSocket Integration & State Management

### Data Flow

```
Laddr Backend                     Godot
─────────────                     ─────
/ws/mission-control  ──WebSocket──►  WebSocketClient (autoload)
                                        │
                                        │ parse JSON, emit typed signals
                                        ▼
                                     WorldState (autoload)
                                        │
                                        │ update dictionaries, emit change signals
                                        ▼
                                  ┌─────┼──────────┐
                                  │     │          │
                               Agents  Stations    UI
```

### WebSocketClient (autoload)

- Connects to `ws://{host}/ws/mission-control` on startup
- Auto-reconnect with exponential backoff (base 2s, max 30s, 10 attempts)
- Parses each JSON message, emits typed signals per event type
- On `snapshot` event, bulk-loads everything into WorldState

### WorldState (autoload)

Single source of truth — five dictionaries:

```gdscript
var agents: Dictionary = {}    # agent_id → {id, name, role, state, current_job_id, ...}
var jobs: Dictionary = {}      # job_id → {id, type, priority, state, assigned_agent_id, ...}
var stations: Dictionary = {}  # station_id → {id, type, state, queue_depth, active_job_ids, ...}
var workers: Dictionary = {}   # worker_id → {id, name, capabilities, status, ...}
var metrics: Dictionary = {}   # total_jobs, active_agents, error_count, etc.

signal agent_changed(agent_id)
signal job_changed(job_id)
signal station_changed(station_id)
signal job_completed(job_id)
signal job_failed(job_id, reason)
signal metrics_changed()
signal worker_changed(worker_id, is_new)
```

### Deriving Semantic Events from `job_updated`

The backend does **not** emit `job_assigned` or `job_handoff` events. All non-terminal job state changes arrive as `job_updated`. WorldState must diff old vs new job state to derive visual transitions:

```gdscript
func _on_job_updated(job: Dictionary) -> void:
    var old_job = jobs.get(job.id, {})
    jobs[job.id] = job

    # Derive assignment: assignedAgentId went from null to a value
    if old_job.get("assignedAgentId") == null and job.get("assignedAgentId") != null:
        job_assigned.emit(job.id, job.assignedAgentId, job.get("currentStationId", ""))

    # Derive handoff: currentStationId changed
    if old_job.get("currentStationId") != job.get("currentStationId") and old_job.get("currentStationId") != null:
        job_handoff.emit(job.id, old_job.currentStationId, job.currentStationId)

    job_changed.emit(job.id)

signal job_assigned(job_id, agent_id, station_id)  # derived from job_updated diff
signal job_handoff(job_id, from_station_id, to_station_id)  # derived from job_updated diff
```

### Worker Registration Note

The backend sends `worker_registered` for both new workers **and** status updates to existing workers. WorldState must check whether the worker ID already exists to distinguish spawn vs update:

```gdscript
func _on_worker_registered(worker: Dictionary) -> void:
    var is_new = not workers.has(worker.id)
    workers[worker.id] = worker
    worker_changed.emit(worker.id, is_new)
    # Visual layer: is_new=true → spawn animation, is_new=false → status update only
```

### Backend Key Convention

The backend sends camelCase keys (`queueDepth`, `activeJobIds`, `assignedAgentId`). The Godot WorldState stores them as-is (camelCase) to avoid translation overhead. GDScript accesses them via dictionary bracket notation: `job["assignedAgentId"]`.

### Event-to-Visual Mapping

| WebSocket Event | WorldState Update | Visual Result |
|---|---|---|
| `snapshot` | Bulk load all entities | Spawn all agents, populate stations |
| `job_created` | Add to `jobs` dict | Envelope pops into intake mailbox |
| `job_updated` | Diff old/new, derive assignment/handoff | See derived signals below |
| *(derived)* assignment | `job_assigned` signal | Agent wobbles to mailbox, picks up envelope |
| *(derived)* handoff | `job_handoff` signal | Agent carries envelope from station A to B |
| `agent_updated` | Update agent state | Agent changes animation (idle/working/blocked) |
| `job_completed` | Mark completed | Happy wobble, envelope flies to output |
| `job_failed` | Mark failed | Sad shake, envelope turns red, goes to error corner |
| `station_updated` | Update station state | Station glow changes (idle/active/saturated) |
| `metrics_updated` | Update metrics dict | HUD refreshes (total jobs, active agents, error count) |
| `worker_registered` | Add or update worker | New: blob bounces in. Existing: status update |
| `worker_deregistered` | Remove worker | Blob waves goodbye, shrinks away |

### Key Principle

WorldState is a dumb data store. It doesn't know about Godot nodes. Agents and stations subscribe to its signals and drive their own visuals. Data layer is testable, visual layer is independent.

## System 3: Agent System — The Blob Brain

Each blob agent is a scene with three cooperating scripts.

### agent_controller.gd — FSM

```
States:
  IDLE        → standing at home position, gentle bob animation
  MOVING      → following nav path to target, wobble walk
  PICKING_UP  → at mailbox/station, reach + grab animation
  CARRYING    → moving with job packet held overhead
  WORKING     → at station, task-specific animation loop
  DELIVERING  → dropping off completed job
  BLOCKED     → stuck, confused wobble, question mark emote
  ERRORED     → sad shake, sparks, sweat drops
  OFFLINE     → greyed out, sleeping Zzzs
```

State transitions driven entirely by WorldState signals (including derived signals from `job_updated` diffs), not internal timers:

1. `job_assigned` signal (derived) → switch to MOVING toward job's current station
2. Arrive → PICKING_UP, brief grab animation
3. Grab complete → CARRYING, path to target station
4. `job_handoff` signal (derived) → reroute CARRYING to new target station
5. Arrive at station → WORKING, station-specific loop
6. `job_completed` signal → DELIVERING, carry to output dock
7. Delivery done → IDLE, wobble back to home spot
8. `job_failed` signal → ERRORED, sad animation, carry to error corner
9. `agent_updated` with state=blocked → BLOCKED, confused wobble
10. `agent_updated` with state=offline → OFFLINE, greyed out, sleeping

### agent_animator.gd — Charm Engine

- **Wobble walk**: sinusoidal body rotation + vertical bounce as blobs waddle
- **Squash/stretch**: compress on landing, stretch on jumping/reaching
- **Carry pose**: job packet floats above head, bobs opposite to walk cycle
- **Idle fidgets**: random interval — look around, tiny hop, yawn
- **Emotes**: thought bubble icons (lightbulb, question mark, exclamation, heart, skull)
- **Color tinting**: unique Claude-palette tint per agent based on worker ID hash (terracotta, warm orange, soft peach, dusty rose)

### agent_mover.gd — Path Following

- Receives ordered waypoint list from NavGraph
- Moves between waypoints using isometric-aware interpolation
- Speed varies by state: normal walk, hurried carry (high priority), slow blocked shuffle
- Arrives within threshold → emits `arrived` signal → controller advances state

### Claude Blob Visual Spec

- Round body, ~2:1 width-to-height ratio (fat and low)
- Two large dot eyes with white shine spots
- No visible mouth normally — appears for emotes (smile, frown, O-surprise)
- Tiny stubby feet that patter during walk
- Soft shadow underneath
- Warm color palette: base body in Claude terracotta/orange tones
- Role accessories:
  - Router blobs: blue visor accessory
  - Research blobs: tiny glasses
  - Code blobs: headphones
  - Review blobs: clipboard
  - Supervisor: slightly larger, tiny hat

## System 4: Station Visuals & Job Packets

### Stations

Generic scenes configured by type from `station_types.json`. Each station has:

- Base sprite (desk, mailbox, terminal, etc.)
- Queue indicator — visible stack of waiting job packets, count badge
- Activity indicator — idle (dim), active (glow), saturated (pulsing), errored (red flash)
- Interaction slots — positions where agents stand while working

### Station Visual Personalities

| Station Type | Visual | Activity Animation |
|---|---|---|
| Intake (Mailroom) | Overflowing mailbox with flag | Letters wiggle when queue grows |
| Router (Dispatch) | Central desk with spinning inbox tray | Papers shuffle, tray spins faster when busy |
| Research (Think Tank) | Cozy reading nook with floating books | Books orbit faster, lightbulbs appear |
| Code (Code Forge) | Terminal desk with multiple monitors | Screens fill with green text, keyboard sparks |
| Review (Review Bay) | Desk with magnifying glass + stamp pad | Magnifying glass bobs, stamps slam down |
| Output (Ship It!) | Outbox chute with conveyor belt | Packages slide down chute, confetti on completion |
| Supervisor (Boss Desk) | Elevated desk with big chair, alert board | Alert lights blink, chair swivels |
| Error (Oops Corner) | Bin with caution tape, red lamp | Lamp flashes, smoke puffs, bin wobbles |

### Saturation Feedback

Queue depth thresholds drive visual urgency:

- Normal (< 50% capacity): calm glow
- Busy (50-80%): faster animations, yellow tint
- Saturated (> 80%): pulsing red outline, queue spilling over, alarm wobble

### Job Packets

Small visual items that exist in the world:

- **Shape**: rounded envelope/parcel
- **Priority coloring**: low (grey), normal (blue), high (orange pulse), critical (red pulse + glow)
- **State indicators**:
  - Queued: sits in station's queue stack
  - Carried: floats above agent's head
  - Processing: orbits the station with progress ring
  - Completed: green checkmark flash, slides to output
  - Failed: turns red, cracks, wobbles to error corner
- **Packet label**: tiny text showing job type abbreviation (visible on hover/select)

### Job Lifecycle Visuals

```
1. job_created     → Envelope pops into existence at Intake (bounce-in)
2. job_assigned    → Agent waddles to Intake, grabs envelope (squash on pickup)
3. carrying        → Envelope bobs above agent's head as they walk
4. arrive station  → Agent places envelope on desk (stretch on place)
5. processing      → Envelope spins slowly at station, progress ring fills
6. job_completed   → Envelope gets green stamp, carried to Output (confetti burst)
7. job_failed      → Envelope turns red + cracks, carried to Error Corner
```

## System 5: UI Overlay & Mission Control Panel

CanvasLayer on top of the isometric world. Three components:

### HUD (top bar)

- Connection status indicator (green/red/yellow dot)
- Live metrics: total jobs | active agents | queue depth | error count
- Playback speed slider (0.5x — 1x — 2x — 4x) — animation speed only, not backend
- Fullscreen toggle

### Mission Panel (left sidebar, collapsible)

- **Agent Roster**: scrollable list of all blobs
  - Each row: color swatch, name, state icon, current job
  - Click row → camera pans to agent, selects them
- **Queue Dashboard**: one row per station
  - Station icon, name, queue depth bar (fills/colors by saturation)
  - Sparkline of throughput over last N minutes
- **Alert Feed**: scrolling list of recent notable events
  - Job failures, agent errors, stations saturated
  - Newest at top, fades old entries

### Inspector Panel (right side, appears on click)

Click any entity to inspect:

- **Agent Inspector**: name, role, state, current job, efficiency %, recent job history (last 5)
- **Job Inspector**: type, priority, state, assigned agent, current station, path history, metadata
- **Station Inspector**: type, state, capacity, queue depth, active jobs, throughput rate

### Interaction Model

- Click entity → select, open inspector, camera eases to center on it
- Click empty space → deselect, close inspector
- Hover entity → lightweight tooltip (name + state)
- Right-click agent → "follow" mode, camera tracks that agent
- Camera: middle-mouse drag pan, scroll zoom, WASD pan, double-click station to zoom-fit, Home to reset

## System 6: Performance & Scalability

### Targets

- 20-100 active agents
- 100-1000 visible jobs
- Smooth 60fps on modern desktop

### Strategies

- Object pooling for job packets and particle effects
- Agents beyond viewport culled from animation updates (still track state)
- Station animations simplified at far zoom levels
- Job packet rendering: at high counts, switch from individual sprites to station queue count badges
- NavGraph pathfinding cached — paths between stations are static, compute once at startup

## Scope Summary

### Phase 1 deliverables (vertical slice)

- Godot project skeleton with data-driven world
- WebSocket connection consuming live events
- One station type fully animated
- One agent blob doing full pickup → carry → work → deliver loop
- Basic HUD with connection status

### Phase 2 deliverables (full pipeline)

- All 8 station types with unique visuals
- Multiple agents with role-based accessories
- Full job lifecycle animations
- Mission panel with agent roster and queue dashboard
- Inspector panel for all entity types

### Phase 3 deliverables (operational polish)

- Filters by job type/priority/state, agent role/state
- Camera focus controls (follow agent, zoom to station)
- Saturation/bottleneck alerts with visual feedback
- Alert feed
- Idle fidgets, emotes, and animation polish
- Playback speed control
- Performance optimization pass
