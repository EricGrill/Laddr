extends Node2D
## Triage Droid — carries job packets from Intake Bay to Dispatcher Hub.
## Stands still when idle. Only moves when there are actual jobs in the queue.

var _sprite: Sprite2D
var _label: Label
var _carried_packet: Node2D
var _sprite_textures: Dictionary = {}

enum State { IDLE, TO_INTAKE, PICKUP, TO_DISPATCH, DROPOFF }
var _state: int = State.IDLE
var _intake_pos: Vector2 = Vector2.ZERO
var _dispatch_pos: Vector2 = Vector2.ZERO
var _move_speed: float = 100.0
var _action_timer: float = 0.0
var _trips_completed: int = 0
var _last_queue_check: float = 0.0

const SPRITE_BASE = "res://assets/sprites/workers/triage/"
const DIRECTIONS = ["front", "iso_left", "iso_right"]
const PACKET_COLORS = [
	Color(0.39, 0.84, 0.90, 0.9),
	Color(0.85, 0.69, 0.36, 0.9),
	Color(0.85, 0.36, 0.36, 0.9),
	Color(0.64, 0.48, 1.0, 0.9),
]


func _ready() -> void:
	for dir in DIRECTIONS:
		var tex = load(SPRITE_BASE + "triage_" + dir + ".png")
		if tex:
			_sprite_textures[dir] = tex

	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(0.4, 0.4)
	if _sprite_textures.has("front"):
		_sprite.texture = _sprite_textures["front"]
	add_child(_sprite)

	_label = Label.new()
	_label.text = "Triage Droid"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-40, 30)
	_label.size = Vector2(80, 20)
	var ls = LabelSettings.new()
	ls.font_size = 10
	ls.font_color = Color(0.5, 0.85, 1.0, 0.9)
	ls.outline_size = 2
	ls.outline_color = Color(0, 0, 0, 0.7)
	_label.label_settings = ls
	add_child(_label)

	# Carried crate — visible box with stripe
	_carried_packet = Node2D.new()
	_carried_packet.visible = false
	var crate = ColorRect.new()
	crate.name = "CrateBG"
	crate.size = Vector2(20, 16)
	crate.position = Vector2(-10, -8)
	crate.color = PACKET_COLORS[0]
	crate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carried_packet.add_child(crate)
	var stripe = ColorRect.new()
	stripe.size = Vector2(20, 2)
	stripe.position = Vector2(-10, -8)
	stripe.color = Color(1, 1, 1, 0.35)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carried_packet.add_child(stripe)
	add_child(_carried_packet)

	WorldState.job_created.connect(_on_new_job)
	WorldState.metrics_changed.connect(_on_metrics)


func set_stations(intake: Vector2, dispatch: Vector2) -> void:
	_intake_pos = intake
	_dispatch_pos = dispatch


func _on_new_job(_job_id: String) -> void:
	if _state == State.IDLE:
		_begin_trip()


func _on_metrics() -> void:
	if _state == State.IDLE:
		var q = WorldState.metrics.get("realQueueDepth", 0)
		if q > 0:
			_begin_trip()


func _begin_trip() -> void:
	if _intake_pos == Vector2.ZERO:
		return
	_state = State.TO_INTAKE
	_face_toward(_intake_pos)


func _face_toward(target: Vector2) -> void:
	var dx = target.x - position.x
	var dy = target.y - position.y
	if abs(dx) > abs(dy):
		_set_facing("iso_left" if dx < 0 else "iso_right")
	else:
		_set_facing("iso_left" if dy < 0 else "iso_right")


func _set_facing(dir: String) -> void:
	if _sprite_textures.has(dir):
		_sprite.texture = _sprite_textures[dir]


func _process(delta: float) -> void:
	match _state:
		State.IDLE:
			# Stand still, gentle bob
			_sprite.position.y = sin(Time.get_ticks_msec() / 1500.0) * 1.5
			_set_facing("front")

		State.TO_INTAKE:
			_walk_toward(_intake_pos, delta)
			if position.distance_to(_intake_pos) < 8:
				position = _intake_pos
				_state = State.PICKUP
				_action_timer = 0.6

		State.PICKUP:
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.12
			if _action_timer <= 0.3 and not _carried_packet.visible:
				_carried_packet.visible = true
				var crate = _carried_packet.get_node_or_null("CrateBG")
				if crate:
					crate.color = PACKET_COLORS[_trips_completed % PACKET_COLORS.size()]
			if _action_timer <= 0:
				_sprite.rotation = 0
				_state = State.TO_DISPATCH
				_face_toward(_dispatch_pos)

		State.TO_DISPATCH:
			_walk_toward(_dispatch_pos, delta)
			# Crate follows above sprite
			_carried_packet.position = Vector2(0, _sprite.position.y - 40)
			if position.distance_to(_dispatch_pos) < 8:
				position = _dispatch_pos
				_state = State.DROPOFF
				_action_timer = 0.4

		State.DROPOFF:
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.06
			if _action_timer <= 0.2:
				_carried_packet.visible = false
			if _action_timer <= 0:
				_sprite.rotation = 0
				_trips_completed += 1
				# More jobs? Go again. Otherwise stop here (will drift home).
				var q = WorldState.metrics.get("realQueueDepth", 0)
				if q > 0:
					_state = State.TO_INTAKE
					_face_toward(_intake_pos)
				else:
					_state = State.IDLE


func _walk_toward(target: Vector2, delta: float) -> void:
	var dir = (target - position).normalized()
	position += dir * _move_speed * delta
	# Walk bob
	_sprite.position.y = sin(Time.get_ticks_msec() / 180.0) * 2.0
	_face_toward(target)
