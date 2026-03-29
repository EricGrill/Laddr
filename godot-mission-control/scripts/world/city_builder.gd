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
	"docks": {"text": "THE DOCKS", "color": Color(0.91, 0.66, 0.49), "pos": Vector2(-560, -320)},
	"downtown": {"text": "DOWNTOWN", "color": Color(0.2, 1.0, 1.0), "pos": Vector2(0, -320)},
	"shipyard": {"text": "SHIPYARD", "color": Color(0.51, 0.88, 0.67), "pos": Vector2(500, -320)},
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
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.job_completed.connect(_on_job_completed)


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
	bg.size = Vector2(1600, 800)
	bg.position = Vector2(-800, -400)
	bg.color = Color(0.02, 0.02, 0.05, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _draw_roads() -> void:
	var road_layer = Node2D.new()
	road_layer.name = "RoadLayer"
	road_layer.z_index = -5
	add_child(road_layer)

	# --- Main boulevard: 1280×24 centered at origin (y=0) ---
	var blvd = ColorRect.new()
	blvd.size = Vector2(1280, 24)
	blvd.position = Vector2(-640, -12)
	blvd.color = Color(0.06, 0.06, 0.10, 1.0)
	blvd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(blvd)

	# Cyan edge glow — top
	var glow_top = ColorRect.new()
	glow_top.size = Vector2(1280, 2)
	glow_top.position = Vector2(-640, -12)
	glow_top.color = Color(0.0, 1.0, 1.0, 0.15)
	glow_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(glow_top)

	# Cyan edge glow — bottom
	var glow_bot = ColorRect.new()
	glow_bot.size = Vector2(1280, 2)
	glow_bot.position = Vector2(-640, 10)
	glow_bot.color = Color(0.0, 1.0, 1.0, 0.15)
	glow_bot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road_layer.add_child(glow_bot)

	# Dashed yellow center line
	var dash_w = 24
	var dash_gap = 12
	var x = -640
	while x < 640:
		var dash = ColorRect.new()
		dash.size = Vector2(dash_w, 2)
		dash.position = Vector2(x, -1)
		dash.color = Color(1.0, 0.9, 0.2, 0.55)
		dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		road_layer.add_child(dash)
		x += dash_w + dash_gap

	# --- 4 side streets: vertical rects 12px wide, from y=-220 to y=220 ---
	var side_street_xs = [-500, -220, 220, 440]
	for sx in side_street_xs:
		var street = ColorRect.new()
		street.size = Vector2(12, 520)
		street.position = Vector2(sx - 6, -260)
		street.color = Color(0.06, 0.06, 0.10, 1.0)
		street.mouse_filter = Control.MOUSE_FILTER_IGNORE
		road_layer.add_child(street)

		# Subtle left/right edge glow
		for edge_offset in [-6, 6]:
			var edge = ColorRect.new()
			edge.size = Vector2(1, 520)
			edge.position = Vector2(sx + edge_offset - 1, -260)
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
	# Collect worker stations and sort for consistent ordering
	var worker_stations: Array[String] = []
	for station_id in WorldState.stations:
		if GRID_STATIONS.has(station_id):
			continue
		if not station_id.begins_with("station-"):
			continue
		worker_stations.append(station_id)
	worker_stations.sort()

	# Position worker stations in a vertical column on the right side
	var base_pos = roads.get_position("output-dock")
	if base_pos == Vector2.ZERO:
		base_pos = Vector2(420, -160)
	var start_x = base_pos.x + 180  # Right of the output dock
	var start_y = -200

	for i in worker_stations.size():
		var station_id = worker_stations[i]
		var worker_pos = Vector2(start_x, start_y + i * 180)
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
	if intake_pos != Vector2.ZERO:
		_triage_droid.position = intake_pos + Vector2(30, 50)
	else:
		_triage_droid.position = Vector2(-540, 50)
	_triage_droid.scale = Vector2(0.7, 0.7)
	_triage_droid.z_index = 10
	add_child(_triage_droid)
	# Tell droid where to walk
	if _triage_droid.has_method("set_stations"):
		_triage_droid.set_stations(intake_pos, dispatch_pos)


# ---------------------------------------------------------------------------
# Agent / citizen spawning
# ---------------------------------------------------------------------------

var _worker_home_panels: Dictionary = {}  # worker_id -> Node2D (info panel)
var _worker_home_index: int = 0

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

	# Position at worker's home station
	var worker_station_id = "station-" + worker_id
	var start_pos = roads.get_position(worker_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = roads.get_position("research")
	if start_pos == Vector2.ZERO:
		start_pos = Vector2(-120, -160)
	citizen.position = start_pos

	add_child(citizen)
	agent_nodes[worker_id] = citizen

	# Create home info panel for this worker
	_create_worker_home(worker_id, start_pos)


func _create_worker_home(worker_id: String, pos: Vector2) -> void:
	var panel = Node2D.new()
	panel.position = pos + Vector2(0, 40)
	panel.z_index = 8

	# Background card — taller to hold job blocks
	var bg = ColorRect.new()
	bg.name = "CardBG"
	bg.size = Vector2(160, 120)
	bg.position = Vector2(-80, 0)
	bg.color = Color(0.04, 0.06, 0.10, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	# Top border accent
	var border = ColorRect.new()
	border.size = Vector2(160, 2)
	border.position = Vector2(-80, 0)
	border.color = Color(0.2, 0.85, 0.95, 0.6)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(border)

	# Worker name
	var name_lbl = Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.size = Vector2(152, 18)
	name_lbl.position = Vector2(-76, 4)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ns = LabelSettings.new()
	ns.font_size = 11
	ns.font_color = Color(0.3, 0.95, 1.0, 1.0)
	ns.outline_size = 1
	ns.outline_color = Color(0, 0, 0, 0.6)
	name_lbl.label_settings = ns
	panel.add_child(name_lbl)

	# Model line
	var info_lbl = Label.new()
	info_lbl.name = "InfoLabel"
	info_lbl.size = Vector2(152, 14)
	info_lbl.position = Vector2(-76, 22)
	info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var is_ = LabelSettings.new()
	is_.font_size = 8
	is_.font_color = Color(0.6, 0.65, 0.7, 0.9)
	is_.outline_size = 1
	is_.outline_color = Color(0, 0, 0, 0.5)
	info_lbl.label_settings = is_
	panel.add_child(info_lbl)

	# Status line
	var status_lbl = Label.new()
	status_lbl.name = "StatusLabel"
	status_lbl.size = Vector2(152, 14)
	status_lbl.position = Vector2(-76, 36)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ss = LabelSettings.new()
	ss.font_size = 8
	ss.font_color = Color(0.4, 0.8, 0.5, 0.9)
	ss.outline_size = 1
	ss.outline_color = Color(0, 0, 0, 0.5)
	status_lbl.label_settings = ss
	panel.add_child(status_lbl)

	# Job blocks container
	var job_container = Node2D.new()
	job_container.name = "JobBlocks"
	job_container.position = Vector2(0, 54)
	panel.add_child(job_container)

	add_child(panel)
	_worker_home_panels[worker_id] = panel
	_update_worker_home(worker_id)


func _update_worker_home(worker_id: String) -> void:
	if not _worker_home_panels.has(worker_id):
		return
	var panel = _worker_home_panels[worker_id]
	var worker_data = WorldState.workers.get(worker_id, {})
	var name_lbl = panel.get_node_or_null("NameLabel")
	var info_lbl = panel.get_node_or_null("InfoLabel")
	var status_lbl = panel.get_node_or_null("StatusLabel")
	var job_container = panel.get_node_or_null("JobBlocks")

	# Worker display name
	if name_lbl:
		name_lbl.text = worker_data.get("name", worker_id.left(12))

	# Extract primary model
	if info_lbl:
		var model_name = ""
		var caps = worker_data.get("capabilities", [])
		for cap in caps:
			var cap_str = ""
			if cap is Dictionary:
				cap_str = str(cap.get("id", ""))
			else:
				cap_str = str(cap)
			var c = cap_str.to_lower()
			if "embed" in c:
				continue
			if "gpt" in c or "claude" in c or "llama" in c or "gemini" in c or "mistral" in c or "qwen" in c or "deepseek" in c or "gemma" in c or "nemotron" in c:
				for prefix in ["openai/", "anthropic/", "google/", "meta/", "mistralai/", "qwen/", "deepseek-ai/", "nvidia/"]:
					cap_str = cap_str.replace(prefix, "")
				model_name = cap_str.left(20)
				break
		info_lbl.text = model_name if model_name != "" else "no model"

	# Status + jobs/hr
	if status_lbl:
		var active = worker_data.get("activeJobs", 0)
		var completed_hr = worker_data.get("completedLastHour", 0)
		var status = worker_data.get("status", "online")
		if active > 0:
			status_lbl.text = "%d active | %d/hr" % [active, completed_hr]
			status_lbl.label_settings.font_color = Color(0.2, 0.85, 0.95, 0.9)
		elif status == "working":
			status_lbl.text = "working | %d/hr" % completed_hr
			status_lbl.label_settings.font_color = Color(0.4, 0.8, 0.5, 0.9)
		else:
			status_lbl.text = "idle | %d/hr" % completed_hr
			status_lbl.label_settings.font_color = Color(0.5, 0.5, 0.55, 0.7)

	# Build job blocks — show assigned/processing jobs for this worker
	if job_container:
		# Clear old blocks
		for child in job_container.get_children():
			child.queue_free()

		var worker_jobs: Array = []
		var worker_station_id = "station-" + worker_id
		for jid in WorldState.jobs:
			var job = WorldState.jobs[jid]
			var job_state = job.get("state", "")
			if job_state == "completed" or job_state == "cancelled" or job_state == "failed":
				continue
			var assigned = str(job.get("assignedAgent", ""))
			var current_station = str(job.get("currentStationId", ""))
			if assigned == worker_id or current_station == worker_station_id:
				worker_jobs.append(job)
		# Limit to 4 visible blocks
		var visible_count = mini(worker_jobs.size(), 4)
		var block_h = 14
		var block_gap = 2
		var block_w = 148

		# Job type colors
		var type_colors = {
			"llm": Color(0.64, 0.48, 1.0, 0.7),
			"code": Color(0.36, 0.55, 1.0, 0.7),
			"tool": Color(0.34, 0.78, 0.71, 0.7),
			"supervisor": Color(0.85, 0.69, 0.36, 0.7),
			"review": Color(0.85, 0.69, 0.36, 0.7),
		}
		var default_color = Color(0.39, 0.84, 0.90, 0.7)

		for i in visible_count:
			var job = worker_jobs[i]
			var job_type = str(job.get("type", ""))
			var job_state = str(job.get("state", "queued"))
			var job_id = str(job.get("id", ""))
			var short_id = job_id.left(8) if job_id.length() > 8 else job_id

			var block = Node2D.new()
			block.position = Vector2(0, i * (block_h + block_gap))

			# Block background
			var block_bg = ColorRect.new()
			block_bg.size = Vector2(block_w, block_h)
			block_bg.position = Vector2(-block_w / 2.0, 0)
			block_bg.color = Color(0.08, 0.10, 0.16, 0.9)
			block_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			block.add_child(block_bg)

			# Left color accent bar
			var accent_color = type_colors.get(job_type, default_color)
			var accent_bar = ColorRect.new()
			accent_bar.size = Vector2(3, block_h)
			accent_bar.position = Vector2(-block_w / 2.0, 0)
			accent_bar.color = accent_color
			accent_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			block.add_child(accent_bar)

			# Job label
			var job_lbl = Label.new()
			job_lbl.size = Vector2(block_w - 8, block_h)
			job_lbl.position = Vector2(-block_w / 2.0 + 6, 0)
			job_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var js = LabelSettings.new()
			js.font_size = 7
			js.font_color = Color(0.8, 0.82, 0.85, 0.9)
			js.outline_size = 1
			js.outline_color = Color(0, 0, 0, 0.5)
			job_lbl.label_settings = js
			# Show type + short ID + state
			var display_type = job_type.left(10) if job_type.length() > 10 else job_type
			job_lbl.text = "%s  %s  %s" % [display_type, short_id, job_state]
			block.add_child(job_lbl)

			job_container.add_child(block)

		# Resize card background to fit job blocks
		var card_bg = panel.get_node_or_null("CardBG")
		if card_bg:
			var base_height = 56
			var jobs_height = visible_count * (block_h + block_gap)
			card_bg.size.y = base_height + jobs_height + 8


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
	# Include worker cards on the right (extends ~200px past output-dock)
	var city_w = 1600.0
	var city_h = 900.0
	# Shift center slightly right to account for worker panel
	var center = Vector2(80.0, 0.0)

	var viewport_size = get_viewport().get_visible_rect().size
	var padding = 20.0
	var zoom_x = viewport_size.x / (city_w + padding)
	var zoom_y = viewport_size.y / (city_h + padding)
	var fit_zoom = min(zoom_x, zoom_y)
	fit_zoom = clamp(fit_zoom, 0.3, 2.5)

	var camera = get_parent().get_node_or_null("Camera")
	if camera:
		camera.global_position = center
		camera.zoom = Vector2(fit_zoom, fit_zoom)
		camera._target_position = center
		camera._target_zoom = Vector2(fit_zoom, fit_zoom)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_metrics_changed() -> void:
	for wid in _worker_home_panels:
		_update_worker_home(wid)


func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new:
		_spawn_agent(worker_id)
	else:
		_update_worker_home(worker_id)


func _on_job_changed(_job_id: String) -> void:
	for wid in _worker_home_panels:
		_update_worker_home(wid)


func _on_job_completed(_job_id: String) -> void:
	for wid in _worker_home_panels:
		_update_worker_home(wid)


func _on_worker_removed(worker_id: String) -> void:
	if _worker_home_panels.has(worker_id):
		_worker_home_panels[worker_id].queue_free()
		_worker_home_panels.erase(worker_id)
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
