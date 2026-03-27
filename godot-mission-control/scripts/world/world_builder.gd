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
	for station_data in layout["stations"]:
		var grid_pos = Vector2(station_data["grid_pos"][0], station_data["grid_pos"][1])
		var screen_pos = iso.grid_to_screen(grid_pos)

		# Create placeholder station node (replaced with proper scene in Task 5)
		var node = Node2D.new()
		node.name = station_data["id"]
		node.position = screen_pos

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

		var type_info = station_types.get(station_data["type"], {})
		var color_hex = type_info.get("color", "#888888")
		var draw_node = ColorRect.new()
		draw_node.color = Color.html(color_hex)
		draw_node.size = Vector2(48, 32)
		draw_node.position = Vector2(-24, -16)
		node.add_child(draw_node)

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
	# Placeholder for Task 6 - will load blob_agent.tscn
	var agent = Node2D.new()
	agent.name = "agent_" + worker_id.left(8)

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
