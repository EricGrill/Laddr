extends Node2D
## Triage Droid — scans incoming jobs at the Intake Bay.
## Shuttles packets a short distance to show processing activity.
## Always stays near the Intake Bay area.

var _sprite: Sprite2D
var _label: Label
var _status_card: Node2D
var _status_text: Label
var _carried_packet: Node2D
var _sprite_textures: Dictionary = {}

# Movement — short shuttle between pickup and dropoff near intake
enum State { IDLE, WALKING_TO_PICKUP, PICKING_UP, WALKING_TO_DROPOFF, DROPPING_OFF }
var _state: int = State.IDLE
var _pickup_offset: Vector2 = Vector2(-30, -20)   # Left side of intake
var _dropoff_offset: Vector2 = Vector2(30, 40)     # Right/below intake
var _move_speed: float = 80.0
var _action_timer: float = 0.0
var _idle_timer: float = 0.0
var _trips_completed: int = 0
var _home_offset: Vector2 = Vector2(0, 10)

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
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 10
	lbl_settings.font_color = Color(0.5, 0.85, 1.0, 0.9)
	lbl_settings.outline_size = 2
	lbl_settings.outline_color = Color(0, 0, 0, 0.7)
	_label.label_settings = lbl_settings
	add_child(_label)

	# Carried crate
	_carried_packet = Node2D.new()
	_carried_packet.position = Vector2(0, -42)
	_carried_packet.visible = false
	var crate_bg = ColorRect.new()
	crate_bg.name = "CrateBG"
	crate_bg.size = Vector2(20, 16)
	crate_bg.position = Vector2(-10, -8)
	crate_bg.color = PACKET_COLORS[0]
	crate_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carried_packet.add_child(crate_bg)
	var crate_top = ColorRect.new()
	crate_top.size = Vector2(20, 2)
	crate_top.position = Vector2(-10, -8)
	crate_top.color = Color(1, 1, 1, 0.35)
	crate_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carried_packet.add_child(crate_top)
	add_child(_carried_packet)

	# Status card
	_status_card = Node2D.new()
	_status_card.position = Vector2(0, -70)
	var bg = ColorRect.new()
	bg.size = Vector2(160, 55)
	bg.position = Vector2(-80, -28)
	bg.color = Color(0.06, 0.12, 0.18, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_card.add_child(bg)
	var border = ColorRect.new()
	border.size = Vector2(160, 2)
	border.position = Vector2(-80, -28)
	border.color = Color(0.3, 0.8, 1.0, 0.9)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_card.add_child(border)
	_status_text = Label.new()
	_status_text.position = Vector2(-74, -24)
	_status_text.size = Vector2(148, 50)
	var st_settings = LabelSettings.new()
	st_settings.font_size = 9
	st_settings.font_color = Color(0.7, 0.92, 1.0, 1.0)
	_status_text.label_settings = st_settings
	_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_card.add_child(_status_text)
	add_child(_status_card)

	WorldState.snapshot_loaded.connect(_on_snapshot)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.metrics_changed.connect(_update_stats)


func _on_snapshot() -> void:
	_update_stats()


func _on_job_changed(_job_id: String) -> void:
	var queued = WorldState.metrics.get("realQueueDepth", 0)
	if _state == State.IDLE and queued > 0:
		_start_trip()


func _start_trip() -> void:
	_state = State.WALKING_TO_PICKUP
	_set_facing("iso_left")
	_update_stats()


func _get_target_pos(offset: Vector2) -> Vector2:
	# All movement is relative to our spawn position (parent handles absolute placement)
	return offset


func _update_stats() -> void:
	var queued = WorldState.metrics.get("realQueueDepth", 0)
	var overflow = WorldState.metrics.get("overflowActive", false)
	var throughput = WorldState.metrics.get("throughput", {})
	var done_hr = throughput.get("completed", {}).get("1h", 0)
	var processing = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "") == "processing":
			processing += 1

	var lines = []
	match _state:
		State.WALKING_TO_PICKUP, State.PICKING_UP:
			var job_name = _get_current_job_name()
			lines.append("FETCHING")
			if job_name != "":
				lines.append(job_name)
			lines.append("Q:%d | %d/hr" % [queued, done_hr])
		State.WALKING_TO_DROPOFF, State.DROPPING_OFF:
			var job_name = _get_current_job_name()
			lines.append("DISPATCHING")
			if job_name != "":
				lines.append(job_name)
			lines.append("Q:%d | Run:%d | %d/hr" % [queued, processing, done_hr])
		_:
			if overflow:
				lines.append("OVERFLOW ACTIVE")
				var spend = WorldState.metrics.get("dailyVeniceSpend", 0.0)
				lines.append("Venice: $%.2f" % spend)
			elif queued > 0:
				lines.append("SCANNING Q:%d" % queued)
				lines.append("%d/hr | %d workers" % [done_hr, WorldState.workers.size()])
			else:
				lines.append("QUEUE CLEAR")
				lines.append("%d/hr | %d workers" % [done_hr, WorldState.workers.size()])
	_status_text.text = "\n".join(lines)


func _get_current_job_name() -> String:
	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var s = job.get("state", "")
		if s == "queued" or s == "processing":
			var raw = str(job.get("type", ""))
			for line in raw.split("\n"):
				var t = line.strip_edges()
				if t.begins_with("# "):
					return t.substr(2).left(22)
			return raw.left(22)
	return ""


func _set_facing(dir: String) -> void:
	if _sprite_textures.has(dir):
		_sprite.texture = _sprite_textures[dir]


func _process(delta: float) -> void:
	# All movement is relative offsets from spawn point
	var local_pos = _sprite.position  # Use sprite offset for local shuttle

	match _state:
		State.IDLE:
			# Drift to home
			var home = _home_offset
			_sprite.position = _sprite.position.lerp(Vector2(home.x, home.y + sin(Time.get_ticks_msec() / 1500.0) * 2.0), delta * 2.0)
			_set_facing("front")
			_idle_timer += delta
			if _idle_timer > 1.5:
				var queued = WorldState.metrics.get("realQueueDepth", 0)
				if queued > 0:
					_start_trip()
				_idle_timer = 0

		State.WALKING_TO_PICKUP:
			var target = _pickup_offset
			var dir = (target - _sprite.position).normalized()
			_sprite.position += dir * _move_speed * delta
			if dir.x < 0:
				_set_facing("iso_left")
			else:
				_set_facing("iso_right")
			_sprite.position.y += sin(Time.get_ticks_msec() / 200.0) * 0.3
			if _sprite.position.distance_to(target) < 5:
				_sprite.position = target
				_state = State.PICKING_UP
				_action_timer = 0.5

		State.PICKING_UP:
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.12
			if _action_timer <= 0.25 and not _carried_packet.visible:
				_carried_packet.visible = true
				var crate = _carried_packet.get_node_or_null("CrateBG")
				if crate:
					crate.color = PACKET_COLORS[_trips_completed % PACKET_COLORS.size()]
			if _action_timer <= 0:
				_sprite.rotation = 0
				_state = State.WALKING_TO_DROPOFF
				_set_facing("iso_right")
				_update_stats()

		State.WALKING_TO_DROPOFF:
			var target = _dropoff_offset
			var dir = (target - _sprite.position).normalized()
			_sprite.position += dir * _move_speed * delta
			if dir.x > 0:
				_set_facing("iso_right")
			else:
				_set_facing("iso_left")
			_sprite.position.y += sin(Time.get_ticks_msec() / 200.0) * 0.3
			_carried_packet.position = Vector2(_sprite.position.x, _sprite.position.y - 42)
			if _sprite.position.distance_to(target) < 5:
				_sprite.position = target
				_state = State.DROPPING_OFF
				_action_timer = 0.3

		State.DROPPING_OFF:
			_action_timer -= delta
			_sprite.rotation = sin(Time.get_ticks_msec() / 100.0) * 0.06
			if _action_timer <= 0.15:
				_carried_packet.visible = false
			if _action_timer <= 0:
				_sprite.rotation = 0
				_trips_completed += 1
				_update_stats()
				var queued = WorldState.metrics.get("realQueueDepth", 0)
				if queued > 0:
					_state = State.WALKING_TO_PICKUP
					_set_facing("iso_left")
				else:
					_state = State.IDLE
					_idle_timer = 0

	# Float status card above sprite
	_status_card.position = Vector2(_sprite.position.x, _sprite.position.y - 70)
	_carried_packet.position = Vector2(_sprite.position.x, _sprite.position.y - 42) if _carried_packet.visible else _carried_packet.position
	_label.position = Vector2(_sprite.position.x - 40, _sprite.position.y + 30)
