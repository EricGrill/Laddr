# Godot Mission Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a 2D isometric Godot 4.x office simulation that visualizes live Laddr job orchestration with cute Claude-styled blob agents.

**Architecture:** Data-driven world from JSON layout files. Three autoloads form the backbone: WebSocketClient (connects to existing `/ws/mission-control`), WorldState (normalized state store with derived signals), EventBus (decoupled signal hub). Agents are CharacterBody2D scenes with 8-directional animation that subscribe to WorldState signals and navigate via `move_and_slide()`. The floor uses TileMapLayer with isometric tiles (inspired by [Godot isometric demo](https://github.com/godotengine/godot-demo-projects/tree/master/2d/isometric)).

**Tech Stack:** Godot 4.x, GDScript, GUT (Godot Unit Test) for logic tests, WebSocket for backend integration.

**Reference:** The isometric tile movement, depth sorting, and CharacterBody2D approach follows the [Godot isometric demo](https://github.com/godotengine/godot-demo-projects/tree/master/2d/isometric) — TileMapLayer with 128x64 isometric tiles, Y-sort for depth ordering, `move_and_slide()` for collision-aware movement, 8-directional animation based on velocity angle.

**Spec:** `docs/superpowers/specs/2026-03-26-godot-mission-control-design.md`

---

## Phase 1: Vertical Slice

Goal: One blob agent picks up a job from the mailbox, carries it to a station, works, and delivers it — connected to live backend data.

---

### Task 1: Project Skeleton & Autoload Registration

**Files:**
- Create: `godot-mission-control/project.godot`
- Create: `godot-mission-control/scripts/autoloads/event_bus.gd`
- Create: `godot-mission-control/scripts/autoloads/world_state.gd`
- Create: `godot-mission-control/scripts/autoloads/web_socket_client.gd`

- [ ] **Step 1: Create project directory structure**

```bash
cd /Users/eric/code/Laddr
mkdir -p godot-mission-control/{assets/{sprites,tilesets,audio},data,scenes/{agents,stations,items,ui},scripts/{autoloads,world,agents,stations,ui},tests}
```

- [ ] **Step 2: Create project.godot**

Create `godot-mission-control/project.godot` with:
- Project name: "Laddr Mission Control"
- Window size: 1280x720
- Stretch mode: canvas_items (for responsive UI)
- Register three autoloads: EventBus, WorldState, WebSocketClient
- Enable 2D physics (for click detection via Area2D)

```ini
; Engine configuration file.
; It's best edited using the editor UI and not directly,
; but it can also be manually edited.

config_version=5

[application]

config/name="Laddr Mission Control"
config/features=PackedStringArray("4.4", "GL Compatibility")
run/main_scene="res://scenes/main.tscn"

[autoload]

EventBus="*res://scripts/autoloads/event_bus.gd"
WorldState="*res://scripts/autoloads/world_state.gd"
WebSocketClient="*res://scripts/autoloads/web_socket_client.gd"

[display]

window/size/viewport_width=1280
window/size/viewport_height=720
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"

[rendering]

renderer/rendering_method="gl_compatibility"
```

- [ ] **Step 3: Create EventBus autoload**

Create `godot-mission-control/scripts/autoloads/event_bus.gd`:

```gdscript
extends Node
## Global signal hub for decoupled communication between systems.
## Visual layer events that don't belong in WorldState (which is pure data).

# Entity selection
signal entity_selected(entity_type: String, entity_id: String)
signal entity_deselected()
signal entity_hovered(entity_type: String, entity_id: String)
signal entity_unhovered()

# Camera
signal camera_focus_requested(world_position: Vector2)
signal camera_follow_requested(entity_type: String, entity_id: String)
signal camera_follow_stopped()
signal camera_reset_requested()

# UI
signal inspector_open_requested(entity_type: String, entity_id: String)
signal inspector_close_requested()
signal alert_posted(message: String, severity: String)

# Playback
signal playback_speed_changed(speed: float)
```

- [ ] **Step 4: Create WorldState autoload**

Create `godot-mission-control/scripts/autoloads/world_state.gd`:

```gdscript
extends Node
## Single source of truth for all entity state.
## Updated by WebSocketClient. Agents/stations/UI subscribe to signals.
## Stores camelCase keys as-is from the backend (no translation).

# Data stores
var agents: Dictionary = {}
var jobs: Dictionary = {}
var stations: Dictionary = {}
var workers: Dictionary = {}
var metrics: Dictionary = {}

# Direct backend event signals
signal agent_changed(agent_id: String)
signal job_changed(job_id: String)
signal station_changed(station_id: String)
signal job_completed(job_id: String)
signal job_failed(job_id: String, reason: String)
signal metrics_changed()
signal worker_changed(worker_id: String, is_new: bool)
signal worker_removed(worker_id: String)

# Derived signals (from job_updated diffs)
signal job_assigned(job_id: String, agent_id: String, station_id: String)
signal job_handoff(job_id: String, from_station_id: String, to_station_id: String)

# Snapshot
signal snapshot_loaded()


func clear() -> void:
	agents.clear()
	jobs.clear()
	stations.clear()
	workers.clear()
	metrics.clear()


func load_snapshot(data: Dictionary) -> void:
	clear()
	for agent in data.get("agents", []):
		agents[agent["id"]] = agent
	for job in data.get("jobs", []):
		jobs[job["id"]] = job
	for station in data.get("stations", []):
		stations[station["id"]] = station
	for worker in data.get("workers", []):
		workers[worker["id"]] = worker
	metrics = data.get("metrics", {})
	snapshot_loaded.emit()


func handle_agent_updated(agent: Dictionary) -> void:
	agents[agent["id"]] = agent
	agent_changed.emit(agent["id"])


func handle_job_created(job: Dictionary) -> void:
	jobs[job["id"]] = job
	job_changed.emit(job["id"])


func handle_job_updated(job: Dictionary) -> void:
	var old_job = jobs.get(job["id"], {})
	jobs[job["id"]] = job

	# Derive assignment: assignedAgentId went from null/empty to a value
	var old_agent = old_job.get("assignedAgentId", "")
	var new_agent = job.get("assignedAgentId", "")
	if (old_agent == null or old_agent == "") and new_agent != null and new_agent != "":
		job_assigned.emit(job["id"], new_agent, job.get("currentStationId", ""))

	# Derive handoff: currentStationId changed (and old wasn't empty)
	var old_station = old_job.get("currentStationId", "")
	var new_station = job.get("currentStationId", "")
	if old_station != null and old_station != "" and old_station != new_station:
		job_handoff.emit(job["id"], old_station, new_station)

	job_changed.emit(job["id"])


func handle_job_completed(job_id: String) -> void:
	if jobs.has(job_id):
		jobs[job_id]["state"] = "completed"
	job_completed.emit(job_id)


func handle_job_failed(job_id: String, reason: String) -> void:
	if jobs.has(job_id):
		jobs[job_id]["state"] = "failed"
	job_failed.emit(job_id, reason)


func handle_station_updated(station: Dictionary) -> void:
	stations[station["id"]] = station
	station_changed.emit(station["id"])


func handle_metrics_updated(new_metrics: Dictionary) -> void:
	metrics = new_metrics
	metrics_changed.emit()


func handle_worker_registered(worker: Dictionary) -> void:
	var is_new = not workers.has(worker["id"])
	workers[worker["id"]] = worker
	worker_changed.emit(worker["id"], is_new)


func handle_worker_deregistered(worker_id: String) -> void:
	workers.erase(worker_id)
	worker_removed.emit(worker_id)
```

- [ ] **Step 5: Create WebSocketClient autoload**

Create `godot-mission-control/scripts/autoloads/web_socket_client.gd`:

```gdscript
extends Node
## Connects to Laddr /ws/mission-control WebSocket.
## Parses JSON events and routes them to WorldState.

signal connection_state_changed(state: String)  # "connecting", "connected", "disconnected"

@export var server_url: String = "ws://localhost:8000/ws/mission-control"

var _socket: WebSocketPeer = WebSocketPeer.new()
var _connected: bool = false
var _reconnect_attempts: int = 0
var _max_reconnect_attempts: int = 10
var _reconnect_base_delay: float = 2.0
var _reconnect_max_delay: float = 30.0
var _reconnect_timer: float = 0.0
var _waiting_to_reconnect: bool = false

var connection_state: String = "disconnected"


func _ready() -> void:
	connect_to_server()


func connect_to_server() -> void:
	_set_connection_state("connecting")
	var err = _socket.connect_to_url(server_url)
	if err != OK:
		push_error("WebSocket connection failed: %s" % err)
		_schedule_reconnect()


func _process(delta: float) -> void:
	if _waiting_to_reconnect:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0:
			_waiting_to_reconnect = false
			connect_to_server()
		return

	_socket.poll()
	var state = _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_attempts = 0
				_set_connection_state("connected")
			while _socket.get_available_packet_count() > 0:
				var packet = _socket.get_packet()
				var text = packet.get_string_from_utf8()
				_handle_message(text)
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_set_connection_state("disconnected")
				_schedule_reconnect()


func send_command(action: String, params: Dictionary = {}) -> void:
	if not _connected:
		return
	var msg = {"action": action}
	msg.merge(params)
	_socket.send_text(JSON.stringify(msg))


func _handle_message(text: String) -> void:
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_error("Failed to parse WebSocket message: %s" % text.left(100))
		return

	var data = json.data
	if not data is Dictionary or not data.has("type"):
		return

	match data["type"]:
		"snapshot":
			WorldState.load_snapshot(data.get("data", {}))
		"agent_updated":
			WorldState.handle_agent_updated(data["agent"])
		"job_created":
			WorldState.handle_job_created(data["job"])
		"job_updated":
			WorldState.handle_job_updated(data["job"])
		"job_completed":
			WorldState.handle_job_completed(data["jobId"])
		"job_failed":
			WorldState.handle_job_failed(data["jobId"], data.get("reason", ""))
		"station_updated":
			WorldState.handle_station_updated(data["station"])
		"metrics_updated":
			WorldState.handle_metrics_updated(data.get("metrics", {}))
		"worker_registered":
			WorldState.handle_worker_registered(data["worker"])
		"worker_deregistered":
			WorldState.handle_worker_deregistered(data["workerId"])
		"command_ack":
			pass  # TODO Phase 3: surface to UI


func _schedule_reconnect() -> void:
	if _reconnect_attempts >= _max_reconnect_attempts:
		push_error("Max reconnect attempts reached")
		return
	_reconnect_attempts += 1
	var delay = min(_reconnect_base_delay * pow(2, _reconnect_attempts - 1), _reconnect_max_delay)
	_reconnect_timer = delay
	_waiting_to_reconnect = true
	_set_connection_state("disconnected")


func _set_connection_state(new_state: String) -> void:
	if connection_state != new_state:
		connection_state = new_state
		connection_state_changed.emit(new_state)
```

- [ ] **Step 6: Verify project opens in Godot**

```bash
# Open the project in Godot editor to verify it loads without errors.
# We need a minimal main.tscn first (created in Task 4).
# For now, just verify the file structure exists:
ls -la godot-mission-control/project.godot
ls -la godot-mission-control/scripts/autoloads/
```

- [ ] **Step 7: Commit**

```bash
cd /Users/eric/code/Laddr
git add godot-mission-control/
git commit -m "feat(mc): godot project skeleton with autoloads

WebSocketClient, WorldState, and EventBus autoloads.
WorldState derives job_assigned/job_handoff from job_updated diffs."
```

---

### Task 2: Isometric TileMap & NavGraph

**Files:**
- Create: `godot-mission-control/scripts/world/isometric_utils.gd`
- Create: `godot-mission-control/scripts/world/nav_graph.gd`
- Create: `godot-mission-control/tests/test_nav_graph.gd`

**Note:** Following the [Godot isometric demo](https://github.com/godotengine/godot-demo-projects/tree/master/2d/isometric), the floor uses TileMapLayer with isometric tile shape (128x64 tiles, 2:1 ratio). Godot's built-in `TileMapLayer.map_to_local()` and `local_to_map()` handle coordinate conversion, so `IsometricUtils` is a thin wrapper that delegates to the TileMapLayer when available.

- [ ] **Step 1: Implement isometric_utils.gd**

Create `godot-mission-control/scripts/world/isometric_utils.gd`:

```gdscript
class_name IsometricUtils
extends RefCounted
## Converts between grid coordinates and isometric screen coordinates.
## Delegates to TileMapLayer when available (preferred), falls back to manual math.
## Isometric tiles are 128x64 (2:1 ratio) following the Godot isometric demo.

var tile_map: TileMapLayer = null
var tile_half_w: float = 64.0   # 128 / 2
var tile_half_h: float = 32.0   # 64 / 2


func setup_with_tilemap(tm: TileMapLayer) -> void:
	tile_map = tm


func setup(tile_size: int) -> void:
	tile_half_w = tile_size / 2.0
	tile_half_h = tile_size / 4.0


func grid_to_screen(grid_pos: Vector2) -> Vector2:
	if tile_map:
		return tile_map.map_to_local(Vector2i(grid_pos))
	return Vector2(
		(grid_pos.x - grid_pos.y) * tile_half_w,
		(grid_pos.x + grid_pos.y) * tile_half_h
	)


func screen_to_grid(screen_pos: Vector2) -> Vector2:
	if tile_map:
		return Vector2(tile_map.local_to_map(screen_pos))
	return Vector2(
		(screen_pos.x / tile_half_w + screen_pos.y / tile_half_h) / 2.0,
		(screen_pos.y / tile_half_h - screen_pos.x / tile_half_w) / 2.0
	)
```

- [ ] **Step 3: Write NavGraph tests**

Create `godot-mission-control/tests/test_nav_graph.gd`:

```gdscript
extends GutTest
## Tests for waypoint graph and pathfinding.

var nav: Object


func before_each() -> void:
	nav = load("res://scripts/world/nav_graph.gd").new()


func test_add_node_and_retrieve() -> void:
	nav.add_node("intake", Vector2(100, 50))
	assert_eq(nav.get_position("intake"), Vector2(100, 50))


func test_unknown_node_returns_zero() -> void:
	assert_eq(nav.get_position("nonexistent"), Vector2.ZERO)


func test_add_path_creates_bidirectional_edges() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "b"])
	assert_true(nav.has_edge("a", "b"))
	assert_true(nav.has_edge("b", "a"))


func test_find_path_simple() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("wp", Vector2(50, 0))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "wp", "b"])
	var path = nav.find_path("a", "b")
	assert_eq(path, [Vector2(0, 0), Vector2(50, 0), Vector2(100, 0)])


func test_find_path_no_connection_returns_empty() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("b", Vector2(100, 0))
	# No path added between them
	var path = nav.find_path("a", "b")
	assert_eq(path, [])


func test_find_path_chooses_shortest() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("wp1", Vector2(50, 0))
	nav.add_node("wp2", Vector2(200, 200))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "wp1", "b"])          # short
	nav.add_path(["a", "wp2", "b"])          # long
	var path = nav.find_path("a", "b")
	# Should use wp1 (shorter distance)
	assert_eq(path[1], Vector2(50, 0))
```

- [ ] **Step 4: Implement nav_graph.gd**

Create `godot-mission-control/scripts/world/nav_graph.gd`:

```gdscript
class_name NavGraph
extends RefCounted
## Weighted graph over waypoints and stations.
## Agents ask for a path from station A to station B.
## Uses Dijkstra's algorithm for shortest path.

# node_id → Vector2 (screen position)
var _positions: Dictionary = {}
# node_id → Array[{neighbor: String, weight: float}]
var _edges: Dictionary = {}


func add_node(id: String, position: Vector2) -> void:
	_positions[id] = position
	if not _edges.has(id):
		_edges[id] = []


func get_position(id: String) -> Vector2:
	return _positions.get(id, Vector2.ZERO)


func has_edge(from_id: String, to_id: String) -> bool:
	if not _edges.has(from_id):
		return false
	for edge in _edges[from_id]:
		if edge["neighbor"] == to_id:
			return true
	return false


func add_path(node_ids: Array) -> void:
	for i in range(node_ids.size() - 1):
		var a = node_ids[i]
		var b = node_ids[i + 1]
		if not _positions.has(a) or not _positions.has(b):
			continue
		var weight = _positions[a].distance_to(_positions[b])
		_add_edge(a, b, weight)
		_add_edge(b, a, weight)


func find_path(from_id: String, to_id: String) -> Array:
	if not _positions.has(from_id) or not _positions.has(to_id):
		return []
	if from_id == to_id:
		return [_positions[from_id]]

	# Dijkstra's
	var dist: Dictionary = {}
	var prev: Dictionary = {}
	var visited: Dictionary = {}

	for node_id in _positions:
		dist[node_id] = INF
	dist[from_id] = 0.0

	while true:
		# Find unvisited node with smallest distance
		var current = ""
		var current_dist = INF
		for node_id in dist:
			if not visited.has(node_id) and dist[node_id] < current_dist:
				current = node_id
				current_dist = dist[node_id]

		if current == "" or current == to_id:
			break

		visited[current] = true

		for edge in _edges.get(current, []):
			var neighbor = edge["neighbor"]
			var new_dist = dist[current] + edge["weight"]
			if new_dist < dist[neighbor]:
				dist[neighbor] = new_dist
				prev[neighbor] = current

	# Reconstruct path
	if not prev.has(to_id) and from_id != to_id:
		return []

	var path_ids: Array = []
	var current = to_id
	while current != "":
		path_ids.push_front(current)
		current = prev.get(current, "")

	# Convert to positions
	var path_positions: Array = []
	for id in path_ids:
		path_positions.append(_positions[id])
	return path_positions


func _add_edge(from_id: String, to_id: String, weight: float) -> void:
	if not _edges.has(from_id):
		_edges[from_id] = []
	# Don't duplicate
	for edge in _edges[from_id]:
		if edge["neighbor"] == to_id:
			if weight < edge["weight"]:
				edge["weight"] = weight
			return
	_edges[from_id].append({"neighbor": to_id, "weight": weight})
```

- [ ] **Step 5: Run tests (if GUT is installed)**

```bash
# GUT tests run inside Godot. To run headless:
# godot --headless --path godot-mission-control -s addons/gut/gut_cmdln.gd -gdir=res://tests/
# If GUT is not installed yet, verify by opening project in Godot and running manually.
```

- [ ] **Step 6: Commit**

```bash
git add godot-mission-control/scripts/world/ godot-mission-control/tests/
git commit -m "feat(mc): isometric utils and nav graph with tests

Grid-to-screen coordinate conversion and Dijkstra pathfinding
over a waypoint graph."
```

---

### Task 3: Data Files & WorldBuilder

**Files:**
- Create: `godot-mission-control/data/office_layout.json`
- Create: `godot-mission-control/data/station_types.json`
- Create: `godot-mission-control/scripts/world/world_builder.gd`

- [ ] **Step 1: Create office_layout.json**

Create `godot-mission-control/data/office_layout.json` — exact content from the spec:

```json
{
  "floor": {
    "width": 20,
    "height": 14,
    "tile_size": 64
  },
  "stations": [
    { "id": "intake", "type": "intake", "label": "Mailroom", "grid_pos": [3, 2], "capacity": 10, "visual": "mailbox" },
    { "id": "dispatcher", "type": "router", "label": "Dispatch Desk", "grid_pos": [10, 7], "capacity": 5, "visual": "dispatch_hub" },
    { "id": "llm_station", "type": "research", "label": "Think Tank", "grid_pos": [5, 10], "capacity": 3, "visual": "research_pod" },
    { "id": "code_forge", "type": "code", "label": "Code Forge", "grid_pos": [15, 10], "capacity": 3, "visual": "terminal_desk" },
    { "id": "review_deck", "type": "review", "label": "Review Bay", "grid_pos": [15, 4], "capacity": 2, "visual": "scanner_gate" },
    { "id": "output_dock", "type": "output", "label": "Ship It!", "grid_pos": [18, 7], "capacity": 8, "visual": "output_chute" },
    { "id": "supervisor", "type": "supervisor", "label": "Boss Desk", "grid_pos": [10, 2], "capacity": 1, "visual": "command_chair" },
    { "id": "error_chamber", "type": "error", "label": "Oops Corner", "grid_pos": [2, 12], "capacity": 5, "visual": "error_bin" }
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

- [ ] **Step 2: Create station_types.json**

Create `godot-mission-control/data/station_types.json`:

```json
{
  "intake": {
    "label": "Mailroom",
    "color": "#e8a87c",
    "icon": "mailbox",
    "description": "Jobs enter the system here"
  },
  "router": {
    "label": "Dispatch",
    "color": "#85c1e9",
    "icon": "dispatch_hub",
    "description": "Routes jobs to appropriate stations"
  },
  "research": {
    "label": "Think Tank",
    "color": "#a8d8b9",
    "icon": "research_pod",
    "description": "LLM reasoning and analysis"
  },
  "code": {
    "label": "Code Forge",
    "color": "#f5b041",
    "icon": "terminal_desk",
    "description": "Code generation and execution"
  },
  "review": {
    "label": "Review Bay",
    "color": "#bb8fce",
    "icon": "scanner_gate",
    "description": "Quality review and validation"
  },
  "output": {
    "label": "Ship It!",
    "color": "#82e0aa",
    "icon": "output_chute",
    "description": "Completed jobs exit here"
  },
  "supervisor": {
    "label": "Boss Desk",
    "color": "#f1948a",
    "icon": "command_chair",
    "description": "Escalation and oversight"
  },
  "error": {
    "label": "Oops Corner",
    "color": "#e74c3c",
    "icon": "error_bin",
    "description": "Failed jobs land here"
  }
}
```

- [ ] **Step 3: Implement WorldBuilder**

Create `godot-mission-control/scripts/world/world_builder.gd`:

```gdscript
extends Node2D
## Reads office_layout.json and spawns stations, waypoints, and nav graph.
## Attach this to a Node2D in main.tscn.

const LAYOUT_PATH = "res://data/office_layout.json"
const STATION_TYPES_PATH = "res://data/station_types.json"

var iso: IsometricUtils = IsometricUtils.new()
var nav: NavGraph = NavGraph.new()
var station_types: Dictionary = {}
var station_nodes: Dictionary = {}  # station_id → Node2D

@export var station_scene: PackedScene  # Set in editor or via code


func _ready() -> void:
	var layout = _load_json(LAYOUT_PATH)
	station_types = _load_json(STATION_TYPES_PATH)

	if layout.is_empty():
		push_error("Failed to load office layout")
		return

	iso.setup(layout["floor"]["tile_size"])
	_build_nav_graph(layout)
	_spawn_stations(layout)


func get_nav_graph() -> NavGraph:
	return nav


func get_station_screen_pos(station_id: String) -> Vector2:
	return nav.get_position(station_id)


func _build_nav_graph(layout: Dictionary) -> void:
	# Add station nodes to graph
	for station in layout["stations"]:
		var grid_pos = Vector2(station["grid_pos"][0], station["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(station["id"], screen_pos)

	# Add waypoint nodes
	for wp in layout["waypoints"]:
		var grid_pos = Vector2(wp["grid_pos"][0], wp["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(wp["id"], screen_pos)

	# Add paths
	for path in layout["paths"]:
		var path_array: Array = []
		for id in path:
			path_array.append(id)
		nav.add_path(path_array)


func _spawn_stations(layout: Dictionary) -> void:
	for station_data in layout["stations"]:
		var grid_pos = Vector2(station_data["grid_pos"][0], station_data["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)

		# Create placeholder station node (replaced with proper scene in Task 5)
		var node = Node2D.new()
		node.name = station_data["id"]
		node.position = screen_pos

		# Add a label so we can see stations in the vertical slice
		var label = Label.new()
		label.text = station_data["label"]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(-40, -30)
		var label_settings = LabelSettings.new()
		label_settings.font_size = 12
		label_settings.font_color = Color.WHITE
		label_settings.outline_size = 2
		label_settings.outline_color = Color.BLACK
		label.label_settings = label_settings
		node.add_child(label)

		# Add a colored circle as placeholder sprite
		var sprite = _create_placeholder_sprite(station_data["type"])
		node.add_child(sprite)

		add_child(node)
		station_nodes[station_data["id"]] = node


func _create_placeholder_sprite(station_type: String) -> Node2D:
	var draw_node = ColorRect.new()
	var type_info = station_types.get(station_type, {})
	var color_hex = type_info.get("color", "#888888")
	draw_node.color = Color.html(color_hex)
	draw_node.size = Vector2(48, 32)
	draw_node.position = Vector2(-24, -16)
	return draw_node


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("File not found: %s" % path)
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	var text = file.get_as_text()
	file.close()
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_error("JSON parse error in %s: %s" % [path, json.get_error_message()])
		return {}
	return json.data
```

- [ ] **Step 4: Commit**

```bash
git add godot-mission-control/data/ godot-mission-control/scripts/world/world_builder.gd
git commit -m "feat(mc): data-driven world builder with layout JSON

Reads office_layout.json to spawn stations at isometric positions
and build NavGraph for agent pathfinding."
```

---

### Task 4: Main Scene & Isometric Camera

**Files:**
- Create: `godot-mission-control/scenes/main.tscn` (built in Godot editor or via script)
- Create: `godot-mission-control/scripts/world/iso_camera.gd`

- [ ] **Step 1: Create isometric camera controller**

Create `godot-mission-control/scripts/world/iso_camera.gd`:

```gdscript
extends Camera2D
## Isometric camera with pan, zoom, and focus controls.

@export var zoom_min: float = 0.3
@export var zoom_max: float = 3.0
@export var zoom_step: float = 0.1
@export var pan_speed: float = 400.0
@export var ease_speed: float = 5.0

var _target_position: Vector2 = Vector2.ZERO
var _target_zoom: Vector2 = Vector2.ONE
var _is_panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _follow_target: Node2D = null


func _ready() -> void:
	_target_position = global_position
	_target_zoom = zoom
	EventBus.camera_focus_requested.connect(_on_focus_requested)
	EventBus.camera_reset_requested.connect(_on_reset_requested)
	EventBus.camera_follow_stopped.connect(_on_follow_stopped)


func _process(delta: float) -> void:
	# WASD panning
	var pan_input = Vector2.ZERO
	if Input.is_action_pressed("ui_left"):
		pan_input.x -= 1
	if Input.is_action_pressed("ui_right"):
		pan_input.x += 1
	if Input.is_action_pressed("ui_up"):
		pan_input.y -= 1
	if Input.is_action_pressed("ui_down"):
		pan_input.y += 1
	if pan_input != Vector2.ZERO:
		_follow_target = null
		_target_position += pan_input * pan_speed * delta / zoom.x

	# Follow target
	if _follow_target and is_instance_valid(_follow_target):
		_target_position = _follow_target.global_position

	# Smooth movement
	global_position = global_position.lerp(_target_position, ease_speed * delta)
	zoom = zoom.lerp(_target_zoom, ease_speed * delta)


func _unhandled_input(event: InputEvent) -> void:
	# Middle mouse pan
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_pan_start = event.position

		# Scroll zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_zoom = (_target_zoom + Vector2.ONE * zoom_step).clampf(zoom_min, zoom_max)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_zoom = (_target_zoom - Vector2.ONE * zoom_step).clampf(zoom_min, zoom_max)

	if event is InputEventMouseMotion and _is_panning:
		_follow_target = null
		_target_position -= event.relative / zoom.x

	# Home key reset
	if event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		_on_reset_requested()


func focus_on(world_pos: Vector2) -> void:
	_follow_target = null
	_target_position = world_pos


func follow(node: Node2D) -> void:
	_follow_target = node


func _on_focus_requested(world_pos: Vector2) -> void:
	focus_on(world_pos)


func _on_reset_requested() -> void:
	_follow_target = null
	_target_position = Vector2.ZERO
	_target_zoom = Vector2.ONE


func _on_follow_stopped() -> void:
	_follow_target = null
```

- [ ] **Step 2: Create main.tscn programmatically**

Since we can't use the Godot editor from the CLI, we'll create a minimal scene file. Following the Godot isometric demo pattern, the world node uses **y_sort_enabled** for proper depth ordering (entities further down the screen render on top).

Create `godot-mission-control/scenes/main.tscn`:

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/world/world_builder.gd" id="1"]
[ext_resource type="Script" path="res://scripts/world/iso_camera.gd" id="2"]

[node name="Main" type="Node2D"]

[node name="Floor" type="TileMapLayer" parent="."]
tile_set = null

[node name="WorldBuilder" type="Node2D" parent="."]
y_sort_enabled = true
script = ExtResource("1")

[node name="Camera" type="Camera2D" parent="."]
script = ExtResource("2")
zoom = Vector2(1, 1)

[node name="UILayer" type="CanvasLayer" parent="."]
layer = 10
```

**Note:** The Floor TileMapLayer starts with `tile_set = null` — it will be configured in the editor with an isometric tileset (128x64 tiles). The WorldBuilder node has `y_sort_enabled = true` so stations and agents are depth-sorted by their Y position, just like the isometric demo's wall layer.

- [ ] **Step 3: Open in Godot, verify stations appear at isometric positions**

Open the project in Godot editor. You should see colored rectangles with labels at isometric positions representing the 8 stations. The camera should be pannable with middle-mouse, zoomable with scroll, and WASD-movable.

- [ ] **Step 4: Commit**

```bash
git add godot-mission-control/scenes/main.tscn godot-mission-control/scripts/world/iso_camera.gd
git commit -m "feat(mc): main scene with isometric camera and world builder

Pan (middle mouse/WASD), zoom (scroll), focus, and follow.
Stations appear as colored placeholders at isometric positions."
```

---

### Task 5: Station Scene (Placeholder Sprites)

**Files:**
- Create: `godot-mission-control/scenes/stations/station.tscn`
- Create: `godot-mission-control/scripts/stations/station_controller.gd`

- [ ] **Step 1: Create station controller**

Create `godot-mission-control/scripts/stations/station_controller.gd`:

```gdscript
extends Node2D
## Generic station that configures itself based on station_id.
## Subscribes to WorldState for state changes.

@export var station_id: String = ""

var station_type: String = ""
var station_label: String = ""
var queue_depth: int = 0
var capacity: int = 1
var state: String = "idle"

@onready var label_node: Label = $Label
@onready var sprite_node: ColorRect = $Sprite
@onready var queue_label: Label = $QueueLabel
@onready var click_area: Area2D = $ClickArea


func setup(id: String, type: String, lbl: String, cap: int, color: Color) -> void:
	station_id = id
	station_type = type
	station_label = lbl
	capacity = cap

	if label_node:
		label_node.text = lbl
	if sprite_node:
		sprite_node.color = color


func _ready() -> void:
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)


func _on_station_changed(changed_id: String) -> void:
	if changed_id != station_id:
		return
	var data = WorldState.stations.get(station_id, {})
	_update_from_data(data)


func _on_snapshot_loaded() -> void:
	var data = WorldState.stations.get(station_id, {})
	if not data.is_empty():
		_update_from_data(data)


func _update_from_data(data: Dictionary) -> void:
	state = data.get("state", "idle")
	queue_depth = data.get("queueDepth", 0)

	# Update queue label
	if queue_label:
		queue_label.text = str(queue_depth) if queue_depth > 0 else ""

	# Saturation color feedback
	if sprite_node:
		var saturation_ratio = float(queue_depth) / max(capacity, 1)
		if saturation_ratio > 0.8:
			sprite_node.color = Color.html("#e74c3c")  # red
		elif saturation_ratio > 0.5:
			sprite_node.color = Color.html("#f5b041")  # yellow
		# else keep original color


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		EventBus.entity_selected.emit("station", station_id)
		EventBus.camera_focus_requested.emit(global_position)
```

- [ ] **Step 2: Create station.tscn**

Create `godot-mission-control/scenes/stations/station.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/stations/station_controller.gd" id="1"]

[node name="Station" type="Node2D"]
script = ExtResource("1")

[node name="Sprite" type="ColorRect" parent="."]
offset_left = -30.0
offset_top = -20.0
offset_right = 30.0
offset_bottom = 20.0
color = Color(0.6, 0.6, 0.6, 1)

[node name="Label" type="Label" parent="."]
offset_left = -40.0
offset_top = -35.0
offset_right = 40.0
offset_bottom = -20.0
horizontal_alignment = 1
text = "Station"

[node name="QueueLabel" type="Label" parent="."]
offset_left = 20.0
offset_top = -20.0
offset_right = 40.0
offset_bottom = -5.0
horizontal_alignment = 1
text = ""

[sub_resource type="RectangleShape2D" id="RectangleShape2D_placeholder"]
size = Vector2(60, 40)

[node name="ClickArea" type="Area2D" parent="."]

[node name="CollisionShape2D" type="CollisionShape2D" parent="ClickArea"]
shape = SubResource("RectangleShape2D_placeholder")
```

- [ ] **Step 3: Update WorldBuilder to use station scene**

Update `godot-mission-control/scripts/world/world_builder.gd` — replace the `_spawn_stations` method to load the station scene instead of creating placeholder nodes. Replace the body of `_spawn_stations`:

```gdscript
func _spawn_stations(layout: Dictionary) -> void:
	var station_scn = load("res://scenes/stations/station.tscn")
	for station_data in layout["stations"]:
		var grid_pos = Vector2(station_data["grid_pos"][0], station_data["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)

		var node = station_scn.instantiate()
		node.position = screen_pos

		var type_info = station_types.get(station_data["type"], {})
		var color = Color.html(type_info.get("color", "#888888"))
		node.setup(
			station_data["id"],
			station_data["type"],
			station_data["label"],
			station_data["capacity"],
			color
		)

		add_child(node)
		station_nodes[station_data["id"]] = node
```

Also remove `_create_placeholder_sprite` — it's no longer needed.

- [ ] **Step 4: Verify in Godot — stations show labels, queue counts update**

- [ ] **Step 5: Commit**

```bash
git add godot-mission-control/scenes/stations/ godot-mission-control/scripts/stations/
git commit -m "feat(mc): station scene with controller and click selection

Stations subscribe to WorldState, show queue depth, and change
color based on saturation. Click to select and focus camera."
```

---

### Task 6: Blob Agent Scene (CharacterBody2D + 8-Dir Movement)

**Note:** Following the [Godot isometric demo](https://github.com/godotengine/godot-demo-projects/tree/master/2d/isometric), agents are **CharacterBody2D** nodes using `move_and_slide()` for collision-aware movement. The isometric aspect ratio is compensated by halving the Y component of velocity (just like the demo's goblin). Animation direction is derived from velocity angle divided into 8 slices.

**Files:**
- Create: `godot-mission-control/scenes/agents/blob_agent.tscn`
- Create: `godot-mission-control/scripts/agents/agent_mover.gd`
- Create: `godot-mission-control/scripts/agents/agent_animator.gd`
- Create: `godot-mission-control/scripts/agents/agent_controller.gd`

- [ ] **Step 1: Create agent_mover.gd**

Create `godot-mission-control/scripts/agents/agent_mover.gd`:

```gdscript
extends Node
## Moves the parent CharacterBody2D along a list of waypoint positions.
## Uses move_and_slide() for collision-aware movement (like the Godot isometric demo).
## Emits arrived signal when the final waypoint is reached.
## Exposes velocity_direction for 8-directional animation.

signal arrived()

@export var base_speed: float = 160.0  # Same as Godot iso demo

var _path: Array = []  # Array of Vector2 screen positions
var _current_waypoint_index: int = 0
var _moving: bool = false
var speed_multiplier: float = 1.0
var velocity_direction: Vector2 = Vector2.ZERO  # For animator to read

var _body: CharacterBody2D


func _ready() -> void:
	_body = get_parent() as CharacterBody2D


func start_path(waypoints: Array) -> void:
	if waypoints.is_empty():
		arrived.emit()
		return
	_path = waypoints
	_current_waypoint_index = 0
	_moving = true


func stop() -> void:
	_moving = false
	_path.clear()
	velocity_direction = Vector2.ZERO
	if _body:
		_body.velocity = Vector2.ZERO


func is_moving() -> bool:
	return _moving


func _physics_process(delta: float) -> void:
	if not _body or not _moving or _path.is_empty():
		if _body:
			_body.velocity = Vector2.ZERO
			velocity_direction = Vector2.ZERO
		return

	var target = _path[_current_waypoint_index]
	var direction = target - _body.position
	var distance = direction.length()

	if distance < 5.0:
		_body.position = target
		_current_waypoint_index += 1
		if _current_waypoint_index >= _path.size():
			_moving = false
			_path.clear()
			_body.velocity = Vector2.ZERO
			velocity_direction = Vector2.ZERO
			arrived.emit()
		return

	# Compute velocity — halve Y for isometric compensation (like goblin.gd)
	var motion = direction.normalized()
	velocity_direction = motion  # Raw direction for animation
	motion.y /= 2.0  # Isometric aspect ratio compensation
	motion = motion.normalized() * base_speed * speed_multiplier

	_body.velocity = motion
	_body.move_and_slide()
```

- [ ] **Step 2: Create agent_animator.gd**

Create `godot-mission-control/scripts/agents/agent_animator.gd`:

```gdscript
extends Node
## Handles blob charm: 8-directional wobble walk, squash/stretch, idle bob, emotes.
## Reads velocity_direction from sibling AgentMover to determine facing.
## Inspired by Godot isometric demo's 8-directional animation system.

@export var wobble_amplitude: float = 3.0
@export var wobble_speed: float = 8.0
@export var bob_amplitude: float = 2.0
@export var bob_speed: float = 2.0
@export var squash_duration: float = 0.15

var _time: float = 0.0
var _is_walking: bool = false
var _squash_timer: float = 0.0
var _squash_type: String = ""  # "squash" or "stretch"
var _facing_direction: int = 0  # 0-7, like goblin.gd (S, SW, W, NW, N, NE, E, SE)

var body_sprite: Node2D  # Set by agent controller
var shadow_sprite: Node2D
var eyes_sprite: Node2D
var mover: Node = null  # AgentMover reference, set by controller

# Idle fidget
var _fidget_timer: float = 0.0
var _fidget_interval: float = 5.0  # randomized


func _ready() -> void:
	_fidget_interval = randf_range(3.0, 8.0)


func set_walking(walking: bool) -> void:
	_is_walking = walking


func play_squash() -> void:
	_squash_timer = squash_duration
	_squash_type = "squash"


func play_stretch() -> void:
	_squash_timer = squash_duration
	_squash_type = "stretch"


func _process(delta: float) -> void:
	_time += delta

	if not body_sprite:
		return

	# Update facing direction from mover velocity (8-directional, like goblin.gd)
	if mover and mover.velocity_direction.length() > 0.1:
		var angle = mover.velocity_direction.angle()
		# Divide into 8 slices of 45 degrees each, offset by 22.5 degrees
		_facing_direction = int(round(angle / (PI / 4))) % 8
		if _facing_direction < 0:
			_facing_direction += 8

	# Update eye positions based on facing direction (simulate looking)
	_update_eye_direction()

	var offset_y = 0.0
	var rotation_z = 0.0
	var scale_mod = Vector2.ONE

	if _is_walking:
		# Wobble walk: sinusoidal rotation + vertical bounce
		rotation_z = sin(_time * wobble_speed) * deg_to_rad(wobble_amplitude)
		offset_y = -abs(sin(_time * wobble_speed * 0.5)) * 4.0
	else:
		# Idle bob
		offset_y = sin(_time * bob_speed) * bob_amplitude
		_update_fidget(delta)

	# Squash/stretch
	if _squash_timer > 0:
		_squash_timer -= delta
		var t = _squash_timer / squash_duration
		if _squash_type == "squash":
			scale_mod = Vector2(1.0 + 0.2 * t, 1.0 - 0.15 * t)
		else:
			scale_mod = Vector2(1.0 - 0.1 * t, 1.0 + 0.2 * t)

	body_sprite.rotation = rotation_z
	body_sprite.position.y = offset_y
	body_sprite.scale = scale_mod


func _update_eye_direction() -> void:
	if not eyes_sprite:
		return
	# Shift eyes in the direction the blob is facing
	# 8 directions: S=0, SW=1, W=2, NW=3, N=4, NE=5, E=6, SE=7
	var offsets = [
		Vector2(0, 1),    # S
		Vector2(-1, 1),   # SW
		Vector2(-1, 0),   # W
		Vector2(-1, -1),  # NW
		Vector2(0, -1),   # N
		Vector2(1, -1),   # NE
		Vector2(1, 0),    # E
		Vector2(1, 1),    # SE
	]
	var offset = offsets[_facing_direction] * 1.5
	eyes_sprite.position = offset


func _update_fidget(delta: float) -> void:
	_fidget_timer -= delta
	if _fidget_timer <= 0:
		_fidget_timer = randf_range(3.0, 8.0)
		# Tiny hop
		play_squash()
```

- [ ] **Step 3: Create agent_controller.gd (FSM)**

Create `godot-mission-control/scripts/agents/agent_controller.gd`:

```gdscript
extends CharacterBody2D
## Agent FSM brain. Subscribes to WorldState signals and drives mover/animator.
## Extends CharacterBody2D for move_and_slide() collision support.

enum State { IDLE, MOVING, PICKING_UP, CARRYING, WORKING, DELIVERING, BLOCKED, ERRORED, OFFLINE }

@export var worker_id: String = ""
@export var agent_color: Color = Color.html("#d4836b")  # Claude terracotta

var current_state: State = State.IDLE
var current_job_id: String = ""
var target_station_id: String = ""
var role: String = ""

@onready var mover: Node = $AgentMover
@onready var animator: Node = $AgentAnimator
@onready var body: Node2D = $Body
@onready var eyes: Node2D = $Body/Eyes
@onready var label_node: Label = $Label
@onready var job_packet_visual: Node2D = $Body/JobPacket
@onready var click_area: Area2D = $ClickArea

var _nav_graph: NavGraph
var _pickup_timer: float = 0.0
var _pickup_duration: float = 0.5


func setup(id: String, nav: NavGraph, color: Color) -> void:
	worker_id = id
	_nav_graph = nav
	agent_color = color
	if body and body.has_method("set_color"):
		body.set_color(color)


func _ready() -> void:
	# Wire animator
	if animator:
		animator.body_sprite = body
		animator.eyes_sprite = eyes
		animator.mover = mover

	# Wire mover
	if mover:
		mover.arrived.connect(_on_arrived)

	# Subscribe to WorldState
	WorldState.job_assigned.connect(_on_job_assigned)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.job_handoff.connect(_on_job_handoff)
	WorldState.agent_changed.connect(_on_agent_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)

	# Hide job packet initially
	if job_packet_visual:
		job_packet_visual.visible = false

	_set_state(State.IDLE)


func _process(delta: float) -> void:
	# Pickup animation timer
	if current_state == State.PICKING_UP:
		_pickup_timer -= delta
		if _pickup_timer <= 0:
			_transition_to_carrying()

	# Update label
	if label_node:
		label_node.text = worker_id.left(8)


func _set_state(new_state: State) -> void:
	current_state = new_state
	if animator:
		animator.set_walking(new_state in [State.MOVING, State.CARRYING, State.DELIVERING])
	if job_packet_visual:
		job_packet_visual.visible = new_state in [State.CARRYING, State.DELIVERING, State.PICKING_UP]


# --- Signal handlers ---

func _on_job_assigned(job_id: String, agent_id: String, station_id: String) -> void:
	# Find which worker this agent represents
	if not _is_my_agent(agent_id):
		return
	current_job_id = job_id
	target_station_id = station_id
	# Move to the station where the job is
	_move_to_station(station_id)
	_set_state(State.MOVING)


func _on_job_completed(job_id: String) -> void:
	if job_id != current_job_id:
		return
	# Deliver to output dock
	target_station_id = "output_dock"
	_move_to_station("output_dock")
	_set_state(State.DELIVERING)
	if animator:
		animator.play_stretch()


func _on_job_failed(job_id: String, _reason: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = "error_chamber"
	_move_to_station("error_chamber")
	_set_state(State.ERRORED)


func _on_job_handoff(job_id: String, _from: String, to_station_id: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = to_station_id
	_move_to_station(to_station_id)
	_set_state(State.CARRYING)


func _on_agent_changed(agent_id: String) -> void:
	if not _is_my_agent(agent_id):
		return
	var agent_data = WorldState.agents.get(agent_id, {})
	var backend_state = agent_data.get("state", "")
	match backend_state:
		"blocked":
			_set_state(State.BLOCKED)
			if mover:
				mover.stop()
		"offline":
			_set_state(State.OFFLINE)
			if mover:
				mover.stop()


func _on_snapshot_loaded() -> void:
	# Find our agent data and sync state
	for agent_id in WorldState.agents:
		if _is_my_agent(agent_id):
			var data = WorldState.agents[agent_id]
			role = data.get("role", "")
			var job_id = data.get("currentJobId", "")
			if job_id != "":
				current_job_id = job_id
				# If agent has a job and station, go to working state
				var station = data.get("currentStationId", "")
				if station != "":
					_move_to_station(station)
					_set_state(State.CARRYING)
			break


func _on_arrived() -> void:
	match current_state:
		State.MOVING:
			# Arrived at pickup location
			_set_state(State.PICKING_UP)
			_pickup_timer = _pickup_duration
			if animator:
				animator.play_squash()
		State.CARRYING:
			# Arrived at work station
			_set_state(State.WORKING)
			if animator:
				animator.play_squash()
		State.DELIVERING:
			# Delivered job, go idle
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)
			if animator:
				animator.play_stretch()
		State.ERRORED:
			# Dropped off at error chamber
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)


func _transition_to_carrying() -> void:
	# After pickup, find the job's target station and carry there
	var job_data = WorldState.jobs.get(current_job_id, {})
	var target = job_data.get("currentStationId", "")
	if target == "" or target == target_station_id:
		# Job might need to go to dispatcher first
		target = "dispatcher"
	target_station_id = target
	_move_to_station(target)
	_set_state(State.CARRYING)
	if animator:
		animator.play_stretch()


func _move_to_station(station_id: String) -> void:
	if not _nav_graph:
		return
	# Find closest station to current position to use as path start
	var from_id = _find_nearest_station_id()
	var path = _nav_graph.find_path(from_id, station_id)
	if path.is_empty():
		# Fallback: move directly
		var target_pos = _nav_graph.get_position(station_id)
		if target_pos != Vector2.ZERO:
			path = [target_pos]
	if mover and not path.is_empty():
		mover.start_path(path)


func _find_nearest_station_id() -> String:
	var best_id = ""
	var best_dist = INF
	# Check all nav graph nodes
	for station_id in WorldState.stations:
		var pos = _nav_graph.get_position(station_id)
		if pos == Vector2.ZERO:
			continue
		var dist = position.distance_to(pos)
		if dist < best_dist:
			best_dist = dist
			best_id = station_id
	# Also check waypoints (they might be closer)
	return best_id if best_id != "" else "intake"


func _is_my_agent(agent_id: String) -> bool:
	# Match agent to this worker node.
	# The backend uses agent IDs that correspond to worker IDs.
	# Check if the agent's worker matches our worker_id.
	var agent_data = WorldState.agents.get(agent_id, {})
	var agent_worker = agent_data.get("workerId", agent_id)
	return agent_worker == worker_id or agent_id == worker_id


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		EventBus.entity_selected.emit("agent", worker_id)
		EventBus.camera_focus_requested.emit(global_position)
```

- [ ] **Step 4: Create blob_agent.tscn**

Note: The root node is **CharacterBody2D** (not Node2D) following the Godot isometric demo pattern. This enables `move_and_slide()` collision-aware movement. A CapsuleShape2D collision shape (like the demo's goblin) is used for physics.

Create `godot-mission-control/scenes/agents/blob_agent.tscn`:

```
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/agents/agent_controller.gd" id="1"]
[ext_resource type="Script" path="res://scripts/agents/agent_mover.gd" id="2"]
[ext_resource type="Script" path="res://scripts/agents/agent_animator.gd" id="3"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_1"]
size = Vector2(30, 20)

[sub_resource type="CapsuleShape2D" id="CapsuleShape2D_1"]
radius = 7.0
height = 14.0

[node name="BlobAgent" type="CharacterBody2D"]
script = ExtResource("1")

[node name="AgentMover" type="Node" parent="."]
script = ExtResource("2")

[node name="AgentAnimator" type="Node" parent="."]
script = ExtResource("3")

[node name="Body" type="Node2D" parent="."]

[node name="Shadow" type="ColorRect" parent="Body"]
offset_left = -12.0
offset_top = 4.0
offset_right = 12.0
offset_bottom = 8.0
color = Color(0, 0, 0, 0.2)

[node name="BlobBody" type="ColorRect" parent="Body"]
offset_left = -14.0
offset_top = -10.0
offset_right = 14.0
offset_bottom = 8.0
color = Color(0.831, 0.514, 0.42, 1)

[node name="Eyes" type="Node2D" parent="Body"]

[node name="LeftEye" type="ColorRect" parent="Body/Eyes"]
offset_left = -7.0
offset_top = -5.0
offset_right = -2.0
offset_bottom = 1.0
color = Color(1, 1, 1, 1)

[node name="LeftPupil" type="ColorRect" parent="Body/Eyes/LeftEye"]
offset_left = 1.0
offset_top = 1.5
offset_right = 4.0
offset_bottom = 4.5
color = Color(0.1, 0.1, 0.1, 1)

[node name="RightEye" type="ColorRect" parent="Body/Eyes"]
offset_left = 2.0
offset_top = -5.0
offset_right = 7.0
offset_bottom = 1.0
color = Color(1, 1, 1, 1)

[node name="RightPupil" type="ColorRect" parent="Body/Eyes/RightEye"]
offset_left = 1.0
offset_top = 1.5
offset_right = 4.0
offset_bottom = 4.5
color = Color(0.1, 0.1, 0.1, 1)

[node name="JobPacket" type="ColorRect" parent="Body"]
visible = false
offset_left = -6.0
offset_top = -20.0
offset_right = 6.0
offset_bottom = -14.0
color = Color(0.35, 0.6, 0.85, 1)

[node name="Label" type="Label" parent="."]
offset_left = -30.0
offset_top = 10.0
offset_right = 30.0
offset_bottom = 25.0
horizontal_alignment = 1

[node name="PhysicsCollision" type="CollisionShape2D" parent="."]
shape = SubResource("CapsuleShape2D_1")
position = Vector2(0, -7)

[node name="ClickArea" type="Area2D" parent="."]

[node name="CollisionShape2D" type="CollisionShape2D" parent="ClickArea"]
shape = SubResource("RectangleShape2D_1")
```

- [ ] **Step 5: Add agent spawning to WorldBuilder**

Add to `godot-mission-control/scripts/world/world_builder.gd`:

```gdscript
var agent_nodes: Dictionary = {}  # worker_id → BlobAgent node

func _ready() -> void:
	# ... existing code ...
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)


func _on_snapshot_loaded() -> void:
	# Spawn agents for all workers in snapshot
	for worker_id in WorldState.workers:
		_spawn_agent(worker_id)


func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new:
		_spawn_agent(worker_id)


func _on_worker_removed(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		agent_nodes[worker_id].queue_free()
		agent_nodes.erase(worker_id)


func _spawn_agent(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		return
	var agent_scn = load("res://scenes/agents/blob_agent.tscn")
	var agent = agent_scn.instantiate()

	# Assign a Claude-palette color based on worker ID hash
	var colors = [
		Color.html("#d4836b"),  # terracotta
		Color.html("#e8a87c"),  # warm orange
		Color.html("#f0c8a0"),  # soft peach
		Color.html("#c97b7b"),  # dusty rose
		Color.html("#d4a574"),  # sandy
		Color.html("#b07d62"),  # deep clay
	]
	var color_index = worker_id.hash() % colors.size()
	agent.setup(worker_id, nav, colors[color_index])

	# Start at intake station
	var start_pos = nav.get_position("intake")
	agent.position = start_pos

	add_child(agent)
	agent_nodes[worker_id] = agent
```

- [ ] **Step 6: Verify in Godot — connect to backend, see blobs appear and move**

Start the Laddr backend, open the Godot project, and verify:
1. Blobs spawn when workers register
2. Blobs wobble-walk between stations when jobs are assigned
3. Job packets appear above blob heads when carrying

- [ ] **Step 7: Commit**

```bash
git add godot-mission-control/scenes/agents/ godot-mission-control/scripts/agents/ godot-mission-control/scripts/world/world_builder.gd
git commit -m "feat(mc): blob agent with FSM, wobble walk, and job carrying

Agent controller subscribes to WorldState signals and drives
mover + animator. Blobs spawn from worker_registered events."
```

---

### Task 7: Basic HUD (Connection Status + Metrics)

**Files:**
- Create: `godot-mission-control/scenes/ui/hud.tscn`
- Create: `godot-mission-control/scripts/ui/hud_controller.gd`

- [ ] **Step 1: Create HUD controller**

Create `godot-mission-control/scripts/ui/hud_controller.gd`:

```gdscript
extends Control
## Top bar HUD showing connection status and live metrics.

@onready var connection_dot: ColorRect = $HBoxContainer/ConnectionDot
@onready var connection_label: Label = $HBoxContainer/ConnectionLabel
@onready var metrics_label: Label = $HBoxContainer/MetricsLabel


func _ready() -> void:
	WebSocketClient.connection_state_changed.connect(_on_connection_state_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	_on_connection_state_changed(WebSocketClient.connection_state)


func _on_connection_state_changed(state: String) -> void:
	if connection_label:
		connection_label.text = state.capitalize()
	if connection_dot:
		match state:
			"connected":
				connection_dot.color = Color.GREEN
			"connecting":
				connection_dot.color = Color.YELLOW
			"disconnected":
				connection_dot.color = Color.RED


func _on_metrics_changed() -> void:
	_update_metrics()


func _on_snapshot_loaded() -> void:
	_update_metrics()


func _update_metrics() -> void:
	if not metrics_label:
		return
	var m = WorldState.metrics
	var total_jobs = m.get("totalJobs", WorldState.jobs.size())
	var active_agents = m.get("activeAgents", WorldState.agents.size())
	var errors = m.get("errorCount", 0)
	var queue_depth = m.get("totalQueueDepth", 0)
	metrics_label.text = "Jobs: %d | Agents: %d | Queue: %d | Errors: %d" % [
		total_jobs, active_agents, queue_depth, errors
	]
```

- [ ] **Step 2: Create hud.tscn**

Create `godot-mission-control/scenes/ui/hud.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/hud_controller.gd" id="1"]

[node name="HUD" type="Control"]
layout_mode = 1
anchors_preset = 10
anchor_right = 1.0
offset_bottom = 40.0
script = ExtResource("1")

[node name="Background" type="ColorRect" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
color = Color(0.1, 0.1, 0.12, 0.85)

[node name="HBoxContainer" type="HBoxContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
offset_left = 12.0
offset_right = -12.0

[node name="ConnectionDot" type="ColorRect" parent="HBoxContainer"]
custom_minimum_size = Vector2(12, 12)
layout_mode = 2
size_flags_vertical = 4
color = Color(1, 0, 0, 1)

[node name="ConnectionLabel" type="Label" parent="HBoxContainer"]
layout_mode = 2
size_flags_vertical = 4
text = "Disconnected"

[node name="Spacer" type="Control" parent="HBoxContainer"]
layout_mode = 2
size_flags_horizontal = 3

[node name="MetricsLabel" type="Label" parent="HBoxContainer"]
layout_mode = 2
size_flags_vertical = 4
text = "Jobs: 0 | Agents: 0 | Queue: 0 | Errors: 0"
```

- [ ] **Step 3: Add HUD to main scene**

Update `godot-mission-control/scenes/main.tscn` — add the HUD as a child of UILayer:

Add under the `[node name="UILayer"]` node:
```
[node name="HUD" parent="UILayer" instance=ExtResource("hud_scene")]
```

(The exact .tscn edit: add an ext_resource for hud.tscn and instance it under UILayer.)

- [ ] **Step 4: Verify — HUD shows connection status, metrics update on snapshot**

- [ ] **Step 5: Commit**

```bash
git add godot-mission-control/scenes/ui/hud.tscn godot-mission-control/scripts/ui/hud_controller.gd godot-mission-control/scenes/main.tscn
git commit -m "feat(mc): HUD with connection status and live metrics

Shows connected/disconnected state and job/agent/queue/error counts
from the WebSocket event stream."
```

---

**Phase 1 checkpoint: At this point the vertical slice should work end-to-end.** Open Godot, run the project with the Laddr backend running. You should see:
- Isometric office with 8 colored station placeholders
- Blob agents spawning when workers register
- Blobs wobble-walking between stations as jobs flow
- Job packets appearing above blob heads
- HUD showing connection status and metrics
- Camera pan/zoom/WASD controls

---

## Phase 2: Full Pipeline

---

### Task 8: Station Visual Upgrades (All 8 Types)

**Files:**
- Create: `godot-mission-control/scripts/stations/station_effects.gd`
- Modify: `godot-mission-control/scripts/stations/station_controller.gd`
- Modify: `godot-mission-control/scenes/stations/station.tscn`

- [ ] **Step 1: Create station_effects.gd**

Create `godot-mission-control/scripts/stations/station_effects.gd`:

```gdscript
extends Node
## Drives station-specific animations based on type and state.
## Attached as a child of station_controller.

var station_type: String = ""
var station_state: String = "idle"
var queue_depth: int = 0
var capacity: int = 1

var _time: float = 0.0
var _parent: Node2D


func _ready() -> void:
	_parent = get_parent()


func setup(type: String, cap: int) -> void:
	station_type = type
	capacity = cap


func update_state(new_state: String, new_queue_depth: int) -> void:
	station_state = new_state
	queue_depth = new_queue_depth


func _process(delta: float) -> void:
	_time += delta
	if not _parent:
		return

	var saturation = float(queue_depth) / max(capacity, 1)

	match station_type:
		"intake":
			_animate_intake(saturation)
		"router":
			_animate_router(saturation)
		"research":
			_animate_research(saturation)
		"code":
			_animate_code(saturation)
		"review":
			_animate_review(saturation)
		"output":
			_animate_output(saturation)
		"supervisor":
			_animate_supervisor(saturation)
		"error":
			_animate_error(saturation)


func _animate_intake(saturation: float) -> void:
	# Mailbox flag wobble when queue grows
	var wobble = sin(_time * 3.0) * (2.0 + saturation * 5.0)
	# Applied to a child node if it exists
	var flag = _parent.get_node_or_null("Flag")
	if flag:
		flag.rotation_degrees = wobble


func _animate_router(saturation: float) -> void:
	# Spinning tray — faster when busy
	var speed = 1.0 + saturation * 3.0
	var tray = _parent.get_node_or_null("Tray")
	if tray:
		tray.rotation += speed * 0.02


func _animate_research(saturation: float) -> void:
	# Floating books — orbit faster when busy
	var speed = 1.0 + saturation * 2.0
	var books = _parent.get_node_or_null("Books")
	if books:
		books.position = Vector2(cos(_time * speed) * 15, sin(_time * speed) * 8)


func _animate_code(saturation: float) -> void:
	# Screen flicker
	var screen = _parent.get_node_or_null("Screen")
	if screen and screen is ColorRect:
		var brightness = 0.3 + saturation * 0.5 + sin(_time * 10.0) * 0.1
		screen.color = Color(0.1, brightness, 0.2, 1.0)


func _animate_review(saturation: float) -> void:
	# Magnifying glass bob
	var glass = _parent.get_node_or_null("Glass")
	if glass:
		glass.position.y = sin(_time * 2.0) * 4.0


func _animate_output(saturation: float) -> void:
	# Conveyor belt movement
	var belt = _parent.get_node_or_null("Belt")
	if belt:
		belt.position.x = fmod(_time * 20.0, 10.0)


func _animate_supervisor(saturation: float) -> void:
	# Alert lights blink
	var alert = _parent.get_node_or_null("AlertLight")
	if alert and alert is ColorRect:
		alert.visible = saturation > 0.5 and fmod(_time, 1.0) > 0.5


func _animate_error(saturation: float) -> void:
	# Red lamp flash
	var lamp = _parent.get_node_or_null("Lamp")
	if lamp and lamp is ColorRect:
		var flash = 0.5 + sin(_time * 6.0) * 0.5
		lamp.color = Color(flash, 0, 0, 1.0)
	# Bin wobble
	if _parent:
		_parent.rotation = sin(_time * 4.0) * deg_to_rad(1.0 + saturation * 3.0)
```

- [ ] **Step 2: Update station_controller.gd to use effects**

Add to `station_controller.gd`'s `_ready()`:
```gdscript
var effects = $StationEffects  # or get_node_or_null
if effects:
    effects.setup(station_type, capacity)
```

Update `_update_from_data()` to forward to effects:
```gdscript
var effects = get_node_or_null("StationEffects")
if effects:
    effects.update_state(state, queue_depth)
```

- [ ] **Step 3: Update station.tscn to include StationEffects node**

Add a child node `StationEffects` with the `station_effects.gd` script.

- [ ] **Step 4: Verify — stations animate differently based on type and load**

- [ ] **Step 5: Commit**

```bash
git add godot-mission-control/scripts/stations/station_effects.gd godot-mission-control/scripts/stations/station_controller.gd godot-mission-control/scenes/stations/station.tscn
git commit -m "feat(mc): station-specific animations and saturation feedback

Each station type has unique animations that speed up with queue depth.
Saturation thresholds change color (green → yellow → red)."
```

---

### Task 9: Agent Role Accessories & Color Palette

**Files:**
- Modify: `godot-mission-control/scripts/agents/agent_controller.gd`
- Modify: `godot-mission-control/scripts/agents/agent_animator.gd`

- [ ] **Step 1: Add role-based visual accessories**

Update `agent_controller.gd` — add method called after snapshot loads that sets role visuals:

```gdscript
func _apply_role_visuals() -> void:
	# Add visual accessory based on role
	var accessory = ColorRect.new()
	accessory.size = Vector2(8, 4)
	accessory.position = Vector2(-4, -14)

	match role:
		"router":
			accessory.color = Color.html("#5b9bd5")  # blue visor
			accessory.size = Vector2(16, 3)
			accessory.position = Vector2(-8, -6)
		"researcher":
			accessory.color = Color.html("#85c1e9")  # glasses
			accessory.size = Vector2(12, 3)
			accessory.position = Vector2(-6, -4)
		"coder":
			accessory.color = Color.html("#333333")  # headphones
			accessory.size = Vector2(18, 3)
			accessory.position = Vector2(-9, -12)
		"reviewer":
			accessory.color = Color.html("#a8d8b9")  # clipboard
			accessory.size = Vector2(6, 8)
			accessory.position = Vector2(10, -6)
		"deployer":
			accessory.color = Color.html("#82e0aa")  # tool belt
			accessory.size = Vector2(16, 2)
			accessory.position = Vector2(-8, 4)
		"supervisor":
			accessory.color = Color.html("#f5b041")  # tiny hat
			accessory.size = Vector2(10, 4)
			accessory.position = Vector2(-5, -14)
			# Also make supervisor slightly larger
			if body:
				body.scale = Vector2(1.2, 1.2)
		_:
			accessory.queue_free()
			return

	accessory.name = "Accessory"
	if body:
		body.add_child(accessory)
```

Call `_apply_role_visuals()` at the end of `_on_snapshot_loaded()` after setting `role`.

- [ ] **Step 2: Commit**

```bash
git add godot-mission-control/scripts/agents/
git commit -m "feat(mc): agent role accessories and Claude color palette

Router blobs get blue visors, coders get headphones, supervisors
get tiny hats and are 20% larger. Colors hash from worker ID."
```

---

### Task 10: Job Packet Scene & Lifecycle Animations

**Files:**
- Create: `godot-mission-control/scenes/items/job_packet.tscn`
- Create: `godot-mission-control/scripts/items/job_packet.gd`

- [ ] **Step 1: Create job_packet.gd**

Create `godot-mission-control/scripts/items/job_packet.gd`:

```gdscript
extends Node2D
## Visual representation of a job in the world.
## Can be queued at a station, carried by an agent, or animating.

var job_id: String = ""
var priority: String = "normal"
var state: String = "queued"

@onready var body: ColorRect = $Body
@onready var priority_glow: ColorRect = $PriorityGlow

var _time: float = 0.0

const PRIORITY_COLORS = {
	"low": Color(0.5, 0.5, 0.5, 1),
	"normal": Color(0.35, 0.6, 0.85, 1),
	"high": Color(0.95, 0.6, 0.2, 1),
	"critical": Color(0.9, 0.2, 0.2, 1),
}


func setup(id: String, pri: String) -> void:
	job_id = id
	priority = pri
	_update_color()


func set_state(new_state: String) -> void:
	state = new_state
	match state:
		"completed":
			if body:
				body.color = Color.html("#82e0aa")  # green
		"failed":
			if body:
				body.color = Color.html("#e74c3c")  # red


func _update_color() -> void:
	if body:
		body.color = PRIORITY_COLORS.get(priority, PRIORITY_COLORS["normal"])


func _process(delta: float) -> void:
	_time += delta

	# Pulse effect for high/critical priority
	if priority in ["high", "critical"] and body:
		var pulse = 0.8 + sin(_time * 4.0) * 0.2
		body.self_modulate = Color(pulse, pulse, pulse, 1.0)

	# Processing spin
	if state == "processing":
		rotation = _time * 2.0
```

- [ ] **Step 2: Create job_packet.tscn**

Create `godot-mission-control/scenes/items/job_packet.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/items/job_packet.gd" id="1"]

[node name="JobPacket" type="Node2D"]
script = ExtResource("1")

[node name="PriorityGlow" type="ColorRect" parent="."]
offset_left = -8.0
offset_top = -6.0
offset_right = 8.0
offset_bottom = 6.0
color = Color(1, 1, 1, 0.15)

[node name="Body" type="ColorRect" parent="."]
offset_left = -6.0
offset_top = -4.0
offset_right = 6.0
offset_bottom = 4.0
color = Color(0.35, 0.6, 0.85, 1)
```

- [ ] **Step 3: Add job packet spawning to station_controller.gd**

Stations should show job packets in their queue visually. Add to `station_controller.gd`:

```gdscript
var _packet_nodes: Array = []
const MAX_VISIBLE_PACKETS = 5

func _update_queue_visuals() -> void:
	# Remove old packet visuals
	for pkt in _packet_nodes:
		pkt.queue_free()
	_packet_nodes.clear()

	var packet_scene = load("res://scenes/items/job_packet.tscn")
	var data = WorldState.stations.get(station_id, {})
	var active_jobs = data.get("activeJobIds", [])

	var count = mini(active_jobs.size(), MAX_VISIBLE_PACKETS)
	for i in range(count):
		var job_id = active_jobs[i]
		var job_data = WorldState.jobs.get(job_id, {})
		var pkt = packet_scene.instantiate()
		pkt.setup(job_id, job_data.get("priority", "normal"))
		pkt.position = Vector2(-20 + i * 10, 15)
		add_child(pkt)
		_packet_nodes.append(pkt)
```

Call `_update_queue_visuals()` from `_update_from_data()`.

- [ ] **Step 4: Commit**

```bash
git add godot-mission-control/scenes/items/ godot-mission-control/scripts/items/ godot-mission-control/scripts/stations/station_controller.gd
git commit -m "feat(mc): job packet visuals with priority colors and lifecycle

Packets pulse for high/critical priority. Stations show up to 5
queued packets. Completed = green, failed = red."
```

---

### Task 11: Mission Panel (Agent Roster + Queue Dashboard)

**Files:**
- Create: `godot-mission-control/scenes/ui/mission_panel.tscn`
- Create: `godot-mission-control/scripts/ui/mission_panel_controller.gd`

- [ ] **Step 1: Create mission panel controller**

Create `godot-mission-control/scripts/ui/mission_panel_controller.gd`:

```gdscript
extends Control
## Left sidebar: agent roster and station queue dashboard.

@onready var agent_list: VBoxContainer = $PanelContainer/VBox/AgentList
@onready var station_list: VBoxContainer = $PanelContainer/VBox/StationList
@onready var toggle_button: Button = $ToggleButton

var _collapsed: bool = false
var _agent_rows: Dictionary = {}  # worker_id → HBoxContainer
var _station_rows: Dictionary = {}  # station_id → HBoxContainer


func _ready() -> void:
	WorldState.snapshot_loaded.connect(_rebuild_all)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.agent_changed.connect(_on_agent_changed)
	WorldState.station_changed.connect(_on_station_changed)
	if toggle_button:
		toggle_button.pressed.connect(_toggle_collapse)


func _toggle_collapse() -> void:
	_collapsed = not _collapsed
	$PanelContainer.visible = not _collapsed
	if toggle_button:
		toggle_button.text = ">" if _collapsed else "<"


func _rebuild_all() -> void:
	_clear_lists()
	for worker_id in WorldState.workers:
		_add_agent_row(worker_id)
	for station_id in WorldState.stations:
		_add_station_row(station_id)


func _clear_lists() -> void:
	for child in agent_list.get_children():
		child.queue_free()
	_agent_rows.clear()
	for child in station_list.get_children():
		child.queue_free()
	_station_rows.clear()


func _add_agent_row(worker_id: String) -> void:
	var row = HBoxContainer.new()
	row.name = worker_id

	# Color swatch
	var swatch = ColorRect.new()
	swatch.custom_minimum_size = Vector2(12, 12)
	var colors = [Color.html("#d4836b"), Color.html("#e8a87c"), Color.html("#f0c8a0"),
		Color.html("#c97b7b"), Color.html("#d4a574"), Color.html("#b07d62")]
	swatch.color = colors[worker_id.hash() % colors.size()]
	row.add_child(swatch)

	# Name label
	var name_label = Label.new()
	name_label.text = worker_id.left(12)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# State label
	var state_label = Label.new()
	state_label.name = "StateLabel"
	state_label.text = "idle"
	row.add_child(state_label)

	# Click to select
	var btn = Button.new()
	btn.text = ">"
	btn.flat = true
	btn.pressed.connect(func(): EventBus.entity_selected.emit("agent", worker_id))
	row.add_child(btn)

	agent_list.add_child(row)
	_agent_rows[worker_id] = row


func _add_station_row(station_id: String) -> void:
	var row = HBoxContainer.new()
	row.name = station_id

	var data = WorldState.stations.get(station_id, {})

	# Station name
	var name_label = Label.new()
	name_label.text = data.get("label", station_id).left(14)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# Queue depth bar
	var bar = ProgressBar.new()
	bar.name = "QueueBar"
	bar.custom_minimum_size = Vector2(80, 14)
	bar.max_value = data.get("capacity", 1)
	bar.value = data.get("queueDepth", 0)
	bar.show_percentage = false
	row.add_child(bar)

	# Depth label
	var depth_label = Label.new()
	depth_label.name = "DepthLabel"
	depth_label.text = "%d/%d" % [data.get("queueDepth", 0), data.get("capacity", 1)]
	row.add_child(depth_label)

	station_list.add_child(row)
	_station_rows[station_id] = row


func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new and not _agent_rows.has(worker_id):
		_add_agent_row(worker_id)


func _on_worker_removed(worker_id: String) -> void:
	if _agent_rows.has(worker_id):
		_agent_rows[worker_id].queue_free()
		_agent_rows.erase(worker_id)


func _on_agent_changed(agent_id: String) -> void:
	# Find the matching worker row
	var agent_data = WorldState.agents.get(agent_id, {})
	var worker_id = agent_data.get("workerId", agent_id)
	if _agent_rows.has(worker_id):
		var row = _agent_rows[worker_id]
		var state_label = row.get_node_or_null("StateLabel")
		if state_label:
			state_label.text = agent_data.get("state", "idle")


func _on_station_changed(station_id: String) -> void:
	if not _station_rows.has(station_id):
		return
	var row = _station_rows[station_id]
	var data = WorldState.stations.get(station_id, {})

	var bar = row.get_node_or_null("QueueBar")
	if bar:
		bar.value = data.get("queueDepth", 0)

	var depth_label = row.get_node_or_null("DepthLabel")
	if depth_label:
		depth_label.text = "%d/%d" % [data.get("queueDepth", 0), data.get("capacity", 1)]
```

- [ ] **Step 2: Create mission_panel.tscn**

Create the scene file with a PanelContainer containing VBox with AgentList and StationList sections, plus a collapse toggle button. Add this under UILayer in main.tscn.

- [ ] **Step 3: Wire into main.tscn UILayer**

- [ ] **Step 4: Verify — roster updates, queue bars fill, clicking rows selects agents**

- [ ] **Step 5: Commit**

```bash
git add godot-mission-control/scenes/ui/mission_panel.tscn godot-mission-control/scripts/ui/mission_panel_controller.gd godot-mission-control/scenes/main.tscn
git commit -m "feat(mc): mission panel with agent roster and queue dashboard

Left sidebar shows all agents with state, stations with queue bars.
Click agent rows to select and focus camera. Collapsible."
```

---

### Task 12: Inspector Panel

**Files:**
- Create: `godot-mission-control/scenes/ui/inspector.tscn`
- Create: `godot-mission-control/scripts/ui/inspector_controller.gd`

- [ ] **Step 1: Create inspector controller**

Create `godot-mission-control/scripts/ui/inspector_controller.gd`:

```gdscript
extends Control
## Right-side panel that shows details of selected entity.
## Listens to EventBus for selection events.

@onready var panel: PanelContainer = $PanelContainer
@onready var title_label: Label = $PanelContainer/VBox/Title
@onready var details_label: RichTextLabel = $PanelContainer/VBox/Details

var _selected_type: String = ""
var _selected_id: String = ""


func _ready() -> void:
	panel.visible = false
	EventBus.entity_selected.connect(_on_entity_selected)
	EventBus.entity_deselected.connect(_on_entity_deselected)
	# Update on state changes
	WorldState.agent_changed.connect(func(id): _refresh_if_selected("agent", id))
	WorldState.job_changed.connect(func(id): _refresh_if_selected("job", id))
	WorldState.station_changed.connect(func(id): _refresh_if_selected("station", id))


func _on_entity_selected(entity_type: String, entity_id: String) -> void:
	_selected_type = entity_type
	_selected_id = entity_id
	panel.visible = true
	_refresh()


func _on_entity_deselected() -> void:
	_selected_type = ""
	_selected_id = ""
	panel.visible = false


func _refresh_if_selected(entity_type: String, entity_id: String) -> void:
	if entity_type == _selected_type and entity_id == _selected_id:
		_refresh()


func _refresh() -> void:
	match _selected_type:
		"agent":
			_show_agent()
		"job":
			_show_job()
		"station":
			_show_station()


func _show_agent() -> void:
	var data = WorldState.agents.get(_selected_id, {})
	if data.is_empty():
		# Try looking up by worker ID
		for aid in WorldState.agents:
			if WorldState.agents[aid].get("workerId", aid) == _selected_id:
				data = WorldState.agents[aid]
				break

	title_label.text = "Agent: %s" % _selected_id.left(12)
	var text = ""
	text += "[b]Role:[/b] %s\n" % data.get("role", "unknown")
	text += "[b]State:[/b] %s\n" % data.get("state", "unknown")
	text += "[b]Current Job:[/b] %s\n" % str(data.get("currentJobId", "none"))
	text += "[b]Efficiency:[/b] %s%%\n" % str(data.get("efficiency", "—"))
	var recent = data.get("recentJobIds", [])
	if not recent.is_empty():
		text += "[b]Recent Jobs:[/b]\n"
		for jid in recent.slice(0, 5):
			text += "  • %s\n" % jid.left(16)
	details_label.text = text


func _show_job() -> void:
	var data = WorldState.jobs.get(_selected_id, {})
	title_label.text = "Job: %s" % _selected_id.left(16)
	var text = ""
	text += "[b]Type:[/b] %s\n" % data.get("type", "unknown")
	text += "[b]Priority:[/b] %s\n" % data.get("priority", "normal")
	text += "[b]State:[/b] %s\n" % data.get("state", "unknown")
	text += "[b]Agent:[/b] %s\n" % str(data.get("assignedAgentId", "none"))
	text += "[b]Station:[/b] %s\n" % str(data.get("currentStationId", "none"))
	var history = data.get("history", [])
	if not history.is_empty():
		text += "[b]History:[/b]\n"
		for entry in history.slice(-5):
			text += "  • %s: %s\n" % [entry.get("event", ""), entry.get("at", "")]
	details_label.text = text


func _show_station() -> void:
	var data = WorldState.stations.get(_selected_id, {})
	title_label.text = "Station: %s" % data.get("label", _selected_id)
	var text = ""
	text += "[b]Type:[/b] %s\n" % data.get("type", "unknown")
	text += "[b]State:[/b] %s\n" % data.get("state", "idle")
	text += "[b]Capacity:[/b] %d\n" % data.get("capacity", 0)
	text += "[b]Queue Depth:[/b] %d\n" % data.get("queueDepth", 0)
	var active = data.get("activeJobIds", [])
	if not active.is_empty():
		text += "[b]Active Jobs:[/b]\n"
		for jid in active.slice(0, 5):
			text += "  • %s\n" % jid.left(16)
	details_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	# Click empty space to deselect
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if panel.visible and not _is_mouse_over_panel():
			# Let the click propagate — entity click handlers will re-select
			# Only deselect if nothing else catches it
			call_deferred("_check_deselect")


func _check_deselect() -> void:
	# If no entity was selected this frame, deselect
	pass  # Deselection handled by clicking empty space in main scene


func _is_mouse_over_panel() -> bool:
	var mouse = get_global_mouse_position()
	return panel.get_global_rect().has_point(mouse)
```

- [ ] **Step 2: Create inspector.tscn and wire into main.tscn**

- [ ] **Step 3: Verify — click agent/station, inspector shows details, updates live**

- [ ] **Step 4: Commit**

```bash
git add godot-mission-control/scenes/ui/inspector.tscn godot-mission-control/scripts/ui/inspector_controller.gd godot-mission-control/scenes/main.tscn
git commit -m "feat(mc): inspector panel for agents, jobs, and stations

Right-side panel shows entity details on click. Updates live
from WorldState signals. RichTextLabel with BBCode formatting."
```

---

**Phase 2 checkpoint:** All 8 stations have unique animations, multiple blob agents with role accessories, job packets with priority colors, mission panel with roster + queue bars, and inspector panel. The full job lifecycle is visualized.

---

## Phase 3: Operational Polish

---

### Task 13: Filters (Job & Agent)

**Files:**
- Create: `godot-mission-control/scripts/ui/filter_state.gd`
- Modify: `godot-mission-control/project.godot` (register FilterState as autoload)
- Modify: `godot-mission-control/scripts/ui/mission_panel_controller.gd`

- [ ] **Step 1: Create filter_state.gd and register as autoload**

Add to `project.godot` under `[autoload]`:
```ini
FilterState="*res://scripts/ui/filter_state.gd"
```

Create `godot-mission-control/scripts/ui/filter_state.gd`:

```gdscript
extends Node
## Tracks active filters for the UI. Agents and stations check this
## to determine visibility.

signal filters_changed()

var job_state_filter: String = ""       # "" means show all
var job_priority_filter: String = ""
var job_type_filter: String = ""
var agent_role_filter: String = ""
var agent_state_filter: String = ""
var station_type_filter: String = ""


func clear_all() -> void:
	job_state_filter = ""
	job_priority_filter = ""
	job_type_filter = ""
	agent_role_filter = ""
	agent_state_filter = ""
	station_type_filter = ""
	filters_changed.emit()


func set_filter(category: String, value: String) -> void:
	match category:
		"job_state": job_state_filter = value
		"job_priority": job_priority_filter = value
		"job_type": job_type_filter = value
		"agent_role": agent_role_filter = value
		"agent_state": agent_state_filter = value
		"station_type": station_type_filter = value
	filters_changed.emit()


func passes_agent_filter(agent_data: Dictionary) -> bool:
	if agent_role_filter != "" and agent_data.get("role", "") != agent_role_filter:
		return false
	if agent_state_filter != "" and agent_data.get("state", "") != agent_state_filter:
		return false
	return true


func passes_job_filter(job_data: Dictionary) -> bool:
	if job_state_filter != "" and job_data.get("state", "") != job_state_filter:
		return false
	if job_priority_filter != "" and job_data.get("priority", "") != job_priority_filter:
		return false
	if job_type_filter != "" and job_data.get("type", "") != job_type_filter:
		return false
	return true
```

- [ ] **Step 2: Add filter dropdowns to mission panel**

Add OptionButton dropdowns to the mission panel for job state, priority, agent role, and agent state. Connect their `item_selected` signals to `filter_state.set_filter()`.

- [ ] **Step 3: Apply filters to agent/station visibility**

In `world_builder.gd`, connect to `filter_state.filters_changed` and iterate agent/station nodes to set visibility based on filter results.

- [ ] **Step 4: Commit**

```bash
git add godot-mission-control/scripts/ui/filter_state.gd godot-mission-control/scripts/ui/mission_panel_controller.gd godot-mission-control/scripts/world/world_builder.gd
git commit -m "feat(mc): filter system for agents and jobs by role/state/priority

Dropdown filters in mission panel. Non-matching entities dim out.
Clear-all button resets filters."
```

---

### Task 14: Camera Focus Controls

**Files:**
- Modify: `godot-mission-control/scripts/world/iso_camera.gd`
- Modify: `godot-mission-control/scripts/agents/agent_controller.gd`

- [ ] **Step 1: Add follow mode to camera**

The camera already supports `follow()` from Task 4. Wire it up:

In `agent_controller.gd`, add right-click handler:

```gdscript
func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			EventBus.entity_selected.emit("agent", worker_id)
			EventBus.camera_focus_requested.emit(global_position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			EventBus.camera_follow_requested.emit("agent", worker_id)
```

In `iso_camera.gd`, connect to `camera_follow_requested`:

```gdscript
func _ready() -> void:
	# ... existing ...
	EventBus.camera_follow_requested.connect(_on_follow_requested)

func _on_follow_requested(entity_type: String, entity_id: String) -> void:
	# Find the node by entity_id in the scene tree
	# WorldBuilder maintains agent_nodes dictionary
	var world_builder = get_tree().get_first_node_in_group("world_builder")
	if world_builder and world_builder.agent_nodes.has(entity_id):
		follow(world_builder.agent_nodes[entity_id])
```

**Important:** Add this line to the top of WorldBuilder's `_ready()` function so the camera can find it:
```gdscript
add_to_group("world_builder")
```

- [ ] **Step 2: Add double-click station zoom**

In `station_controller.gd`, detect double-click:

```gdscript
var _last_click_time: float = 0.0

func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var now = Time.get_ticks_msec() / 1000.0
		if now - _last_click_time < 0.4:
			# Double click — zoom to fit
			EventBus.camera_focus_requested.emit(global_position)
		else:
			EventBus.entity_selected.emit("station", station_id)
		_last_click_time = now
```

- [ ] **Step 3: Commit**

```bash
git add godot-mission-control/scripts/world/iso_camera.gd godot-mission-control/scripts/agents/agent_controller.gd godot-mission-control/scripts/stations/station_controller.gd godot-mission-control/scripts/world/world_builder.gd
git commit -m "feat(mc): camera follow mode and station zoom-to-fit

Right-click agent to follow. Double-click station to zoom.
Home key resets camera. WASD/middle-mouse breaks follow."
```

---

### Task 15: Alert Feed

**Files:**
- Create: `godot-mission-control/scripts/ui/alert_feed.gd`
- Modify: `godot-mission-control/scenes/ui/mission_panel.tscn`

- [ ] **Step 1: Create alert_feed.gd**

Create `godot-mission-control/scripts/ui/alert_feed.gd`:

```gdscript
extends VBoxContainer
## Scrolling list of recent notable events.
## Auto-posts alerts for failures, errors, and saturation.

const MAX_ALERTS = 20
const FADE_DURATION = 10.0

var _alerts: Array = []  # Array of {label: Label, time: float}


func _ready() -> void:
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.worker_removed.connect(_on_worker_removed)


func _process(delta: float) -> void:
	# Fade old alerts
	var to_remove = []
	for alert in _alerts:
		alert["time"] -= delta
		if alert["time"] <= 0:
			to_remove.append(alert)
		else:
			var alpha = clampf(alert["time"] / FADE_DURATION, 0.0, 1.0)
			alert["label"].modulate.a = alpha

	for alert in to_remove:
		alert["label"].queue_free()
		_alerts.erase(alert)


func post_alert(message: String, severity: String = "warning") -> void:
	var label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var settings = LabelSettings.new()
	settings.font_size = 11
	match severity:
		"error":
			settings.font_color = Color.html("#e74c3c")
		"warning":
			settings.font_color = Color.html("#f5b041")
		"info":
			settings.font_color = Color.html("#85c1e9")
	label.label_settings = settings

	add_child(label)
	move_child(label, 0)  # Newest at top
	_alerts.append({"label": label, "time": FADE_DURATION})

	# Trim old alerts
	while _alerts.size() > MAX_ALERTS:
		var oldest = _alerts.pop_back()
		oldest["label"].queue_free()

	EventBus.alert_posted.emit(message, severity)


func _on_job_failed(job_id: String, reason: String) -> void:
	var msg = "Job %s failed" % job_id.left(12)
	if reason != "":
		msg += ": %s" % reason.left(40)
	post_alert(msg, "error")


func _on_station_changed(station_id: String) -> void:
	var data = WorldState.stations.get(station_id, {})
	var queue = data.get("queueDepth", 0)
	var cap = data.get("capacity", 1)
	if float(queue) / max(cap, 1) > 0.8:
		post_alert("Station %s saturated (%d/%d)" % [station_id, queue, cap], "warning")


func _on_worker_removed(worker_id: String) -> void:
	post_alert("Worker %s disconnected" % worker_id.left(12), "warning")
```

- [ ] **Step 2: Add AlertFeed to mission panel**

Add an AlertFeed node as a child of the mission panel's VBox, below the station list.

- [ ] **Step 3: Commit**

```bash
git add godot-mission-control/scripts/ui/alert_feed.gd godot-mission-control/scenes/ui/mission_panel.tscn
git commit -m "feat(mc): alert feed for failures, saturation, and disconnects

Auto-posts alerts for job failures, station saturation, and worker
disconnects. Newest at top, fades after 10 seconds. Max 20 visible."
```

---

### Task 16: Idle Fidgets & Emotes

**Files:**
- Modify: `godot-mission-control/scripts/agents/agent_animator.gd`

- [ ] **Step 1: Enhance animator with emote system**

Add to `agent_animator.gd`:

```gdscript
var _emote_node: Label = null
var _emote_timer: float = 0.0
const EMOTE_DURATION = 2.0

const EMOTES = {
	"thinking": "?",
	"success": "!",
	"error": "X",
	"blocked": "...",
	"lightbulb": "*",
}


func show_emote(emote_type: String) -> void:
	if _emote_node:
		_emote_node.queue_free()

	_emote_node = Label.new()
	_emote_node.text = EMOTES.get(emote_type, "?")
	_emote_node.position = Vector2(-4, -28)
	var settings = LabelSettings.new()
	settings.font_size = 16
	settings.font_color = Color.WHITE
	settings.outline_size = 2
	settings.outline_color = Color.BLACK
	_emote_node.label_settings = settings

	if body_sprite:
		body_sprite.add_child(_emote_node)
	_emote_timer = EMOTE_DURATION


func _update_emote(delta: float) -> void:
	if _emote_timer > 0:
		_emote_timer -= delta
		if _emote_timer <= 0 and _emote_node:
			_emote_node.queue_free()
			_emote_node = null
		elif _emote_node:
			# Float upward and fade
			_emote_node.position.y -= delta * 5.0
			_emote_node.modulate.a = clampf(_emote_timer / EMOTE_DURATION, 0.0, 1.0)
```

Call `_update_emote(delta)` from `_process()`. Wire emotes to agent states in agent_controller:
- WORKING → show "lightbulb" emote at start
- BLOCKED → show "blocked" emote
- ERRORED → show "error" emote
- Job completed → show "success" emote

- [ ] **Step 2: Add varied idle fidgets**

Expand `_update_fidget()` to randomly choose from: tiny hop, look-around (eyes shift), small wiggle.

- [ ] **Step 3: Commit**

```bash
git add godot-mission-control/scripts/agents/agent_animator.gd godot-mission-control/scripts/agents/agent_controller.gd
git commit -m "feat(mc): emote system and idle fidgets for blob agents

Emotes float up and fade: lightbulb when working, ? when blocked,
X on error, ! on success. Random idle fidgets every 3-8 seconds."
```

---

### Task 17: Playback Speed Control

**Files:**
- Modify: `godot-mission-control/scripts/ui/hud_controller.gd`
- Modify: `godot-mission-control/scenes/ui/hud.tscn`

- [ ] **Step 1: Add speed slider to HUD**

Add an HSlider to the HUD with values 0.5, 1.0, 2.0, 4.0. On value change, emit `EventBus.playback_speed_changed`.

- [ ] **Step 2: Apply playback speed to agent mover and animator**

In `agent_mover.gd`, read playback speed:

```gdscript
func _ready() -> void:
	parent = get_parent()
	EventBus.playback_speed_changed.connect(func(speed): speed_multiplier = speed)
```

In `agent_animator.gd`, scale animation time by playback speed.

- [ ] **Step 3: Commit**

```bash
git add godot-mission-control/scripts/ui/hud_controller.gd godot-mission-control/scenes/ui/hud.tscn godot-mission-control/scripts/agents/agent_mover.gd godot-mission-control/scripts/agents/agent_animator.gd
git commit -m "feat(mc): playback speed slider (0.5x to 4x)

Controls animation and movement speed only, not backend events.
Slider in HUD top bar."
```

---

### Task 18: Performance Optimization Pass

**Files:**
- Modify: `godot-mission-control/scripts/agents/agent_animator.gd`
- Modify: `godot-mission-control/scripts/stations/station_effects.gd`
- Modify: `godot-mission-control/scripts/world/world_builder.gd`

- [ ] **Step 1: Add viewport culling for agents**

In `agent_animator.gd`, skip animation updates for agents outside the viewport:

```gdscript
func _process(delta: float) -> void:
	if not body_sprite:
		return

	# Skip if off-screen
	var parent_node = get_parent()
	if parent_node and not parent_node.is_visible_in_tree():
		return
	var cam = get_viewport().get_camera_2d()
	if cam:
		var screen_pos = parent_node.get_global_transform_with_canvas().origin
		var viewport_rect = get_viewport().get_visible_rect()
		var margin = 100.0
		if screen_pos.x < -margin or screen_pos.x > viewport_rect.size.x + margin:
			return
		if screen_pos.y < -margin or screen_pos.y > viewport_rect.size.y + margin:
			return

	# ... rest of animation logic
```

- [ ] **Step 2: Add object pooling for job packets**

In `station_controller.gd`, reuse packet nodes instead of creating/freeing:

```gdscript
var _packet_pool: Array = []

func _get_pooled_packet() -> Node2D:
	if _packet_pool.size() > 0:
		var pkt = _packet_pool.pop_back()
		pkt.visible = true
		return pkt
	return load("res://scenes/items/job_packet.tscn").instantiate()

func _return_to_pool(pkt: Node2D) -> void:
	pkt.visible = false
	_packet_pool.append(pkt)
```

- [ ] **Step 3: Cache NavGraph paths**

In `nav_graph.gd`, add a path cache:

```gdscript
var _path_cache: Dictionary = {}

func find_path(from_id: String, to_id: String) -> Array:
	var cache_key = from_id + "→" + to_id
	if _path_cache.has(cache_key):
		return _path_cache[cache_key].duplicate()

	# ... existing Dijkstra logic ...

	_path_cache[cache_key] = result.duplicate()
	return result
```

- [ ] **Step 4: Profile in Godot — verify 60fps with 50 agents and 200 jobs**

- [ ] **Step 5: Commit**

```bash
git add godot-mission-control/scripts/agents/ godot-mission-control/scripts/stations/ godot-mission-control/scripts/world/nav_graph.gd
git commit -m "perf(mc): viewport culling, packet pooling, path caching

Skip animation for off-screen agents. Reuse job packet nodes.
Cache NavGraph paths (stations are static). Target: 60fps at 50 agents."
```

---

## Summary

| Phase | Tasks | Key Deliverable |
|-------|-------|-----------------|
| 1 | Tasks 1-7 | Vertical slice: one blob doing full job loop, live data, basic HUD |
| 2 | Tasks 8-12 | Full pipeline: all stations, multiple agents, mission panel, inspector |
| 3 | Tasks 13-18 | Polish: filters, camera follow, alerts, emotes, speed control, perf |

Total: 18 tasks. Each task has 3-7 steps. Frequent commits at each task boundary.
