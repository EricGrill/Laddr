extends Node2D
## CityBuilder — orchestrates the Daystrom City cyberpunk mission control scene.
## Builds the city from backend WebSocket data via WorldState signals.
## Replaces grid_builder.gd as the primary world orchestrator.

const STATION_TYPES_PATH = "res://data/station_types.json"

# Station order — fixed building positions in the city
const GRID_STATIONS = [
	"intake", "dispatcher", "research", "code",
	"review", "supervisor", "output-dock", "error-chamber",
]

# Map dynamic worker station types to their parent building in the road graph
const TYPE_TO_GRID_CELL = {
	"llm": "research",
	"tool": "code",
	"research": "research",
	"code": "code",
	"review": "review",
}

const DISTRICT_LABELS = {
	"docks": {"text": "THE DOCKS", "color": Color(0.91, 0.66, 0.49), "pos": Vector2(-480, -220)},
	"downtown": {"text": "DOWNTOWN", "color": Color(0.2, 1.0, 1.0), "pos": Vector2(0, -220)},
	"shipyard": {"text": "SHIPYARD", "color": Color(0.51, 0.88, 0.67), "pos": Vector2(420, -220)},
}

var roads: RoadSystem = RoadSystem.new()
var station_types: Dictionary = {}
var station_nodes: Dictionary = {}   # station_id -> Node2D (building)
var agent_nodes: Dictionary = {}     # worker_id -> BlobAgent node
var _snapshot_processed: bool = false
var _camera: Camera2D = null
var _job_delivery: Node2D = null
var _sidious: Node2D = null
var _triage_droid: Node2D = null
var _suppress_reactions: bool = false
var _overflow_active: bool = false
var _worker_dock_counts: Dictionary = {}  # parent_station_id -> int


func _ready() -> void:
	add_to_group("world_builder")
	station_types = _load_json(STATION_TYPES_PATH)
	_camera = get_parent().get_node_or_null("Camera")

	_draw_city_background()
	_draw_roads()
	_draw_district_labels()
	_setup_job_delivery()

	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)


# ---------------------------------------------------------------------------
# Compatibility interface
# ---------------------------------------------------------------------------

func get_nav_graph() -> RoadSystem:
	return roads


func get_station_screen_pos(station_id: String) -> Vector2:
	return roads.get_position(station_id)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw_city_background() -> void:
	var bg = ColorRect.new()
	bg.name = "CityBackground"
	bg.z_index = -10
	bg.size = Vector2(1400, 600)
	bg.position = Vector2(-700, -300)
	bg.color = Color(0.02, 0.02, 0.05, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _draw_roads() -> void:
	var road_layer = Node2D.new()
	road_layer.name = "RoadLayer"
	road_layer.z_index = -5
	add_child(road_layer)

	# --- Main boulevard: 1080×24 centered at origin (y=0) ---
	var blvd = ColorRect.new()
	blvd.size = Vector2(1080, 24)
	blvd.position = Vector2(-540, -12)
	blvd.color = Color(0.06, 0.06, 0.10, 1.0)
	blvd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(blvd)

	# Cyan edge glow — top
	var glow_top = ColorRect.new()
	glow_top.size = Vector2(1080, 2)
	glow_top.position = Vector2(-540, -12)
	glow_top.color = Color(0.0, 1.0, 1.0, 0.15)
	glow_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(glow_top)

	# Cyan edge glow — bottom
	var glow_bot = ColorRect.new()
	glow_bot.size = Vector2(1080, 2)
	glow_bot.position = Vector2(-540, 10)
	glow_bot.color = Color(0.0, 1.0, 1.0, 0.15)
	glow_bot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(glow_bot)

	# Dashed yellow center line
	var dash_w = 24
	var dash_gap = 12
	var x = -540
	while x < 540:
		var dash = ColorRect.new()
		dash.size = Vector2(dash_w, 2)
		dash.position = Vector2(x, -1)
		dash.color = Color(1.0, 0.9, 0.2, 0.55)
		dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		road_layer.add_child(dash)
		x += dash_w + dash_gap

	# --- 4 side streets: vertical rects 12px wide, from y=-180 to y=180 ---
	var side_street_xs = [-420, -180, 180, 360]
	for sx in side_street_xs:
		var street = ColorRect.new()
		street.size = Vector2(12, 360)
		street.position = Vector2(sx - 6, -180)
		street.color = Color(0.06, 0.06, 0.10, 1.0)
		street.mouse_filter = Control.MOUSE_FILTER_IGNORE
		road_layer.add_child(street)

		# Subtle left/right edge glow
		for edge_offset in [-6, 6]:
			var edge = ColorRect.new()
			edge.size = Vector2(1, 360)
			edge.position = Vector2(sx + edge_offset - 1, -180)
			edge.color = Color(0.0, 1.0, 1.0, 0.10)
			edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			road_layer.add_child(edge)


func _draw_district_labels() -> void:
	var label_layer = Node2D.new()
	label_layer.name = "DistrictLabels"
	label_layer.z_index = 5
	add_child(label_layer)

	for key in DISTRICT_LABELS:
		var info = DISTRICT_LABELS[key]
		var lbl = Label.new()
		lbl.text = info["text"]
		lbl.position = info["pos"]
		var ls = LabelSettings.new()
		ls.font_size = 9
		ls.font_color = info["color"]
		ls.outline_size = 1
		ls.outline_color = Color(0, 0, 0, 0.8)
		lbl.label_settings = ls
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.size = Vector2(120, 20)
		lbl.position = info["pos"] - Vector2(60, 0)
		label_layer.add_child(lbl)


# ---------------------------------------------------------------------------
# Job delivery setup
# ---------------------------------------------------------------------------

func _setup_job_delivery() -> void:
	var delivery_script = load("res://scripts/world/job_delivery.gd")
	if delivery_script:
		_job_delivery = Node2D.new()
		_job_delivery.name = "JobDelivery"
		_job_delivery.set_script(delivery_script)
		add_child(_job_delivery)


# ---------------------------------------------------------------------------
# Snapshot / build
# ---------------------------------------------------------------------------

func _on_snapshot_loaded() -> void:
	if _snapshot_processed:
		# Just spawn any new workers that arrived since last snapshot
		for worker_id in WorldState.workers:
			if not agent_nodes.has(worker_id):
				_spawn_agent(worker_id)
		return

	_snapshot_processed = true
	_build_from_snapshot()

	_suppress_reactions = true
	_distribute_jobs()
	_suppress_reactions = false

	# Tell job delivery where intake is
	if _job_delivery and _job_delivery.has_method("set_intake_position"):
		var intake_pos = roads.get_position("intake")
		if intake_pos != Vector2.ZERO:
			_job_delivery.set_intake_position(intake_pos)

	_spawn_sidious()
	_spawn_triage_droid()

	for worker_id in WorldState.workers:
		_spawn_agent(worker_id)

	_auto_fit_camera()


func _build_from_snapshot() -> void:
	# Clean up any previously built nodes
	for sid in station_nodes:
		station_nodes[sid].queue_free()
	station_nodes.clear()
	_worker_dock_counts.clear()

	# Place the 8 fixed station buildings
	for station_id in GRID_STATIONS:
		var pos = roads.get_building_position(station_id)
		if pos == Vector2.ZERO:
			push_warning("CityBuilder: no road position for station '%s'" % station_id)
			continue

		var station_data = _find_station_data(station_id)
		if station_data.is_empty():
			# Create placeholder from station_types.json for stations without backend data
			var type_key = _type_key_for_station(station_id)
			var type_info = station_types.get(type_key, {})
			station_data = {
				"type": type_key,
				"label": type_info.get("label", station_id.capitalize()),
				"capacity": 10,
				"queueDepth": 0,
				"activeJobIds": [],
				"workerId": null,
			}

		_spawn_building(station_id, station_data, pos)

	# Register dynamic worker stations in the road graph
	_register_worker_stations()


func _type_key_for_station(station_id: String) -> String:
	# Map station IDs to station_types.json keys
	match station_id:
		"output-dock":
			return "output"
		"error-chamber":
			return "error"
		_:
			return station_id


func _find_station_data(station_id: String) -> Dictionary:
	if WorldState.stations.has(station_id):
		return WorldState.stations[station_id]
	# Try alternate names (e.g. backend may use "router" for "dispatcher")
	for sid in WorldState.stations:
		var data = WorldState.stations[sid]
		if data.get("type", "") == station_id:
			return data
	return {}


func _spawn_building(station_id: String, data: Dictionary, pos: Vector2) -> void:
	var building_scn = load("res://scenes/world/building.tscn")
	if not building_scn:
		push_error("CityBuilder: could not load building.tscn")
		return
	var node = building_scn.instantiate()
	node.position = pos

	var stype = data.get("type", _type_key_for_station(station_id))
	var lbl = data.get("label", station_id.capitalize())
	var cap = data.get("capacity", 10)
	var type_info = station_types.get(stype, {})
	var color = Color.html(type_info.get("color", "#888888"))

	node.setup(station_id, stype, lbl, cap, color)
	add_child(node)
	station_nodes[station_id] = node


func _register_worker_stations() -> void:
	for station_id in WorldState.stations:
		# Skip stations already placed as fixed buildings
		if GRID_STATIONS.has(station_id):
			continue
		# Only handle worker stations: "station-<workerId>"
		if not station_id.begins_with("station-"):
			continue

		var data = WorldState.stations[station_id]
		var worker_type = data.get("type", "")
		var parent_id = TYPE_TO_GRID_CELL.get(worker_type, "research")
		var parent_pos = roads.get_position(parent_id)
		if parent_pos == Vector2.ZERO:
			parent_pos = roads.get_position("research")

		# Stack workers within their parent building area
		var dock_idx = _worker_dock_counts.get(parent_id, 0)
		_worker_dock_counts[parent_id] = dock_idx + 1
		var offset = Vector2(
			-40 + (dock_idx % 3) * 40,
			60 + (dock_idx / 3) * 40,
		)
		var worker_pos = parent_pos + offset
		roads._positions[station_id] = worker_pos


# ---------------------------------------------------------------------------
# Special agents
# ---------------------------------------------------------------------------

func _spawn_sidious() -> void:
	var script = load("res://scripts/agents/sidious_controller.gd")
	if not script:
		return
	_sidious = Node2D.new()
	_sidious.name = "Sidious"
	_sidious.set_script(script)
	var cmd_pos = roads.get_position("supervisor")
	_sidious.position = cmd_pos + Vector2(60, -40) if cmd_pos != Vector2.ZERO else Vector2(180, -40)
	_sidious.z_index = 10
	add_child(_sidious)


func _spawn_triage_droid() -> void:
	var script = load("res://scripts/agents/triage_controller.gd")
	if not script:
		return
	_triage_droid = Node2D.new()
	_triage_droid.name = "TriageDroid"
	_triage_droid.set_script(script)
	var intake_pos = roads.get_position("intake")
	var dispatch_pos = roads.get_position("dispatcher")
	if intake_pos != Vector2.ZERO and dispatch_pos != Vector2.ZERO:
		_triage_droid.position = (intake_pos + dispatch_pos) / 2 + Vector2(0, -15)
	else:
		_triage_droid.position = Vector2(-480, 0)
	_triage_droid.z_index = 10
	add_child(_triage_droid)


# ---------------------------------------------------------------------------
# Agent / citizen spawning
# ---------------------------------------------------------------------------

func _spawn_agent(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		return
	var agent_scn = load("res://scenes/agents/blob_agent.tscn")
	if not agent_scn:
		return
	var citizen = agent_scn.instantiate()

	var colors = [
		Color.html("#d4836b"), Color.html("#e8a87c"), Color.html("#f0c8a0"),
		Color.html("#c97b7b"), Color.html("#d4a574"), Color.html("#b07d62"),
	]
	var color_index = worker_id.hash() % colors.size()
	citizen.setup(worker_id, roads, colors[color_index])

	# Position at worker's station, or fall back to research building
	var worker_station_id = "station-" + worker_id
	var start_pos = roads.get_position(worker_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = roads.get_position("research")
	if start_pos == Vector2.ZERO:
		start_pos = Vector2(-120, -120)
	citizen.position = start_pos

	add_child(citizen)
	agent_nodes[worker_id] = citizen


# ---------------------------------------------------------------------------
# Job distribution (mirrors grid_builder logic)
# ---------------------------------------------------------------------------

func _distribute_jobs() -> void:
	var station_jobs: Dictionary = {}
	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var job_state = job.get("state", "queued")
		var current_station = job.get("currentStationId", "")

		if current_station != null and current_station != "" and WorldState.stations.has(current_station):
			if not station_jobs.has(current_station):
				station_jobs[current_station] = []
			station_jobs[current_station].append(jid)
			continue

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

	for sid in station_jobs:
		if WorldState.stations.has(sid):
			WorldState.stations[sid]["activeJobIds"] = station_jobs[sid]
			WorldState.stations[sid]["queueDepth"] = station_jobs[sid].size()
			WorldState.station_changed.emit(sid)


# ---------------------------------------------------------------------------
# Camera auto-fit
# ---------------------------------------------------------------------------

func _auto_fit_camera() -> void:
	var city_w = 1400.0
	var city_h = 700.0
	var center = Vector2(0.0, 0.0)

	var viewport_size = get_viewport().get_visible_rect().size
	var padding = 80.0
	var zoom_x = viewport_size.x / (city_w + padding)
	var zoom_y = viewport_size.y / (city_h + padding)
	var fit_zoom = min(zoom_x, zoom_y)
	fit_zoom = clamp(fit_zoom, 0.3, 1.5)

	var camera = get_parent().get_node_or_null("Camera")
	if camera:
		camera.global_position = center
		camera.zoom = Vector2(fit_zoom, fit_zoom)
		camera._target_position = center
		camera._target_zoom = Vector2(fit_zoom, fit_zoom)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new:
		_spawn_agent(worker_id)


func _on_worker_removed(worker_id: String) -> void:
	if agent_nodes.has(worker_id):
		agent_nodes[worker_id].queue_free()
		agent_nodes.erase(worker_id)
		_react_to_event(0.02, 2.0, 0.12, 0.2)


func _react_to_event(zoom_delta: float, shake_strength: float, duration: float, _emphasis: float) -> void:
	if _camera and _camera.has_method("pulse_attention"):
		_camera.call("pulse_attention", zoom_delta, shake_strength, duration)


# ---------------------------------------------------------------------------
# JSON loader
# ---------------------------------------------------------------------------

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("CityBuilder: file not found: %s" % path)
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	var text = file.get_as_text()
	file.close()
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_error("CityBuilder: JSON parse error in %s: %s" % [path, json.get_error_message()])
		return {}
	return json.data
