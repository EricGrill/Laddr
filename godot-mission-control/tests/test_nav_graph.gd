extends GutTest
## Tests for waypoint graph and pathfinding.

var nav: Object


func before_each() -> void:
	nav = load("res://scripts/world/nav_graph.gd").new()


func test_add_node_and_retrieve() -> void:
	nav.add_node("intake", Vector2(100, 50))
	assert_eq(nav.get_position("intake"), Vector2(100, 50))


func test_unknown_node_returns_zero() -> void:
	assert_eq(nav.get_position("nonexistent"), Vector2.ZERO)


func test_add_path_creates_bidirectional_edges() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "b"])
	assert_true(nav.has_edge("a", "b"))
	assert_true(nav.has_edge("b", "a"))


func test_find_path_simple() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("wp", Vector2(50, 0))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "wp", "b"])
	var path = nav.find_path("a", "b")
	assert_eq(path, [Vector2(0, 0), Vector2(50, 0), Vector2(100, 0)])


func test_find_path_no_connection_returns_empty() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("b", Vector2(100, 0))
	var path = nav.find_path("a", "b")
	assert_eq(path, [])


func test_find_path_chooses_shortest() -> void:
	nav.add_node("a", Vector2(0, 0))
	nav.add_node("wp1", Vector2(50, 0))
	nav.add_node("wp2", Vector2(200, 200))
	nav.add_node("b", Vector2(100, 0))
	nav.add_path(["a", "wp1", "b"])
	nav.add_path(["a", "wp2", "b"])
	var path = nav.find_path("a", "b")
	assert_eq(path[1], Vector2(50, 0))
