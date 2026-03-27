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

# Dynamic worker stations fill a row
const DYNAMIC_START = Vector2(7, 12)
const DYNAMIC_SPACING = Vector2(5, 0)


func _ready() -> void:
	add_to_group("world_builder")
	station_types = _load_json(STATION_TYPES_PATH)
	iso.setup(TILE_SIZE)

	_draw_floor_grid()
	_setup_job_delivery()

	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.station_changed.connect(_on_station_changed)
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

	var tile_dark = load("res://assets/sprites/tiles/floor_tile_dark.png")
	var tile_light = load("res://assets/sprites/tiles/floor_tile_light.png")

	for gx in range(GRID_W):
		for gy in range(GRID_H):
			var screen_pos = iso.grid_to_screen(Vector2(gx, gy))
			if tile_dark and tile_light:
				var sprite = Sprite2D.new()
				sprite.texture = tile_dark if (gx + gy) % 2 == 0 else tile_light
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


func _on_snapshot_loaded() -> void:
	if _snapshot_processed:
		for worker_id in WorldState.workers:
			if not agent_nodes.has(worker_id):
				_spawn_agent(worker_id)
		return

	_snapshot_processed = true
	_build_from_snapshot()

	# Distribute jobs to stations for queue visuals
	_distribute_jobs()

	# Tell job delivery system where intake is
	if _job_delivery and _job_delivery.has_method("set_intake_position"):
		var intake_pos = nav.get_position("intake")
		if intake_pos != Vector2.ZERO:
			_job_delivery.set_intake_position(intake_pos)

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
			grid_pos = DYNAMIC_START + DYNAMIC_SPACING * dynamic_index
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


func _setup_job_delivery() -> void:
	var delivery_script = load("res://scripts/world/job_delivery.gd")
	if delivery_script:
		_job_delivery = Node2D.new()
		_job_delivery.name = "JobDelivery"
		_job_delivery.set_script(delivery_script)
		add_child(_job_delivery)


func _on_station_changed(_station_id: String) -> void:
	pass


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
