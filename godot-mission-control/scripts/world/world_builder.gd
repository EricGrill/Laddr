extends Node2D
## Dynamically builds the world from backend WebSocket snapshot.
## Spawns stations, agents, and nav graph from live data.

const STATION_TYPES_PATH = "res://data/station_types.json"

var iso: IsometricUtils = IsometricUtils.new()
var nav: NavGraph = NavGraph.new()
var station_types: Dictionary = {}
var station_nodes: Dictionary = {}  # station_id -> Node2D
var agent_nodes: Dictionary = {}  # worker_id -> BlobAgent node
var _snapshot_processed: bool = false

# Grid layout for auto-positioning stations
# Fixed stations get known positions, dynamic (worker) stations fill remaining slots
const FIXED_POSITIONS = {
	"intake": Vector2(2, 3),
	"dispatcher": Vector2(6, 6),
	"supervisor": Vector2(10, 3),
	"error-chamber": Vector2(2, 9),
	"output-dock": Vector2(14, 6),
}

# Slots for dynamic worker stations (positioned in a row)
const DYNAMIC_START = Vector2(6, 10)
const DYNAMIC_SPACING = Vector2(4, 0)

const TILE_SIZE = 64


func _ready() -> void:
	add_to_group("world_builder")
	station_types = _load_json(STATION_TYPES_PATH)
	iso.setup(TILE_SIZE)

	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.station_changed.connect(_on_station_changed)
	FilterState.filters_changed.connect(_on_filters_changed)


func get_nav_graph() -> NavGraph:
	return nav


func get_station_screen_pos(station_id: String) -> Vector2:
	return nav.get_position(station_id)


func _on_snapshot_loaded() -> void:
	if _snapshot_processed:
		# Just update existing nodes on reconnect
		for worker_id in WorldState.workers:
			if not agent_nodes.has(worker_id):
				_spawn_agent(worker_id)
		return

	_snapshot_processed = true

	# Build stations from backend data
	_build_from_snapshot()

	# Spawn agents for all workers
	for worker_id in WorldState.workers:
		_spawn_agent(worker_id)


func _build_from_snapshot() -> void:
	# Clear any existing
	for sid in station_nodes:
		station_nodes[sid].queue_free()
	station_nodes.clear()
	nav = NavGraph.new()

	var dynamic_index = 0

	# Create stations from WorldState
	for station_id in WorldState.stations:
		var station_data = WorldState.stations[station_id]
		var grid_pos: Vector2

		# Fixed stations get known positions
		if FIXED_POSITIONS.has(station_id):
			grid_pos = FIXED_POSITIONS[station_id]
		else:
			# Dynamic worker stations auto-layout
			grid_pos = DYNAMIC_START + DYNAMIC_SPACING * dynamic_index
			dynamic_index += 1

		var screen_pos = iso.grid_to_screen(grid_pos)
		nav.add_node(station_id, screen_pos)
		_spawn_station(station_id, station_data, screen_pos)

	# Add waypoints for pathfinding between stations
	_add_waypoints()

	# Build paths connecting all stations through center
	_build_paths()


func _spawn_station(station_id: String, data: Dictionary, screen_pos: Vector2) -> void:
	var station_scn = load("res://scenes/stations/station.tscn")
	var node = station_scn.instantiate()
	node.position = screen_pos

	var stype = data.get("type", "code")
	var label = data.get("label", station_id)
	var capacity = data.get("capacity", 10)

	# Get visual config from station_types.json
	var type_info = station_types.get(stype, {})
	var color = Color.html(type_info.get("color", "#888888"))

	node.setup(station_id, stype, label, capacity, color)
	add_child(node)
	station_nodes[station_id] = node


func _add_waypoints() -> void:
	# Central waypoints for pathfinding
	var waypoints = {
		"wp_center": Vector2(8, 6),
		"wp_top": Vector2(8, 3),
		"wp_left": Vector2(3, 6),
		"wp_right": Vector2(13, 6),
		"wp_bottom": Vector2(8, 10),
	}
	for wp_id in waypoints:
		nav.add_node(wp_id, iso.grid_to_screen(waypoints[wp_id]))


func _build_paths() -> void:
	# Connect all stations through waypoints for pathfinding
	# Hub-and-spoke: everything connects through center
	var center_connections = {
		"intake": ["wp_left", "wp_center"],
		"dispatcher": ["wp_center"],
		"supervisor": ["wp_top", "wp_center"],
		"error-chamber": ["wp_left", "wp_bottom"],
		"output-dock": ["wp_right", "wp_center"],
	}

	# Fixed station paths
	for station_id in center_connections:
		if nav.get_position(station_id) != Vector2.ZERO:
			var path = [station_id] + center_connections[station_id]
			nav.add_path(path)

	# Dynamic stations connect through bottom waypoint
	for station_id in WorldState.stations:
		if not FIXED_POSITIONS.has(station_id):
			if nav.get_position(station_id) != Vector2.ZERO:
				nav.add_path([station_id, "wp_bottom", "wp_center"])

	# Connect waypoints to each other
	nav.add_path(["wp_left", "wp_center", "wp_right"])
	nav.add_path(["wp_top", "wp_center", "wp_bottom"])


func _on_station_changed(station_id: String) -> void:
	# Station data updated from backend — node updates itself via its own signal handler
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
		Color.html("#d4836b"),  # terracotta
		Color.html("#e8a87c"),  # warm orange
		Color.html("#f0c8a0"),  # soft peach
		Color.html("#c97b7b"),  # dusty rose
		Color.html("#d4a574"),  # sandy
		Color.html("#b07d62"),  # deep clay
	]
	var color_index = worker_id.hash() % colors.size()
	agent.setup(worker_id, nav, colors[color_index])

	# Position agent at their worker station if it exists, otherwise intake
	var worker_station_id = "station-" + worker_id
	var start_pos = nav.get_position(worker_station_id)
	if start_pos == Vector2.ZERO:
		start_pos = nav.get_position("intake")
	if start_pos == Vector2.ZERO:
		# Fallback: center of screen
		start_pos = iso.grid_to_screen(Vector2(8, 6))
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
