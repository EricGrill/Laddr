extends Node2D
## Reads office_layout.json and spawns stations, waypoints, and nav graph.
## Attach this to a Node2D in main.tscn.

const LAYOUT_PATH = "res://data/office_layout.json"
const STATION_TYPES_PATH = "res://data/station_types.json"

var iso: IsometricUtils = IsometricUtils.new()
var nav: NavGraph = NavGraph.new()
var station_types: Dictionary = {}
var station_nodes: Dictionary = {}  # station_id -> Node2D
var agent_nodes: Dictionary = {}  # worker_id -> BlobAgent node

@export var station_scene: PackedScene


func _ready() -> void:
	add_to_group("world_builder")

	var layout = _load_json(LAYOUT_PATH)
	station_types = _load_json(STATION_TYPES_PATH)

	if layout.is_empty():
		push_error("Failed to load office layout")
		return

	iso.setup(layout["floor"]["tile_size"])
	_build_nav_graph(layout)
	_spawn_stations(layout)

	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)


func get_nav_graph() -> NavGraph:
	return nav


func get_station_screen_pos(station_id: String) -> Vector2:
	return nav.get_position(station_id)


func _build_nav_graph(layout: Dictionary) -> void:
	for station in layout["stations"]:
		var grid_pos = Vector2(station["grid_pos"][0], station["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(station["id"], screen_pos)

	for wp in layout["waypoints"]:
		var grid_pos = Vector2(wp["grid_pos"][0], wp["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(wp["id"], screen_pos)

	for path in layout["paths"]:
		var path_array: Array = []
		for id in path:
			path_array.append(id)
		nav.add_path(path_array)


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


func _on_snapshot_loaded() -> void:
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
