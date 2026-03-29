class_name RoadSystem
extends RefCounted
## Daystrom City road grid — intersection nodes connected by road segments.
## Three districts along a main boulevard: Docks (left), Downtown (center), Shipyard (right).
## Provides Dijkstra pathfinding for vehicles (road centerline) and agents (sidewalk offset).

const SIDEWALK_OFFSET := 20.0

## node_id -> Vector2 (world-space position, origin at center)
var _positions: Dictionary = {}
## node_id -> Array[{neighbor: String, weight: float}]
var _edges: Dictionary = {}
## "from_id→to_id" -> Array[Vector2] cached result
var _path_cache: Dictionary = {}

## Building station id -> nearest road intersection id
var _building_to_node: Dictionary = {}


func _init() -> void:
	_build_road_grid()


## Build the static road grid: intersections, boulevard, side streets, building stubs.
func _build_road_grid() -> void:
	# --- Boulevard (y = 0, horizontal spine) ---
	_add_node("blvd_w",    Vector2(-640,   0))
	_add_node("blvd_docks",Vector2(-500,   0))
	_add_node("blvd_dt_w", Vector2(-220,   0))
	_add_node("blvd_dt_c", Vector2(   0,   0))
	_add_node("blvd_dt_e", Vector2( 220,   0))
	_add_node("blvd_ship", Vector2( 440,   0))
	_add_node("blvd_e",    Vector2( 640,   0))

	# --- Side street intersections ---
	_add_node("dock_n",  Vector2(-500, -260))
	_add_node("dock_s",  Vector2(-500,  260))
	_add_node("dt_w_n",  Vector2(-220, -260))
	_add_node("dt_w_s",  Vector2(-220,  260))
	_add_node("dt_e_n",  Vector2( 220, -260))
	_add_node("dt_e_s",  Vector2( 220,  260))
	_add_node("ship_n",  Vector2( 440, -260))
	_add_node("ship_s",  Vector2( 440,  260))

	# --- Building entrance nodes ---
	_add_node("intake",         Vector2(-560, -200))
	_add_node("dispatcher",     Vector2(-560,  200))
	_add_node("research",       Vector2(-160, -200))
	_add_node("code",           Vector2( 160, -200))
	_add_node("review",         Vector2(-160,  200))
	_add_node("supervisor",     Vector2( 160,  200))
	_add_node("output-dock",    Vector2( 500, -200))
	_add_node("error-chamber",  Vector2( 500,  200))

	# --- Boulevard connections ---
	_connect("blvd_w",    "blvd_docks")
	_connect("blvd_docks","blvd_dt_w")
	_connect("blvd_dt_w", "blvd_dt_c")
	_connect("blvd_dt_c", "blvd_dt_e")
	_connect("blvd_dt_e", "blvd_ship")
	_connect("blvd_ship", "blvd_e")

	# --- Side street connections (vertical spurs off boulevard) ---
	_connect("dock_n",  "blvd_docks")
	_connect("blvd_docks", "dock_s")
	_connect("dt_w_n",  "blvd_dt_w")
	_connect("blvd_dt_w", "dt_w_s")
	_connect("dt_e_n",  "blvd_dt_e")
	_connect("blvd_dt_e", "dt_e_s")
	_connect("ship_n",  "blvd_ship")
	_connect("blvd_ship", "ship_s")

	# --- Building stub connections ---
	_connect("intake",        "dock_n")
	_connect("dispatcher",    "dock_s")
	_connect("research",      "dt_w_n")
	_connect("code",          "dt_e_n")
	_connect("review",        "dt_w_s")
	_connect("supervisor",    "dt_e_s")
	_connect("output-dock",   "ship_n")
	_connect("error-chamber", "ship_s")

	# --- Building -> nearest node mapping (for get_building_position callers) ---
	_building_to_node = {
		"intake":         "intake",
		"dispatcher":     "dispatcher",
		"research":       "research",
		"code":           "code",
		"review":         "review",
		"supervisor":     "supervisor",
		"output-dock":    "output-dock",
		"error-chamber":  "error-chamber",
	}


## Return the world-space position of a road intersection node.
func get_position(node_id: String) -> Vector2:
	return _positions.get(node_id, Vector2.ZERO)


## Return the world-space center of a named building/station.
## Falls back to get_position if no explicit building mapping exists.
func get_building_position(station_id: String) -> Vector2:
	var node_id: String = _building_to_node.get(station_id, station_id)
	return _positions.get(node_id, Vector2.ZERO)


## Find the shortest road-centerline path between two node IDs.
## Returns an Array[Vector2] of waypoint positions (empty if no path).
func find_path(from_id: String, to_id: String) -> Array:
	return _dijkstra(from_id, to_id, false)


## Find the shortest path between two node IDs, offset onto the sidewalk.
## Each segment is shifted SIDEWALK_OFFSET pixels perpendicular to the road direction.
func find_sidewalk_path(from_id: String, to_id: String) -> Array:
	return _dijkstra(from_id, to_id, true)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _add_node(id: String, position: Vector2) -> void:
	_positions[id] = position
	if not _edges.has(id):
		_edges[id] = []


## Add a bidirectional weighted edge between two existing nodes.
func _connect(a: String, b: String) -> void:
	if not _positions.has(a) or not _positions.has(b):
		push_warning("RoadSystem: cannot connect unknown nodes '%s' <-> '%s'" % [a, b])
		return
	var weight: float = _positions[a].distance_to(_positions[b])
	_add_edge(a, b, weight)
	_add_edge(b, a, weight)


func _add_edge(from_id: String, to_id: String, weight: float) -> void:
	if not _edges.has(from_id):
		_edges[from_id] = []
	for edge in _edges[from_id]:
		if edge["neighbor"] == to_id:
			if weight < edge["weight"]:
				edge["weight"] = weight
			return
	_edges[from_id].append({"neighbor": to_id, "weight": weight})


## Core Dijkstra implementation shared by find_path and find_sidewalk_path.
func _dijkstra(from_id: String, to_id: String, sidewalk: bool) -> Array:
	if not _positions.has(from_id) or not _positions.has(to_id):
		return []
	if from_id == to_id:
		return [_positions[from_id]]

	var cache_key: String = from_id + ("~sw~" if sidewalk else "→") + to_id
	if _path_cache.has(cache_key):
		return _path_cache[cache_key].duplicate()

	var dist: Dictionary = {}
	var prev: Dictionary = {}
	var visited: Dictionary = {}

	for node_id in _positions:
		dist[node_id] = INF
	dist[from_id] = 0.0

	while true:
		var current: String = ""
		var current_dist: float = INF
		for node_id in dist:
			if not visited.has(node_id) and dist[node_id] < current_dist:
				current = node_id
				current_dist = dist[node_id]

		if current == "" or current == to_id:
			break

		visited[current] = true

		for edge in _edges.get(current, []):
			var neighbor: String = edge["neighbor"]
			var new_dist: float = dist[current] + edge["weight"]
			if new_dist < dist[neighbor]:
				dist[neighbor] = new_dist
				prev[neighbor] = current

	if not prev.has(to_id) and from_id != to_id:
		return []

	# Reconstruct ordered list of node IDs
	var path_ids: Array = []
	var cursor: String = to_id
	while cursor != "":
		path_ids.push_front(cursor)
		cursor = prev.get(cursor, "")

	# Convert to Vector2 positions (optionally offset for sidewalk)
	var path_positions: Array = []
	if sidewalk:
		path_positions = _offset_path(path_ids)
	else:
		for id in path_ids:
			path_positions.append(_positions[id])

	_path_cache[cache_key] = path_positions.duplicate()
	return path_positions


## Offset each waypoint SIDEWALK_OFFSET px perpendicular to its road segment.
## The perpendicular direction is the left-hand normal of the travel direction
## so agents walk on the right side of the road.
func _offset_path(path_ids: Array) -> Array:
	if path_ids.size() == 0:
		return []
	if path_ids.size() == 1:
		return [_positions[path_ids[0]]]

	var result: Array = []
	for i in range(path_ids.size()):
		var pos: Vector2 = _positions[path_ids[i]]
		# Determine segment direction at this waypoint
		var direction: Vector2
		if i == 0:
			direction = (_positions[path_ids[1]] - pos).normalized()
		elif i == path_ids.size() - 1:
			direction = (pos - _positions[path_ids[i - 1]]).normalized()
		else:
			var d0: Vector2 = (pos - _positions[path_ids[i - 1]]).normalized()
			var d1: Vector2 = (_positions[path_ids[i + 1]] - pos).normalized()
			direction = ((d0 + d1) * 0.5).normalized()
		# Left-hand perpendicular: rotate direction 90° counter-clockwise
		var perp: Vector2 = Vector2(-direction.y, direction.x)
		result.append(pos + perp * SIDEWALK_OFFSET)

	return result
