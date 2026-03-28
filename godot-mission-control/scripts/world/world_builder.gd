extends Node2D
## Dynamically builds the world from backend WebSocket snapshot.
## Spawns stations, agents, floor grid, and nav graph from live data.

const STATION_TYPES_PATH = "res://data/station_types.json"

var iso: IsometricUtils = IsometricUtils.new()
var nav: NavGraph = NavGraph.new()
var station_types: Dictionary = {}
var station_nodes: Dictionary = {}  # station_id -> Node2D
var agent_nodes: Dictionary = {}  # worker_id -> BlobAgent node
var _snapshot_processed: bool = false
var _floor_node: Node2D = null
var _job_delivery: Node2D = null
var _sidious: Node2D = null
var _triage_droid: Node2D = null
var _camera: Camera2D = null
var _ambient_root: Node2D = null
var _ambient_orbits: Array = []
var _ambient_time: float = 0.0
var _world_emphasis: float = 0.0
var _floor_dark_tex: Texture2D = null
var _floor_light_tex: Texture2D = null
var _suppress_reactions: bool = false
var _overflow_active: bool = false

# Grid layout — wider spacing for bigger sprites
const TILE_SIZE = 64
const GRID_W = 20
const GRID_H = 16

# Fixed stations — positioned for a nice isometric spread
const FIXED_POSITIONS = {
	"intake": Vector2(3, 4),
	"dispatcher": Vector2(8, 7),
	"supervisor": Vector2(13, 3),
	"error-chamber": Vector2(3, 11),
	"output-dock": Vector2(17, 7),
}

# Dynamic worker stations — 2-column grid, tighter spacing
const DYNAMIC_START = Vector2(6, 10)
const DYNAMIC_COLS = 3
const DYNAMIC_COL_SPACING = 3.5
const DYNAMIC_ROW_SPACING = 3


func _ready() -> void:
	add_to_group("world_builder")
	set_process(true)
	station_types = _load_json(STATION_TYPES_PATH)
	iso.setup(TILE_SIZE)
	_camera = get_parent().get_node_or_null("Camera")

	_draw_floor_grid()
	_build_ambient_layer()
	_spawn_decorations()
	_setup_job_delivery()

	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	FilterState.filters_changed.connect(_on_filters_changed)


func get_nav_graph() -> NavGraph:
	return nav


func get_station_screen_pos(station_id: String) -> Vector2:
	return nav.get_position(station_id)


func _draw_floor_grid() -> void:
	if _floor_node:
		_floor_node.queue_free()
	_floor_node = Node2D.new()
	_floor_node.name = "FloorGrid"
	_floor_node.z_index = -5
	add_child(_floor_node)

	_floor_dark_tex = load("res://assets/sprites/tiles/floor_tile_dark.png")
	_floor_light_tex = load("res://assets/sprites/tiles/floor_tile_light.png")

	for gx in range(GRID_W):
		for gy in range(GRID_H):
			var screen_pos = iso.grid_to_screen(Vector2(gx, gy))
			if _floor_dark_tex and _floor_light_tex:
				var sprite = Sprite2D.new()
				sprite.texture = _floor_dark_tex if (gx + gy) % 2 == 0 else _floor_light_tex
				sprite.position = screen_pos
				sprite.scale = Vector2(1.0, 1.0)
				# Fade edges for softer look
				var dist_from_center = Vector2(gx - GRID_W / 2.0, gy - GRID_H / 2.0).length()
				var max_dist = Vector2(GRID_W / 2.0, GRID_H / 2.0).length()
				var alpha = clampf(1.0 - (dist_from_center / max_dist) * 0.5, 0.4, 1.0)
				sprite.modulate = Color(1, 1, 1, alpha)
				_floor_node.add_child(sprite)
			else:
				# Fallback to colored rects
				var tile = ColorRect.new()
				if (gx + gy) % 2 == 0:
					tile.color = Color(0.18, 0.20, 0.25, 1.0)
				else:
					tile.color = Color(0.15, 0.17, 0.22, 1.0)
				tile.size = Vector2(TILE_SIZE - 2, TILE_SIZE / 2 - 1)
				tile.position = screen_pos - tile.size / 2
				_floor_node.add_child(tile)


func _build_ambient_layer() -> void:
	if _ambient_root:
		_ambient_root.queue_free()
	_ambient_root = Node2D.new()
	_ambient_root.name = "AmbientLayer"
	_ambient_root.z_index = -4
	add_child(_ambient_root)
	_ambient_orbits.clear()

	if not _floor_light_tex:
		return

	var anchors = [
		{"center": iso.grid_to_screen(Vector2(10, 7)), "radius": Vector2(170, 60), "speed": 0.16, "phase": 0.0, "scale": 1.75, "color": Color(0.25, 0.9, 1.0, 0.10)},
		{"center": iso.grid_to_screen(Vector2(8, 7)), "radius": Vector2(96, 34), "speed": 0.28, "phase": 1.3, "scale": 1.2, "color": Color(0.35, 0.8, 1.0, 0.08)},
		{"center": iso.grid_to_screen(Vector2(13, 3)), "radius": Vector2(88, 30), "speed": 0.21, "phase": 2.1, "scale": 1.1, "color": Color(0.55, 0.65, 1.0, 0.08)},
		{"center": iso.grid_to_screen(Vector2(3, 4)), "radius": Vector2(72, 26), "speed": 0.24, "phase": 2.8, "scale": 1.0, "color": Color(0.55, 1.0, 0.75, 0.07)},
	]

	for anchor in anchors:
		var sprite = Sprite2D.new()
		sprite.texture = _floor_light_tex
		sprite.centered = true
		sprite.scale = Vector2.ONE * float(anchor["scale"])
		sprite.modulate = anchor["color"]
		_ambient_root.add_child(sprite)
		_ambient_orbits.append({
			"node": sprite,
			"center": anchor["center"],
			"radius": anchor["radius"],
			"speed": anchor["speed"],
			"phase": anchor["phase"],
			"base_color": anchor["color"],
			"base_scale": float(anchor["scale"]),
			"spin": randf_range(-0.2, 0.2),
		})


func _react_to_event(zoom_delta: float, shake_strength: float, duration: float, emphasis: float) -> void:
	_world_emphasis = maxf(_world_emphasis, emphasis)
	if _camera and _camera.has_method("pulse_attention"):
		_camera.call("pulse_attention", zoom_delta, shake_strength, duration)


func _process(delta: float) -> void:
	_ambient_time += delta
	_world_emphasis = maxf(0.0, _world_emphasis - delta * 0.45)
	_update_ambient_layer()


func _update_ambient_layer() -> void:
	if _floor_node:
		var floor_alpha = clampf(0.92 + sin(_ambient_time * 0.28) * 0.025 + _world_emphasis * 0.05, 0.82, 1.0)
		_floor_node.modulate = Color(1.0, 1.0, 1.0, floor_alpha)

	if not _ambient_root:
		return

	_ambient_root.modulate.a = clampf(0.85 + _world_emphasis * 0.15, 0.75, 1.0)

	for orbit in _ambient_orbits:
		var sprite = orbit.get("node")
		if not (sprite is Sprite2D):
			continue
		if not is_instance_valid(sprite):
			continue
		var center: Vector2 = orbit.get("center", Vector2.ZERO)
		var radius: Vector2 = orbit.get("radius", Vector2.ZERO)
		var speed: float = float(orbit.get("speed", 0.2))
		var phase: float = float(orbit.get("phase", 0.0))
		var base_color: Color = orbit.get("base_color", Color.WHITE)
		var base_scale: float = float(orbit.get("base_scale", 1.0))
		var wobble = Vector2(
			cos(_ambient_time * speed + phase) * radius.x,
			sin(_ambient_time * speed * 1.35 + phase * 1.2) * radius.y
		)
		sprite.position = center + wobble + Vector2(0, sin(_ambient_time * 0.6 + phase) * 4.0)
		sprite.rotation = sin(_ambient_time * 0.35 + phase) * 0.08 + float(orbit.get("spin", 0.0)) * _ambient_time
		sprite.scale = Vector2.ONE * base_scale * (1.0 + sin(_ambient_time * (speed * 4.0) + phase) * 0.08)
		sprite.modulate = Color(
			base_color.r,
			base_color.g,
			base_color.b,
			clampf(base_color.a * (0.75 + _world_emphasis * 0.35) * (0.85 + sin(_ambient_time * 1.8 + phase) * 0.15), 0.02, 0.32)
		)


func _on_snapshot_loaded() -> void:
	if _snapshot_processed:
		for worker_id in WorldState.workers:
			if not agent_nodes.has(worker_id):
				_spawn_agent(worker_id)
		return

	_snapshot_processed = true
	_build_from_snapshot()

	# Distribute jobs to stations for queue visuals
	_suppress_reactions = true
	_distribute_jobs()
	_suppress_reactions = false

	# Tell job delivery system where intake is
	if _job_delivery and _job_delivery.has_method("set_intake_position"):
		var intake_pos = nav.get_position("intake")
		if intake_pos != Vector2.ZERO:
			_job_delivery.set_intake_position(intake_pos)

	# Spawn Sidious at Command Deck
	_spawn_sidious()

	# Spawn Triage Droid near Dispatcher
	_spawn_triage_droid()

	for worker_id in WorldState.workers:
		_spawn_agent(worker_id)

	# Auto-fit camera to show all stations
	_auto_fit_camera()


func _build_from_snapshot() -> void:
	for sid in station_nodes:
		station_nodes[sid].queue_free()
	station_nodes.clear()
	nav = NavGraph.new()

	var dynamic_index = 0

	for station_id in WorldState.stations:
		var station_data = WorldState.stations[station_id]
		var grid_pos: Vector2

		if FIXED_POSITIONS.has(station_id):
			grid_pos = FIXED_POSITIONS[station_id]
		else:
			var col = dynamic_index % DYNAMIC_COLS
			var row = dynamic_index / DYNAMIC_COLS
			grid_pos = DYNAMIC_START + Vector2(col * DYNAMIC_COL_SPACING, row * DYNAMIC_ROW_SPACING)
			dynamic_index += 1

		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(station_id, screen_pos)
		_spawn_station(station_id, station_data, screen_pos)

	_add_waypoints()
	_build_paths()


func _spawn_station(station_id: String, data: Dictionary, screen_pos: Vector2) -> void:
	var station_scn = load("res://scenes/stations/station.tscn")
	var node = station_scn.instantiate()
	node.position = screen_pos

	var stype = data.get("type", "code")
	var slabel = data.get("label", station_id)
	var capacity = data.get("capacity", 10)

	# For worker stations, show the worker name prominently
	var worker_id = data.get("workerId", "")
	if worker_id != "" and worker_id != null:
		slabel = str(slabel)

	var type_info = station_types.get(stype, {})
	var color = Color.html(type_info.get("color", "#888888"))

	node.setup(station_id, stype, slabel, capacity, color)
	add_child(node)
	station_nodes[station_id] = node


func _add_waypoints() -> void:
	var waypoints = {
		"wp_center": Vector2(10, 7),
		"wp_top": Vector2(10, 4),
		"wp_left": Vector2(4, 7),
		"wp_right": Vector2(16, 7),
		"wp_bottom": Vector2(10, 12),
		"wp_topleft": Vector2(4, 4),
		"wp_topright": Vector2(16, 4),
		"wp_bottomleft": Vector2(4, 12),
	}
	for wp_id in waypoints:
		nav.add_node(wp_id, iso.grid_to_screen(waypoints[wp_id]))


func _build_paths() -> void:
	# Connect fixed stations through waypoints
	var routes = {
		"intake": ["wp_topleft", "wp_left", "wp_center"],
		"dispatcher": ["wp_center"],
		"supervisor": ["wp_topright", "wp_top", "wp_center"],
		"error-chamber": ["wp_bottomleft", "wp_left", "wp_center"],
		"output-dock": ["wp_right", "wp_center"],
	}

	for station_id in routes:
		if nav.get_position(station_id) != Vector2.ZERO:
			var path = [station_id] + routes[station_id]
			nav.add_path(path)

	# Dynamic stations connect through bottom
	for station_id in WorldState.stations:
		if not FIXED_POSITIONS.has(station_id):
			if nav.get_position(station_id) != Vector2.ZERO:
				nav.add_path([station_id, "wp_bottom", "wp_center"])

	# Waypoint mesh
	nav.add_path(["wp_left", "wp_center", "wp_right"])
	nav.add_path(["wp_top", "wp_center", "wp_bottom"])
	nav.add_path(["wp_topleft", "wp_top", "wp_topright"])
	nav.add_path(["wp_bottomleft", "wp_bottom"])


func _auto_fit_camera() -> void:
	if station_nodes.is_empty():
		return
	# Find bounding box of all stations
	var min_pos = Vector2(INF, INF)
	var max_pos = Vector2(-INF, -INF)
	for sid in station_nodes:
		var pos = station_nodes[sid].position
		min_pos.x = min(min_pos.x, pos.x)
		min_pos.y = min(min_pos.y, pos.y)
		max_pos.x = max(max_pos.x, pos.x)
		max_pos.y = max(max_pos.y, pos.y)

	var center = (min_pos + max_pos) / 2
	var spread = max_pos - min_pos
	var viewport_size = get_viewport().get_visible_rect().size

	# Calculate zoom to fit all stations with padding
	var padding = 200.0
	var zoom_x = viewport_size.x / (spread.x + padding) if spread.x > 0 else 1.0
	var zoom_y = viewport_size.y / (spread.y + padding) if spread.y > 0 else 1.0
	var fit_zoom = min(zoom_x, zoom_y)
	fit_zoom = clamp(fit_zoom, 0.4, 1.5)

	var camera = get_parent().get_node_or_null("Camera")
	if camera:
		camera.global_position = center
		camera._target_position = center
		camera.zoom = Vector2(fit_zoom, fit_zoom)
		camera._target_zoom = Vector2(fit_zoom, fit_zoom)


func _distribute_jobs() -> void:
	# Map job states to stations for visual queue display
	var station_jobs: Dictionary = {}  # station_id -> [job_ids]
	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var job_state = job.get("state", "queued")
		var station_id = job.get("currentStationId", "")

		# If job has an assigned station, use it
		if station_id != null and station_id != "" and WorldState.stations.has(station_id):
			if not station_jobs.has(station_id):
				station_jobs[station_id] = []
			station_jobs[station_id].append(jid)
			continue

		# Otherwise distribute based on state
		var target = ""
		match job_state:
			"queued":
				target = "intake"
			"processing":
				target = "dispatcher"
			"completed":
				target = "output-dock"
			"failed":
				target = "error-chamber"

		if target != "" and WorldState.stations.has(target):
			if not station_jobs.has(target):
				station_jobs[target] = []
			station_jobs[target].append(jid)

	# Update station data with job lists so queue visuals work
	for sid in station_jobs:
		if WorldState.stations.has(sid):
			WorldState.stations[sid]["activeJobIds"] = station_jobs[sid]
			WorldState.stations[sid]["queueDepth"] = station_jobs[sid].size()
			WorldState.station_changed.emit(sid)


func _spawn_decorations() -> void:
	# Place decorative props around the map in empty spaces
	var decor_items = [
		{"file": "hologram_globe", "pos": Vector2(1, 6), "scale": 0.3},
		{"file": "server_rack", "pos": Vector2(18, 3), "scale": 0.3},
		{"file": "coffee_station", "pos": Vector2(13, 11), "scale": 0.28},
		{"file": "antenna_dish", "pos": Vector2(5, 1), "scale": 0.3},
		{"file": "server_rack", "pos": Vector2(16, 12), "scale": 0.25},
		{"file": "hologram_globe", "pos": Vector2(12, 1), "scale": 0.25},
	]
	for item in decor_items:
		var tex = load("res://assets/sprites/decor/%s.png" % item["file"])
		if not tex:
			continue
		var sprite = Sprite2D.new()
		sprite.texture = tex
		sprite.scale = Vector2(item["scale"], item["scale"])
		sprite.position = iso.grid_to_screen(item["pos"])
		sprite.z_index = 2
		sprite.modulate = Color(1, 1, 1, 0.85)
		add_child(sprite)


func _setup_job_delivery() -> void:
	var delivery_script = load("res://scripts/world/job_delivery.gd")
	if delivery_script:
		_job_delivery = Node2D.new()
		_job_delivery.name = "JobDelivery"
		_job_delivery.set_script(delivery_script)
		add_child(_job_delivery)


func _spawn_sidious() -> void:
	var script = load("res://scripts/agents/sidious_controller.gd")
	if not script:
		return
	_sidious = Node2D.new()
	_sidious.name = "Sidious"
	_sidious.set_script(script)
	# Position at Command Deck with slight offset
	var cmd_pos = nav.get_position("supervisor")
	if cmd_pos != Vector2.ZERO:
		_sidious.position = cmd_pos + Vector2(0, 20)
	else:
		_sidious.position = iso.grid_to_screen(Vector2(10, 3)) + Vector2(0, 20)
	_sidious.z_index = 10
	add_child(_sidious)


func _spawn_triage_droid() -> void:
	var script = load("res://scripts/agents/triage_controller.gd")
	if not script:
		return
	_triage_droid = Node2D.new()
	_triage_droid.name = "TriageDroid"
	_triage_droid.set_script(script)
	# Position between Intake and Dispatcher
	var intake_pos = nav.get_position("intake")
	var dispatch_pos = nav.get_position("dispatcher")
	if intake_pos != Vector2.ZERO and dispatch_pos != Vector2.ZERO:
		_triage_droid.position = (intake_pos + dispatch_pos) / 2 + Vector2(0, -15)
	else:
		_triage_droid.position = iso.grid_to_screen(Vector2(4, 5))
	_triage_droid.z_index = 10
	add_child(_triage_droid)


func _on_station_changed(_station_id: String) -> void:
	if _suppress_reactions:
		return
	var data = WorldState.stations.get(_station_id, {})
	if data.is_empty():
		return
	var capacity = max(int(data.get("capacity", 1)), 1)
	var queue_depth = int(data.get("queueDepth", 0))
	var saturation = float(queue_depth) / float(capacity)
	if saturation >= 0.85:
		_react_to_event(0.01 + saturation * 0.015, 1.5 + saturation * 3.0, 0.16 + saturation * 0.05, saturation * 0.5)


func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new:
		_spawn_agent(worker_id)


func _on_worker_removed(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		agent_nodes[worker_id].queue_free()
		agent_nodes.erase(worker_id)
		_react_to_event(0.02, 2.0, 0.12, 0.2)


func _on_job_completed(_job_id: String) -> void:
	_react_to_event(0.02, 1.2, 0.12, 0.18)


func _on_job_failed(_job_id: String, _reason: String) -> void:
	_react_to_event(0.05, 3.5, 0.22, 0.45)


func _on_metrics_changed() -> void:
	var overflow = bool(WorldState.metrics.get("overflowActive", false))
	if overflow and not _overflow_active:
		_react_to_event(0.06, 4.5, 0.25, 0.6)
	_overflow_active = overflow


func _spawn_agent(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		return
	var agent_scn = load("res://scenes/agents/blob_agent.tscn")
	var agent = agent_scn.instantiate()

	var colors = [
		Color.html("#d4836b"), Color.html("#e8a87c"), Color.html("#f0c8a0"),
		Color.html("#c97b7b"), Color.html("#d4a574"), Color.html("#b07d62"),
	]
	var color_index = worker_id.hash() % colors.size()
	agent.setup(worker_id, nav, colors[color_index])

	# Position at worker's station or intake
	var worker_station_id = "station-" + worker_id
	var start_pos = nav.get_position(worker_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = nav.get_position("intake")
	if start_pos == Vector2.ZERO:
		start_pos = iso.grid_to_screen(Vector2(10, 7))
	agent.position = start_pos

	add_child(agent)
	agent_nodes[worker_id] = agent


func _on_filters_changed() -> void:
	for worker_id in agent_nodes:
		var agent_node = agent_nodes[worker_id]
		var agent_data: Dictionary = {}
		for agent_id in WorldState.agents:
			var data = WorldState.agents[agent_id]
			if data.get("workerId", agent_id) == worker_id:
				agent_data = data
				break
		var passes = FilterState.passes_agent_filter(agent_data)
		agent_node.modulate.a = 1.0 if passes else 0.3


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
