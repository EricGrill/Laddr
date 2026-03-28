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
var _base_offset: Vector2 = Vector2.ZERO
var _shake_time: float = 0.0
var _shake_duration: float = 0.0
var _shake_total_duration: float = 0.0
var _shake_strength: float = 0.0
var _shake_seed: float = 0.0
var _zoom_pulse: float = 0.0
var _zoom_pulse_duration: float = 0.0
var _zoom_pulse_total_duration: float = 0.0
var _zoom_pulse_strength: float = 0.0
var _overflow_active: bool = false


func _ready() -> void:
	_target_position = global_position
	_target_zoom = zoom
	_base_offset = offset
	set_process(true)
	EventBus.camera_focus_requested.connect(_on_focus_requested)
	EventBus.camera_reset_requested.connect(_on_reset_requested)
	EventBus.camera_follow_stopped.connect(_on_follow_stopped)
	EventBus.camera_follow_requested.connect(_on_follow_requested)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.metrics_changed.connect(_on_metrics_changed)


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
	zoom = zoom.lerp(_target_zoom * (1.0 + _zoom_pulse), ease_speed * delta)
	_update_zoom_pulse(delta)
	_update_shake(delta)


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


func pulse_attention(zoom_delta: float = 0.03, shake_strength: float = 3.0, duration: float = 0.2) -> void:
	_zoom_pulse_strength = maxf(_zoom_pulse_strength, zoom_delta)
	_zoom_pulse_duration = maxf(_zoom_pulse_duration, duration)
	_zoom_pulse_total_duration = maxf(_zoom_pulse_total_duration, duration)
	_shake_strength = maxf(_shake_strength, shake_strength)
	_shake_duration = maxf(_shake_duration, duration)
	_shake_total_duration = maxf(_shake_total_duration, duration)
	_shake_seed = randf_range(0.0, TAU)


func _update_zoom_pulse(delta: float) -> void:
	if _zoom_pulse_duration > 0.0:
		_zoom_pulse_duration -= delta
		var pulse_t = clampf(_zoom_pulse_duration / max(_zoom_pulse_total_duration, 0.001), 0.0, 1.0)
		_zoom_pulse = _zoom_pulse_strength * pulse_t
	else:
		_zoom_pulse = lerpf(_zoom_pulse, 0.0, ease_speed * delta)
		if _zoom_pulse < 0.0005:
			_zoom_pulse = 0.0
			_zoom_pulse_strength = 0.0
			_zoom_pulse_total_duration = 0.0


func _update_shake(delta: float) -> void:
	if _shake_duration > 0.0:
		_shake_duration -= delta
		_shake_time += delta
		var falloff = clampf(_shake_duration / max(_shake_total_duration, 0.001), 0.0, 1.0)
		var shake = _shake_strength * falloff
		offset = _base_offset + Vector2(
			sin((_shake_seed + _shake_time) * 17.0) * shake,
			cos((_shake_seed * 1.3 + _shake_time) * 21.0) * shake * 0.65
		)
	else:
		offset = offset.lerp(_base_offset, ease_speed * delta)
		if offset.distance_to(_base_offset) < 0.05:
			offset = _base_offset
			_shake_strength = 0.0
			_shake_total_duration = 0.0


func _on_job_completed(_job_id: String) -> void:
	pulse_attention(0.015, 2.0, 0.16)


func _on_job_failed(_job_id: String, _reason: String) -> void:
	pulse_attention(0.05, 5.5, 0.25)


func _on_worker_removed(_worker_id: String) -> void:
	pulse_attention(0.02, 2.5, 0.18)


func _on_metrics_changed() -> void:
	var overflow = bool(WorldState.metrics.get("overflowActive", false))
	if overflow and not _overflow_active:
		pulse_attention(0.06, 4.0, 0.22)
	_overflow_active = overflow


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
	_zoom_pulse = 0.0
	_zoom_pulse_strength = 0.0
	_zoom_pulse_duration = 0.0
	_zoom_pulse_total_duration = 0.0
	_shake_strength = 0.0
	_shake_duration = 0.0
	_shake_total_duration = 0.0
	_shake_time = 0.0
	offset = _base_offset


func _on_follow_stopped() -> void:
	_follow_target = null


func _on_follow_requested(entity_type: String, entity_id: String) -> void:
	# Find the node by entity_id in the scene tree
	# WorldBuilder maintains agent_nodes dictionary
	var world_builder = get_tree().get_first_node_in_group("world_builder")
	if world_builder and world_builder.agent_nodes.has(entity_id):
		follow(world_builder.agent_nodes[entity_id])
