class_name NavGraph
extends RefCounted
## Weighted graph over waypoints and stations.
## Agents ask for a path from station A to station B.
## Uses Dijkstra's algorithm for shortest path.

# node_id -> Vector2 (screen position)
var _positions: Dictionary = {}
# node_id -> Array[{neighbor: String, weight: float}]
var _edges: Dictionary = {}
# "from_id→to_id" -> Array[Vector2] cached result
var _path_cache: Dictionary = {}


func add_node(id: String, position: Vector2) -> void:
	_positions[id] = position
	if not _edges.has(id):
		_edges[id] = []


func get_position(id: String) -> Vector2:
	return _positions.get(id, Vector2.ZERO)


func has_edge(from_id: String, to_id: String) -> bool:
	if not _edges.has(from_id):
		return false
	for edge in _edges[from_id]:
		if edge["neighbor"] == to_id:
			return true
	return false


func add_path(node_ids: Array) -> void:
	for i in range(node_ids.size() - 1):
		var a = node_ids[i]
		var b = node_ids[i + 1]
		if not _positions.has(a) or not _positions.has(b):
			continue
		var weight = _positions[a].distance_to(_positions[b])
		_add_edge(a, b, weight)
		_add_edge(b, a, weight)


func find_path(from_id: String, to_id: String) -> Array:
	if not _positions.has(from_id) or not _positions.has(to_id):
		return []
	if from_id == to_id:
		return [_positions[from_id]]

	var cache_key = from_id + "→" + to_id
	if _path_cache.has(cache_key):
		return _path_cache[cache_key].duplicate()

	# Dijkstra's
	var dist: Dictionary = {}
	var prev: Dictionary = {}
	var visited: Dictionary = {}

	for node_id in _positions:
		dist[node_id] = INF
	dist[from_id] = 0.0

	while true:
		var current = ""
		var current_dist = INF
		for node_id in dist:
			if not visited.has(node_id) and dist[node_id] < current_dist:
				current = node_id
				current_dist = dist[node_id]

		if current == "" or current == to_id:
			break

		visited[current] = true

		for edge in _edges.get(current, []):
			var neighbor = edge["neighbor"]
			var new_dist = dist[current] + edge["weight"]
			if new_dist < dist[neighbor]:
				dist[neighbor] = new_dist
				prev[neighbor] = current

	if not prev.has(to_id) and from_id != to_id:
		return []

	var path_ids: Array = []
	var current = to_id
	while current != "":
		path_ids.push_front(current)
		current = prev.get(current, "")

	var path_positions: Array = []
	for id in path_ids:
		path_positions.append(_positions[id])

	_path_cache[cache_key] = path_positions.duplicate()
	return path_positions


func _add_edge(from_id: String, to_id: String, weight: float) -> void:
	if not _edges.has(from_id):
		_edges[from_id] = []
	for edge in _edges[from_id]:
		if edge["neighbor"] == to_id:
			if weight < edge["weight"]:
				edge["weight"] = weight
			return
	_edges[from_id].append({"neighbor": to_id, "weight": weight})
