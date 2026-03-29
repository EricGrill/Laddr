extends Node2D
## Triage Droid — picks up job packets from Intake, carries them to Dispatcher.
## Animates walking between the two stations, carrying a colored packet.

var _sprite: Sprite2D
var _label: Label
var _status_card: Node2D
var _status_text: Label
var _carried_packet: ColorRect  # Visual packet being carried
var _sprite_textures: Dictionary = {}
var _jobs_scanned: int = 0

# Movement state
enum State { IDLE, WALKING_TO_INTAKE, PICKING_UP, WALKING_TO_DISPATCH, DROPPING_OFF }
var _state: int = State.IDLE
var _intake_pos: Vector2 = Vector2.ZERO
var _dispatch_pos: Vector2 = Vector2.ZERO
var _home_pos: Vector2 = Vector2.ZERO
var _move_speed: float = 120.0
var _action_timer: float = 0.0
var _idle_timer: float = 0.0
var _trips_completed: int = 0

const SPRITE_BASE = "res://assets/sprites/workers/triage/"
const DIRECTIONS = ["front", "iso_left", "iso_right"]
const PACKET_COLORS = [
	Color(0.39, 0.84, 0.90, 0.9),  # cyan - normal
	Color(0.85, 0.69, 0.36, 0.9),  # gold - high
	Color(0.85, 0.36, 0.36, 0.9),  # red - critical
	Color(0.64, 0.48, 1.0, 0.9),   # purple - llm
]


func _ready() -> void:
	_home_pos = position

	for dir in DIRECTIONS:
		var tex = load(SPRITE_BASE + "triage_" + dir + ".png")
		if tex:
			_sprite_textures[dir] = tex

	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(0.4, 0.4)
	if _sprite_textures.has("front"):
		_sprite.texture = _sprite_textures["front"]
	add_child(_sprite)

	# Name label
	_label = Label.new()
	_label.text = "Triage Droid"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-40, 30)
	_label.size = Vector2(80, 20)
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 10
	lbl_settings.font_color = Color(0.5, 0.85, 1.0, 0.9)
	lbl_settings.outline_size = 2
	lbl_settings.outline_color = Color(0, 0, 0, 0.7)
	_label.label_settings = lbl_settings
	add_child(_label)

	# Carried packet (hidden until carrying)
	_carried_packet = ColorRect.new()
	_carried_packet.size = Vector2(12, 10)
	_carried_packet.position = Vector2(-6, -35)
	_carried_packet.color = PACKET_COLORS[0]
	_carried_packet.visible = false
	add_child(_carried_packet)

	# Status card
	_status_card = Node2D.new()
	_status_card.position = Vector2(0, -65)

	var bg = ColorRect.new()
	bg.size = Vector2(140, 45)
	bg.position = Vector2(-70, -28)
	bg.color = Color(0.06, 0.12, 0.18, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_card.add_child(bg)

	var border = ColorRect.new()
	border.size = Vector2(140, 2)
	border.position = Vector2(-70, -28)
	border.color = Color(0.3, 0.8, 1.0, 0.9)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_card.add_child(border)

	_status_text = Label.new()
	_status_text.position = Vector2(-64, -24)
	_status_text.size = Vector2(128, 40)
	var st_settings = LabelSettings.new()
	st_settings.font_size = 10
	st_settings.font_color = Color(0.7, 0.92, 1.0, 1.0)
	_status_text.label_settings = st_settings
	_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_card.add_child(_status_text)
	add_child(_status_card)

	WorldState.snapshot_loaded.connect(_on_snapshot)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.metrics_changed.connect(_update_stats)


func set_stations(intake: Vector2, dispatch: Vector2) -> void:
	_intake_pos = intake
	_dispatch_pos = dispatch


func _on_snapshot() -> void:
	_jobs_scanned = WorldState.jobs.size()
	# Find station positions from world builder
	_find_station_positions()
	_update_stats()


func _find_station_positions() -> void:
	var builders = get_tree().get_nodes_in_group("world_builder")
	if builders.size() > 0:
		var builder = builders[0]
		if builder.has_method("get_station_screen_pos"):
			var ip = builder.get_station_screen_pos("intake")
			var dp = builder.get_station_screen_pos("dispatcher")
			if ip != Vector2.ZERO:
				_intake_pos = ip
			if dp != Vector2.ZERO:
				_dispatch_pos = dp


func _on_job_changed(_job_id: String) -> void:
	_jobs_scanned += 1
	# Start a trip if idle and there are queued jobs
	if _state == State.IDLE:
		_start_trip()


func _start_trip() -> void:
	if _intake_pos == Vector2.ZERO or _dispatch_pos == Vector2.ZERO:
		_find_station_positions()
	if _intake_pos == Vector2.ZERO:
		return
	_state = State.WALKING_TO_INTAKE
	_set_facing("iso_left")


func _update_stats() -> void:
	var queued = WorldState.metrics.get("realQueueDepth", 0)
	var overflow = WorldState.metrics.get("overflowActive", false)

	var lines = []
	if overflow:
		lines.append("OVERFLOW ACTIVE")
	elif queued > 0:
		lines.append("SCANNING QUEUE")
		lines.append("Total: %d jobs" % queued)
	else:
		lines.append("QUEUE CLEAR")
		lines.append("Standing by...")

	# Show current job info if carrying
	if _state == State.WALKING_TO_DISPATCH or _state == State.DROPPING_OFF:
		var job_name = _get_current_job_name()
		if job_name != "":
			lines.append(job_name)

	lines.append("Q:%d | Run:%d" % [queued, _count_processing()])
	lines.append("Workers: %d online" % WorldState.workers.size())
	_status_text.text = "\n".join(lines)

	# Keep moving if there are jobs
	if queued > 0 and _state == State.IDLE:
		_idle_timer = 0
		_start_trip()


func _count_processing() -> int:
	var count = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "") == "processing":
			count += 1
	return count


func _get_current_job_name() -> String:
	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		if job.get("state", "") == "queued" or job.get("state", "") == "processing":
			var raw = str(job.get("type", ""))
			for line in raw.split("\n"):
				var t = line.strip_edges()
				if t.begins_with("# "):
					return t.substr(2).left(24)
			return raw.left(24)
	return ""


func _set_facing(dir: String) -> void:
	if _sprite_textures.has(dir):
		_sprite.texture = _sprite_textures[dir]


func _process(delta: float) -> void:
	match _state:
		State.IDLE:
			# Idle bob
			_sprite.position.y = sin(Time.get_ticks_msec() / 1500.0) * 2.0
			_set_facing("front")
			_idle_timer += delta
			# Auto-start trips if there are queued jobs
			if _idle_timer > 2.0:
				var queued = WorldState.metrics.get("realQueueDepth", 0)
				if queued > 0:
					_start_trip()
				_idle_timer = 0

		State.WALKING_TO_INTAKE:
			var dir = (_intake_pos - global_position).normalized()
			global_position += dir * _move_speed * delta
			# Face direction of travel
			if dir.x < -0.1:
				_set_facing("iso_left")
			elif dir.x > 0.1:
				_set_facing("iso_right")
			# Walk bob
			_sprite.position.y = sin(Time.get_ticks_msec() / 200.0) * 1.5
			if global_position.distance_to(_intake_pos) < 10:
				global_position = _intake_pos
				_state = State.PICKING_UP
				_action_timer = 0.6

		State.PICKING_UP:
			# Quick pickup animation — wobble + show packet
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.12
			if _action_timer <= 0.3 and not _carried_packet.visible:
				_carried_packet.visible = true
				_carried_packet.color = PACKET_COLORS[_trips_completed % PACKET_COLORS.size()]
			if _action_timer <= 0:
				_sprite.rotation = 0
				_state = State.WALKING_TO_DISPATCH
				_set_facing("iso_right")

		State.WALKING_TO_DISPATCH:
			var dir = (_dispatch_pos - global_position).normalized()
			global_position += dir * _move_speed * delta
			if dir.x < -0.1:
				_set_facing("iso_left")
			elif dir.x > 0.1:
				_set_facing("iso_right")
			# Walk bob with packet
			_sprite.position.y = sin(Time.get_ticks_msec() / 200.0) * 1.5
			_carried_packet.position.y = -35 + sin(Time.get_ticks_msec() / 200.0) * 1.5
			if global_position.distance_to(_dispatch_pos) < 10:
				global_position = _dispatch_pos
				_state = State.DROPPING_OFF
				_action_timer = 0.4

		State.DROPPING_OFF:
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.08
			if _action_timer <= 0.2:
				_carried_packet.visible = false
			if _action_timer <= 0:
				_sprite.rotation = 0
				_trips_completed += 1
				# Check if more jobs to carry
				var queued = WorldState.metrics.get("realQueueDepth", 0)
				if queued > 0:
					_state = State.WALKING_TO_INTAKE
					_set_facing("iso_left")
				else:
					_state = State.IDLE
					_update_stats()

	# Float status card
	_status_card.position.y = -65 + sin(Time.get_ticks_msec() / 1200.0) * 2.0
