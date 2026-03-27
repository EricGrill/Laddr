extends Camera2D
## Isometric camera with pan, zoom, and focus controls.

@export var zoom_min: float = 0.3
@export var zoom_max: float = 3.0
@export var zoom_step: float = 0.1
@export var pan_speed: float = 400.0
@export var ease_speed: float = 5.0

var _target_position: Vector2 = Vector2.ZERO
var _target_zoom: Vector2 = Vector2.ONE
var _is_panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _follow_target: Node2D = null


func _ready() -> void:
	_target_position = global_position
	_target_zoom = zoom
	EventBus.camera_focus_requested.connect(_on_focus_requested)
	EventBus.camera_reset_requested.connect(_on_reset_requested)
	EventBus.camera_follow_stopped.connect(_on_follow_stopped)


func _process(delta: float) -> void:
	# WASD panning
	var pan_input = Vector2.ZERO
	if Input.is_action_pressed("ui_left"):
		pan_input.x -= 1
	if Input.is_action_pressed("ui_right"):
		pan_input.x += 1
	if Input.is_action_pressed("ui_up"):
		pan_input.y -= 1
	if Input.is_action_pressed("ui_down"):
		pan_input.y += 1
	if pan_input != Vector2.ZERO:
		_follow_target = null
		_target_position += pan_input * pan_speed * delta / zoom.x

	# Follow target
	if _follow_target and is_instance_valid(_follow_target):
		_target_position = _follow_target.global_position

	# Smooth movement
	global_position = global_position.lerp(_target_position, ease_speed * delta)
	zoom = zoom.lerp(_target_zoom, ease_speed * delta)


func _unhandled_input(event: InputEvent) -> void:
	# Middle mouse pan
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_pan_start = event.position

		# Scroll zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_zoom = (_target_zoom + Vector2.ONE * zoom_step).clampf(zoom_min, zoom_max)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_zoom = (_target_zoom - Vector2.ONE * zoom_step).clampf(zoom_min, zoom_max)

	if event is InputEventMouseMotion and _is_panning:
		_follow_target = null
		_target_position -= event.relative / zoom.x

	# Home key reset
	if event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		_on_reset_requested()


func focus_on(world_pos: Vector2) -> void:
	_follow_target = null
	_target_position = world_pos


func follow(node: Node2D) -> void:
	_follow_target = node


func _on_focus_requested(world_pos: Vector2) -> void:
	focus_on(world_pos)


func _on_reset_requested() -> void:
	_follow_target = null
	_target_position = Vector2.ZERO
	_target_zoom = Vector2.ONE


func _on_follow_stopped() -> void:
	_follow_target = null
