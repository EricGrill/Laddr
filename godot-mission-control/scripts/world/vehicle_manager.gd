extends Node2D
## Spawns colored rectangle vehicles that drive along roads when jobs are assigned,
## completed, or failed. Replaces job_transit_manager.gd.

const TRAVEL_SPEED_PX := 300.0
const MIN_TRAVEL_DURATION := 0.4

## Priority colors
const COLOR_NORMAL   := Color(0.2, 0.85, 0.95, 1.0)   # cyan
const COLOR_HIGH     := Color(1.0, 0.85, 0.2, 1.0)    # yellow
const COLOR_CRITICAL := Color(1.0, 0.2, 1.0, 1.0)     # magenta
const COLOR_LOW      := Color(0.7, 0.7, 0.7, 0.6)     # dim white

var _roads = null                             # RoadSystem (nav graph)
var _world_builder: Node = null
var _active_vehicles: Dictionary = {}         # job_id -> vehicle state
var _job_last_station: Dictionary = {}        # job_id -> last known station_id
var _time: float = 0.0


func _ready() -> void:
	set_process(true)
	_world_builder = get_parent()
	if _world_builder and _world_builder.has_method("get_nav_graph"):
		_roads = _world_builder.call("get_nav_graph")
	_connect_signals()
	_sync_from_snapshot()


func _connect_signals() -> void:
	WorldState.snapshot_loaded.connect(_sync_from_snapshot)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.job_assigned.connect(_on_job_assigned)
	WorldState.job_handoff.connect(_on_job_handoff)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)


func _sync_from_snapshot() -> void:
	_clear_active_vehicles()
	_job_last_station.clear()
	for job_id in WorldState.jobs:
		_cache_job_station(job_id)


func _process(delta: float) -> void:
	_time += delta
	var to_release: Array = []

	for job_id in _active_vehicles:
		var state: Dictionary = _active_vehicles[job_id]
		var vehicle: Node2D = state.get("vehicle")
		if not is_instance_valid(vehicle):
			to_release.append(job_id)
			continue

		state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
		_update_vehicle(state)

		if state.get("done", false):
			to_release.append(job_id)

	for job_id in to_release:
		_release_vehicle(job_id)


# ── Signal handlers ────────────────────────────────────────────────────────────

func _cache_job_station(job_id: String) -> void:
	var job = WorldState.jobs.get(job_id, {})
	if job.is_empty():
		return
	var station_id = str(job.get("currentStationId", ""))
	if station_id != "":
		_job_last_station[job_id] = station_id


func _on_job_changed(job_id: String) -> void:
	_cache_job_station(job_id)


func _on_job_assigned(job_id: String, _agent_id: String, station_id: String) -> void:
	var source = _resolve_source_station(job_id, station_id)
	_launch_vehicle(job_id, source, station_id)


func _on_job_handoff(job_id: String, from_station_id: String, to_station_id: String) -> void:
	_launch_vehicle(job_id, from_station_id, to_station_id)


func _on_job_completed(job_id: String) -> void:
	var source = _resolve_source_station(job_id, "output-dock")
	_launch_vehicle(job_id, source, "output-dock")


func _on_job_failed(job_id: String, _reason: String) -> void:
	var source = _resolve_source_station(job_id, "error-chamber")
	_launch_vehicle(job_id, source, "error-chamber")


# ── Station / path helpers ─────────────────────────────────────────────────────

func _resolve_source_station(job_id: String, fallback_station: String) -> String:
	if _job_last_station.has(job_id):
		var cached = str(_job_last_station[job_id])
		if cached != "":
			return cached
	var job = WorldState.jobs.get(job_id, {})
	var current_station = str(job.get("currentStationId", ""))
	if current_station != "":
		return current_station
	if fallback_station != "":
		return fallback_station
	return "intake"


func _station_position(station_id: String) -> Vector2:
	if station_id == "":
		return Vector2.ZERO
	if _world_builder and _world_builder.has_method("get_station_screen_pos"):
		var pos = _world_builder.call("get_station_screen_pos", station_id)
		if pos is Vector2:
			return pos
	return Vector2.ZERO


func _path_between(from_station_id: String, to_station_id: String, start_pos: Vector2, end_pos: Vector2) -> Array:
	if _roads and _roads.has_method("find_path"):
		var path = _roads.find_path(from_station_id, to_station_id)
		if path is Array and path.size() >= 2:
			return path
	return [start_pos, end_pos]


func _path_length(path: Array) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += (path[i] as Vector2).distance_to(path[i + 1] as Vector2)
	return total


func _sample_path(path: Array, distance: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if path.size() == 1:
		return path[0]
	var remaining = distance
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg = a.distance_to(b)
		if seg <= 0.001:
			continue
		if remaining <= seg:
			return a.lerp(b, clampf(remaining / seg, 0.0, 1.0))
		remaining -= seg
	return path[path.size() - 1]


# ── Vehicle spawning / update ──────────────────────────────────────────────────

func _priority_color(priority: String) -> Color:
	match priority:
		"high":     return COLOR_HIGH
		"critical": return COLOR_CRITICAL
		"low":      return COLOR_LOW
		_:          return COLOR_NORMAL


func _create_vehicle(color: Color) -> Node2D:
	var root := Node2D.new()
	root.z_index = 15

	# Glow — 16×8, same color at alpha 0.15
	var glow := ColorRect.new()
	glow.size = Vector2(16.0, 8.0)
	glow.position = Vector2(-8.0, -4.0)
	var glow_color := color
	glow_color.a = 0.15
	glow.color = glow_color
	root.add_child(glow)

	# Body — 10×6 px, centered
	var body := ColorRect.new()
	body.size = Vector2(10.0, 6.0)
	body.position = Vector2(-5.0, -3.0)
	body.color = color
	root.add_child(body)

	return root


func _launch_vehicle(job_id: String, from_station_id: String, to_station_id: String) -> void:
	if _world_builder == null or not _world_builder.has_method("get_nav_graph"):
		return

	# Cancel any existing vehicle for this job
	if _active_vehicles.has(job_id):
		_release_vehicle(job_id)

	var job_data = WorldState.jobs.get(job_id, {})
	var priority = str(job_data.get("priority", "normal"))
	var color = _priority_color(priority)

	var start_pos = _station_position(from_station_id)
	var end_pos   = _station_position(to_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = end_pos
	if end_pos == Vector2.ZERO:
		end_pos = start_pos
	if start_pos == Vector2.ZERO and end_pos == Vector2.ZERO:
		return

	var path = _path_between(from_station_id, to_station_id, start_pos, end_pos)
	var vehicle = _create_vehicle(color)
	add_child(vehicle)
	vehicle.position = path[0] if path.size() > 0 else start_pos

	_active_vehicles[job_id] = {
		"vehicle": vehicle,
		"path": path,
		"elapsed": 0.0,
		"duration": max(MIN_TRAVEL_DURATION, _path_length(path) / TRAVEL_SPEED_PX),
		"done": false,
	}
	_job_last_station[job_id] = to_station_id


func _update_vehicle(state: Dictionary) -> void:
	var vehicle: Node2D = state.get("vehicle")
	if not is_instance_valid(vehicle):
		state["done"] = true
		return

	var path: Array = state.get("path", [])
	var duration: float = float(state.get("duration", MIN_TRAVEL_DURATION))
	var elapsed: float  = float(state.get("elapsed", 0.0))
	var progress = clampf(elapsed / max(duration, 0.001), 0.0, 1.0)

	# smoothstep interpolation
	var eased = progress * progress * (3.0 - 2.0 * progress)
	var total_distance = _path_length(path)
	vehicle.position = _sample_path(path, total_distance * eased)

	# Fade out when t > 0.85
	if progress > 0.85:
		var fade_t = (progress - 0.85) / 0.15
		vehicle.modulate.a = clampf(1.0 - fade_t, 0.0, 1.0)
	else:
		vehicle.modulate.a = 1.0

	if progress >= 1.0:
		state["done"] = true


func _release_vehicle(job_id: String) -> void:
	if not _active_vehicles.has(job_id):
		return
	var state: Dictionary = _active_vehicles[job_id]
	var vehicle: Node2D = state.get("vehicle")
	if is_instance_valid(vehicle):
		vehicle.queue_free()
	_active_vehicles.erase(job_id)


func _clear_active_vehicles() -> void:
	for job_id in _active_vehicles:
		var state: Dictionary = _active_vehicles[job_id]
		var vehicle: Node2D = state.get("vehicle")
		if is_instance_valid(vehicle):
			vehicle.queue_free()
	_active_vehicles.clear()
