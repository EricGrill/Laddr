extends Node
## Moves the parent CharacterBody2D along a list of waypoint positions.
## Uses move_and_slide() for collision-aware movement (like the Godot isometric demo).
## Emits arrived signal when the final waypoint is reached.
## Exposes velocity_direction for 8-directional animation.

signal arrived()

@export var base_speed: float = 160.0  # Same as Godot iso demo

var _path: Array = []  # Array of Vector2 screen positions
var _current_waypoint_index: int = 0
var _moving: bool = false
var speed_multiplier: float = 1.0
var velocity_direction: Vector2 = Vector2.ZERO  # For animator to read

var _body: CharacterBody2D


func _ready() -> void:
	_body = get_parent() as CharacterBody2D
	EventBus.playback_speed_changed.connect(func(speed): speed_multiplier = speed)


func start_path(waypoints: Array) -> void:
	if waypoints.is_empty():
		arrived.emit()
		return
	_path = waypoints
	_current_waypoint_index = 0
	_moving = true


func stop() -> void:
	_moving = false
	_path.clear()
	velocity_direction = Vector2.ZERO
	if _body:
		_body.velocity = Vector2.ZERO


func is_moving() -> bool:
	return _moving


func _physics_process(delta: float) -> void:
	if not _body or not _moving or _path.is_empty():
		if _body:
			_body.velocity = Vector2.ZERO
			velocity_direction = Vector2.ZERO
		return

	var target = _path[_current_waypoint_index]
	var direction = target - _body.position
	var distance = direction.length()

	if distance < 5.0:
		_body.position = target
		_current_waypoint_index += 1
		if _current_waypoint_index >= _path.size():
			_moving = false
			_path.clear()
			_body.velocity = Vector2.ZERO
			velocity_direction = Vector2.ZERO
			arrived.emit()
		return

	# Compute velocity — straight orthogonal movement (no iso compensation)
	var motion = direction.normalized()
	velocity_direction = motion  # Raw direction for animation
	motion = motion * base_speed * speed_multiplier

	_body.velocity = motion
	_body.move_and_slide()
