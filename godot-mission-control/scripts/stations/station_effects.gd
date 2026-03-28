extends Node
## Drives station-specific animations based on type and state.
## Attached as a child of station_controller.

var station_type: String = ""
var station_state: String = "idle"
var queue_depth: int = 0
var capacity: int = 1

var _time: float = 0.0
var _motion_seed: float = 0.0
var _parent: Node2D

var _sprite: Sprite2D
var _label: Label
var _info_label: Label
var _queue_label: Label
var _glow: ColorRect
var _pulse_ring: ColorRect
var _scan_beam: ColorRect
var _alarm_light: ColorRect
var _steam: ColorRect

var _sprite_base_pos: Vector2 = Vector2.ZERO
var _sprite_base_scale: Vector2 = Vector2.ONE
var _label_base_pos: Vector2 = Vector2.ZERO
var _info_base_pos: Vector2 = Vector2.ZERO
var _queue_base_pos: Vector2 = Vector2.ZERO
var _glow_base_pos: Vector2 = Vector2.ZERO
var _glow_base_scale: Vector2 = Vector2.ONE
var _pulse_base_pos: Vector2 = Vector2.ZERO
var _pulse_base_scale: Vector2 = Vector2.ONE
var _scan_base_pos: Vector2 = Vector2.ZERO
var _scan_base_scale: Vector2 = Vector2.ONE
var _alarm_base_pos: Vector2 = Vector2.ZERO
var _alarm_base_scale: Vector2 = Vector2.ONE
var _steam_base_pos: Vector2 = Vector2.ZERO
var _steam_base_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	_parent = get_parent()
	_motion_seed = float((get_parent().get_instance_id() if get_parent() else 1) % 983) * 0.017
	_cache_nodes()


func setup(type: String, cap: int) -> void:
	station_type = type
	capacity = cap


func update_state(new_state: String, new_queue_depth: int) -> void:
	station_state = new_state
	queue_depth = new_queue_depth


func _process(delta: float) -> void:
	_time += delta
	if not _parent:
		return

	_cache_nodes()

	var saturation = clampf(float(queue_depth) / max(capacity, 1), 0.0, 1.5)
	_apply_common_motion(saturation)

	match station_type:
		"intake":
			_animate_intake(saturation)
		"router":
			_animate_router(saturation)
		"research":
			_animate_research(saturation)
		"code":
			_animate_code(saturation)
		"review":
			_animate_review(saturation)
		"output":
			_animate_output(saturation)
		"supervisor":
			_animate_supervisor(saturation)
		"error":
			_animate_error(saturation)


func _cache_nodes() -> void:
	if not _parent:
		return
	if not _sprite:
		_sprite = _parent.get_node_or_null("Sprite")
		if _sprite:
			_sprite_base_pos = _sprite.position
			_sprite_base_scale = _sprite.scale
	if not _label:
		_label = _parent.get_node_or_null("Label")
		if _label:
			_label_base_pos = _label.position
	if not _info_label:
		_info_label = _parent.get_node_or_null("InfoLabel")
		if _info_label:
			_info_base_pos = _info_label.position
	if not _queue_label:
		_queue_label = _parent.get_node_or_null("QueueLabel")
		if _queue_label:
			_queue_base_pos = _queue_label.position
	if not _glow:
		_glow = _parent.get_node_or_null("Glow")
		if _glow:
			_glow_base_pos = _glow.position
			_glow_base_scale = _glow.scale
	if not _pulse_ring:
		_pulse_ring = _parent.get_node_or_null("PulseRing")
		if _pulse_ring:
			_pulse_base_pos = _pulse_ring.position
			_pulse_base_scale = _pulse_ring.scale
	if not _scan_beam:
		_scan_beam = _parent.get_node_or_null("ScanBeam")
		if _scan_beam:
			_scan_base_pos = _scan_beam.position
			_scan_base_scale = _scan_beam.scale
	if not _alarm_light:
		_alarm_light = _parent.get_node_or_null("AlarmLight")
		if _alarm_light:
			_alarm_base_pos = _alarm_light.position
			_alarm_base_scale = _alarm_light.scale
	if not _steam:
		_steam = _parent.get_node_or_null("Steam")
		if _steam:
			_steam_base_pos = _steam.position
			_steam_base_scale = _steam.scale


func _apply_common_motion(saturation: float) -> void:
	var state_strength = _get_state_strength()
	var pulse = 0.5 + sin(_time * (1.2 + saturation * 1.6) + _motion_seed) * 0.5
	var hover = sin(_time * (1.0 + state_strength) + _motion_seed) * (1.0 + saturation * 1.5)
	var lean = sin(_time * 0.7 + _motion_seed) * deg_to_rad(0.7 + saturation * 1.4)

	if _sprite:
		_sprite.position = _sprite_base_pos + Vector2(sin(_time * 1.4 + _motion_seed) * 1.2, -abs(hover) * 0.7)
		_sprite.rotation = lean
		_sprite.scale = _sprite_base_scale * Vector2(1.0 + pulse * 0.03, 1.0 + pulse * 0.03)

	if _label:
		_label.position = _label_base_pos + Vector2(0, sin(_time * 0.9 + _motion_seed) * 1.0)
	if _info_label:
		_info_label.position = _info_base_pos + Vector2(0, sin(_time * 1.1 + _motion_seed) * 0.8)
	if _queue_label:
		_queue_label.position = _queue_base_pos + Vector2(sin(_time * 1.3 + _motion_seed) * 0.8, 0)

	_update_glow(saturation, pulse)
	_update_pulse_ring(saturation, pulse)
	_update_scan_beam(saturation, pulse)
	_update_alarm_light(saturation, pulse)
	_update_steam(saturation, pulse)


func _get_state_strength() -> float:
	match station_state:
		"idle":
			return 0.1
		"queued", "processing", "busy":
			return 0.55
		"blocked", "overloaded":
			return 0.8
		"error", "failed":
			return 1.0
		_:
			return 0.35


func _state_color() -> Color:
	match station_state:
		"idle":
			return Color(0.2, 0.8, 1.0, 1.0)
		"queued", "processing", "busy":
			return Color(0.25, 0.95, 0.85, 1.0)
		"blocked", "overloaded":
			return Color(1.0, 0.75, 0.25, 1.0)
		"error", "failed":
			return Color(1.0, 0.25, 0.25, 1.0)
		_:
			return Color(0.7, 0.8, 0.9, 1.0)


func _update_glow(saturation: float, pulse: float) -> void:
	if not _glow:
		return
	var color = _state_color()
	color.a = 0.08 + pulse * 0.12 + saturation * 0.08
	_glow.color = color
	_glow.position = _glow_base_pos + Vector2(0, -2 + sin(_time * 1.2 + _motion_seed) * 1.0)
	_glow.scale = _glow_base_scale * Vector2(1.0 + pulse * 0.08, 1.0 + pulse * 0.05)
	_glow.visible = station_state != "idle" or saturation > 0.15


func _update_pulse_ring(saturation: float, pulse: float) -> void:
	if not _pulse_ring:
		return
	var strength = _get_state_strength()
	_pulse_ring.position = _pulse_base_pos + Vector2(0, sin(_time * 1.0 + _motion_seed) * 1.0)
	_pulse_ring.scale = _pulse_base_scale * Vector2(1.0 + pulse * 0.06 + saturation * 0.05, 1.0 + pulse * 0.03)
	_pulse_ring.rotation = sin(_time * (0.6 + strength) + _motion_seed) * deg_to_rad(2.0)
	var ring_color = _state_color()
	ring_color.a = 0.06 + pulse * 0.08
	_pulse_ring.color = ring_color
	_pulse_ring.visible = station_state != "idle" or saturation > 0.2


func _update_scan_beam(saturation: float, pulse: float) -> void:
	if not _scan_beam:
		return
	var sweep = fmod(_time * (0.8 + saturation * 0.8) + _motion_seed, 1.0)
	_scan_beam.position = _scan_base_pos + Vector2(lerpf(-28.0, 28.0, sweep), sin(_time * 1.4 + _motion_seed) * 1.0)
	_scan_beam.scale = _scan_base_scale * Vector2(1.0 + pulse * 0.02, 1.0)
	var color = _state_color()
	color.a = 0.03 + pulse * 0.05
	_scan_beam.color = color
	_scan_beam.visible = station_state in ["queued", "processing", "busy"] or saturation > 0.6


func _update_alarm_light(saturation: float, pulse: float) -> void:
	if not _alarm_light:
		return
	var alert_on = station_state in ["blocked", "overloaded", "error", "failed"] or saturation > 0.88
	_alarm_light.visible = alert_on
	if not alert_on:
		return
	var blink = fmod(_time * 6.0 + _motion_seed, 1.0) > 0.45
	_alarm_light.position = _alarm_base_pos + Vector2(sin(_time * 3.0 + _motion_seed) * 1.0, 0)
	_alarm_light.scale = _alarm_base_scale * Vector2(1.0 + pulse * 0.08, 1.0 + pulse * 0.08)
	var color = _state_color()
	color.a = 0.45 if blink else 0.18
	_alarm_light.color = color


func _update_steam(saturation: float, pulse: float) -> void:
	if not _steam:
		return
	var active = station_type in ["research", "code", "router", "review"] and (station_state != "idle" or saturation > 0.25)
	_steam.visible = active
	if not active:
		return
	var drift = sin(_time * 0.9 + _motion_seed) * 1.0
	_steam.position = _steam_base_pos + Vector2(drift * 0.75, -pulse * 3.0)
	_steam.scale = _steam_base_scale * Vector2(1.0, 1.0 + pulse * 0.08)
	var color = _state_color()
	color.a = 0.12 + pulse * 0.06
	_steam.color = color


func _animate_intake(saturation: float) -> void:
	# Intake flag gets livelier as the queue grows.
	var flag = _parent.get_node_or_null("Flag")
	if flag:
		flag.rotation_degrees = sin(_time * 3.0) * (2.0 + saturation * 6.0)


func _animate_router(saturation: float) -> void:
	# Spinning tray becomes more energetic when busy.
	var tray = _parent.get_node_or_null("Tray")
	if tray:
		tray.rotation += (1.0 + saturation * 3.0) * 0.02


func _animate_research(saturation: float) -> void:
	# Floating books orbit faster when the station is saturated.
	var books = _parent.get_node_or_null("Books")
	if books:
		var speed = 1.0 + saturation * 2.0
		books.position = Vector2(cos(_time * speed) * 15, sin(_time * speed) * 8)


func _animate_code(saturation: float) -> void:
	# Screen flicker plus a stronger glow pulse under load.
	var screen = _parent.get_node_or_null("Screen")
	if screen and screen is ColorRect:
		var brightness = 0.3 + saturation * 0.5 + sin(_time * 10.0) * 0.1
		screen.color = Color(0.1, brightness, 0.2, 1.0)


func _animate_review(saturation: float) -> void:
	# Magnifying glass bob mirrors the pulse rhythm.
	var glass = _parent.get_node_or_null("Glass")
	if glass:
		glass.position.y = sin(_time * 2.0) * (2.5 + saturation * 2.0)


func _animate_output(saturation: float) -> void:
	# Conveyor belt movement speeds up slightly with traffic.
	var belt = _parent.get_node_or_null("Belt")
	if belt:
		belt.position.x = fmod(_time * (18.0 + saturation * 8.0), 10.0)


func _animate_supervisor(saturation: float) -> void:
	# Alert lights blink more often as load approaches the limit.
	var alert = _parent.get_node_or_null("AlertLight")
	if alert and alert is ColorRect:
		alert.visible = saturation > 0.5 and fmod(_time, 1.0) > 0.5


func _animate_error(saturation: float) -> void:
	# Red lamp flash and a stronger wobble for error states.
	var lamp = _parent.get_node_or_null("Lamp")
	if lamp and lamp is ColorRect:
		var flash = 0.5 + sin(_time * 6.0) * 0.5
		lamp.color = Color(flash, 0, 0, 1.0)

	if _sprite:
		_sprite.position = _sprite_base_pos + Vector2(
			sin(_time * 11.0 + _motion_seed) * (1.5 + saturation * 2.0),
			cos(_time * 9.0 + _motion_seed) * (0.8 + saturation * 1.2)
		)
		_sprite.rotation = sin(_time * 8.0 + _motion_seed) * deg_to_rad(2.0 + saturation * 4.0)
