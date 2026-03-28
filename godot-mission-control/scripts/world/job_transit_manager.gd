extends Node2D
## Animates transient job packets moving between stations.
## Reuses the existing packet scene so transit reads as actual work traveling.

const PACKET_SCENE := preload("res://scenes/items/job_packet.tscn")

const TRAVEL_SPEED_PX := 440.0
const MIN_TRAVEL_DURATION := 0.35
const BURST_DURATION := 0.22

var _world_builder: Node = null
var _active_packets: Dictionary = {}  # job_id -> packet state
var _job_last_station: Dictionary = {}
var _time: float = 0.0


func _ready() -> void:
	set_process(true)
	_world_builder = get_parent()
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
	_clear_active_packets()
	_job_last_station.clear()
	for job_id in WorldState.jobs:
		_cache_job_station(job_id)


func _process(delta: float) -> void:
	_time += delta
	var to_release: Array = []

	for job_id in _active_packets:
		var state: Dictionary = _active_packets[job_id]
		var packet: Node2D = state.get("packet")
		if not is_instance_valid(packet):
			to_release.append(job_id)
			continue

		var mode = str(state.get("mode", "travel"))
		state["elapsed"] = float(state.get("elapsed", 0.0)) + delta

		if mode == "travel":
			_update_travel_packet(state)
		else:
			_update_burst_packet(state)

		if state.get("done", false):
			to_release.append(job_id)

	for job_id in to_release:
		_release_packet(job_id)


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
	var source_station = _resolve_source_station(job_id, station_id)
	_launch_transit(job_id, source_station, station_id, "processing")


func _on_job_handoff(job_id: String, from_station_id: String, to_station_id: String) -> void:
	_launch_transit(job_id, from_station_id, to_station_id, "processing")


func _on_job_completed(job_id: String) -> void:
	var final_station = _resolve_final_station(job_id, "output-dock")
	var source_station = _resolve_source_station(job_id, final_station)
	_launch_transit(job_id, source_station, final_station, "completed")


func _on_job_failed(job_id: String, _reason: String) -> void:
	var final_station = _resolve_final_station(job_id, "error-chamber")
	var source_station = _resolve_source_station(job_id, final_station)
	_launch_transit(job_id, source_station, final_station, "failed")


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


func _resolve_final_station(job_id: String, fallback_station: String) -> String:
	var job = WorldState.jobs.get(job_id, {})
	if fallback_station != "":
		return fallback_station
	var current_station = str(job.get("currentStationId", ""))
	if current_station != "":
		return current_station
	return "intake"


func _launch_transit(job_id: String, from_station_id: String, to_station_id: String, final_state: String) -> void:
	if _world_builder == null or not _world_builder.has_method("get_nav_graph"):
		return

	if _active_packets.has(job_id):
		_release_packet(job_id)

	var job_data = WorldState.jobs.get(job_id, {})
	var priority = str(job_data.get("priority", "normal"))
	var start_pos = _station_position(from_station_id)
	var end_pos = _station_position(to_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = end_pos
	if end_pos == Vector2.ZERO:
		end_pos = start_pos

	var path = _path_between(from_station_id, to_station_id, start_pos, end_pos)
	if path.size() < 2:
		_spawn_burst(job_id, priority, start_pos if start_pos != Vector2.ZERO else end_pos, final_state)
		return

	var packet = _spawn_packet(job_id, priority, path[0])
	if not packet:
		return

	_active_packets[job_id] = {
		"packet": packet,
		"path": path,
		"elapsed": 0.0,
		"duration": max(MIN_TRAVEL_DURATION, _path_length(path) / TRAVEL_SPEED_PX),
		"mode": "travel",
		"final_state": final_state,
		"priority": priority,
	}
	packet.call_deferred("set_state", "processing")
	packet.z_index = 20
	_job_last_station[job_id] = to_station_id


func _spawn_packet(job_id: String, priority: String, start_position: Vector2) -> Node2D:
	var packet = PACKET_SCENE.instantiate()
	add_child(packet)
	packet.position = start_position
	packet.z_index = 20
	packet.call_deferred("setup", job_id, priority)
	return packet


func _spawn_burst(job_id: String, priority: String, position: Vector2, final_state: String) -> void:
	var packet = _spawn_packet(job_id, priority, position)
	if not packet:
		return
	packet.call_deferred("set_state", final_state)
	_active_packets[job_id] = {
		"packet": packet,
		"path": [position],
		"elapsed": 0.0,
		"duration": BURST_DURATION,
		"mode": "burst",
		"done": false,
	}


func _station_position(station_id: String) -> Vector2:
	if station_id == "":
		return Vector2.ZERO
	if _world_builder and _world_builder.has_method("get_station_screen_pos"):
		var pos = _world_builder.call("get_station_screen_pos", station_id)
		if pos is Vector2:
			return pos
	return Vector2.ZERO


func _path_between(from_station_id: String, to_station_id: String, start_pos: Vector2, end_pos: Vector2) -> Array:
	if _world_builder and _world_builder.has_method("get_nav_graph"):
		var nav = _world_builder.call("get_nav_graph")
		if nav and nav.has_method("find_path"):
			var path = nav.find_path(from_station_id, to_station_id)
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
		var segment_length = a.distance_to(b)
		if segment_length <= 0.001:
			continue
		if remaining <= segment_length:
			return a.lerp(b, clampf(remaining / segment_length, 0.0, 1.0))
		remaining -= segment_length
	return path[path.size() - 1]


func _sample_tangent(path: Array, distance: float) -> Vector2:
	if path.size() < 2:
		return Vector2.RIGHT

	var remaining = distance
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var segment_length = a.distance_to(b)
		if segment_length <= 0.001:
			continue
		if remaining <= segment_length:
			return (b - a).normalized()
		remaining -= segment_length
	return ((path[path.size() - 1] as Vector2) - (path[path.size() - 2] as Vector2)).normalized()


func _update_travel_packet(state: Dictionary) -> void:
	var packet: Node2D = state.get("packet")
	if not is_instance_valid(packet):
		state["done"] = true
		return

	var path: Array = state.get("path", [])
	var duration: float = float(state.get("duration", MIN_TRAVEL_DURATION))
	var elapsed: float = float(state.get("elapsed", 0.0))
	var progress = clampf(elapsed / max(duration, 0.001), 0.0, 1.0)
	var eased = progress * progress * (3.0 - 2.0 * progress)
	var total_distance = _path_length(path)
	var position = _sample_path(path, total_distance * eased)
	var tangent = _sample_tangent(path, total_distance * eased)

	packet.position = position + Vector2(0, sin(elapsed * 10.0) * 2.0)
	packet.rotation = tangent.angle() + PI * 0.5
	packet.scale = Vector2.ONE * (1.0 + sin(elapsed * 9.0) * 0.035)
	packet.modulate.a = 0.8 + sin(elapsed * 12.0) * 0.08

	if progress >= 1.0:
		var final_state = str(state.get("final_state", "processing"))
		if final_state == "processing":
			state["done"] = true
			return
		packet.set_state(final_state)
		state["mode"] = "burst"
		state["elapsed"] = 0.0
		state["duration"] = BURST_DURATION


func _update_burst_packet(state: Dictionary) -> void:
	var packet: Node2D = state.get("packet")
	if not is_instance_valid(packet):
		state["done"] = true
		return

	var elapsed: float = float(state.get("elapsed", 0.0))
	var duration: float = float(state.get("duration", BURST_DURATION))
	var progress = clampf(elapsed / max(duration, 0.001), 0.0, 1.0)

	packet.scale = Vector2.ONE * (1.0 + progress * 0.7)
	packet.modulate.a = 1.0 - progress
	packet.rotation += 0.03

	if progress >= 1.0:
		state["done"] = true


func _release_packet(job_id: String) -> void:
	if not _active_packets.has(job_id):
		return
	var state: Dictionary = _active_packets[job_id]
	var packet: Node2D = state.get("packet")
	if is_instance_valid(packet):
		packet.queue_free()
	_active_packets.erase(job_id)


func _clear_active_packets() -> void:
	for job_id in _active_packets:
		var state: Dictionary = _active_packets[job_id]
		var packet: Node2D = state.get("packet")
		if is_instance_valid(packet):
			packet.queue_free()
	_active_packets.clear()
