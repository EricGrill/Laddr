extends Node
## Handles agent animation: directional sprite swapping, wobble walk,
## squash/stretch, idle bob, emotes.
## Reads velocity_direction from sibling AgentMover to determine facing.

@export var wobble_amplitude: float = 3.0
@export var wobble_speed: float = 8.0
@export var bob_amplitude: float = 2.0
@export var bob_speed: float = 2.0
@export var squash_duration: float = 0.15

var _time: float = 0.0
var _is_walking: bool = false
var _squash_timer: float = 0.0
var _squash_type: String = ""  # "squash" or "stretch"
var _facing_direction: int = 0  # 0-7 (S, SW, W, NW, N, NE, E, SE)
var _role_name: String = "default"
var _motion_seed: float = 0.0
var _blink_timer: float = 0.0
var _blink_interval: float = 4.0
var _body_base_position: Vector2 = Vector2.ZERO
var _packet_base_position: Vector2 = Vector2.ZERO
var _shadow_base_position: Vector2 = Vector2.ZERO
var _aura_base_position: Vector2 = Vector2.ZERO
var _agent_base_scale: Vector2 = Vector2.ONE
var _packet_base_scale: Vector2 = Vector2.ONE
var _shadow_base_scale: Vector2 = Vector2.ONE
var _aura_base_scale: Vector2 = Vector2.ONE

const ROLE_PROFILES := {
	"default": {
		"bob_amplitude": 2.0,
		"bob_speed": 2.0,
		"wobble_amplitude": 3.0,
		"wobble_speed": 8.0,
		"sway_amplitude": 1.0,
		"lean_amplitude": 0.0,
		"fidget_min": 3.0,
		"fidget_max": 8.0,
		"packet_float": 1.0,
		"packet_sway": 1.0,
		"pulse_scale": 1.0,
		"emote_bias": 1.0,
	},
	"router": {
		"bob_amplitude": 1.6,
		"bob_speed": 2.6,
		"wobble_amplitude": 3.8,
		"wobble_speed": 9.0,
		"sway_amplitude": 1.4,
		"lean_amplitude": 0.02,
		"fidget_min": 2.0,
		"fidget_max": 6.0,
		"packet_float": 1.15,
		"packet_sway": 1.1,
		"pulse_scale": 1.03,
		"emote_bias": 1.2,
	},
	"researcher": {
		"bob_amplitude": 2.8,
		"bob_speed": 1.7,
		"wobble_amplitude": 2.2,
		"wobble_speed": 6.0,
		"sway_amplitude": 0.8,
		"lean_amplitude": -0.03,
		"fidget_min": 4.0,
		"fidget_max": 9.0,
		"packet_float": 1.35,
		"packet_sway": 0.8,
		"pulse_scale": 1.01,
		"emote_bias": 0.95,
	},
	"coder": {
		"bob_amplitude": 1.7,
		"bob_speed": 2.2,
		"wobble_amplitude": 2.6,
		"wobble_speed": 10.0,
		"sway_amplitude": 0.7,
		"lean_amplitude": 0.01,
		"fidget_min": 2.5,
		"fidget_max": 5.5,
		"packet_float": 0.95,
		"packet_sway": 1.25,
		"pulse_scale": 1.02,
		"emote_bias": 1.0,
	},
	"reviewer": {
		"bob_amplitude": 1.8,
		"bob_speed": 1.9,
		"wobble_amplitude": 2.0,
		"wobble_speed": 7.5,
		"sway_amplitude": 0.9,
		"lean_amplitude": -0.01,
		"fidget_min": 3.5,
		"fidget_max": 7.0,
		"packet_float": 1.05,
		"packet_sway": 0.9,
		"pulse_scale": 1.0,
		"emote_bias": 1.05,
	},
	"deployer": {
		"bob_amplitude": 2.2,
		"bob_speed": 2.4,
		"wobble_amplitude": 3.4,
		"wobble_speed": 8.8,
		"sway_amplitude": 1.2,
		"lean_amplitude": 0.04,
		"fidget_min": 2.0,
		"fidget_max": 5.0,
		"packet_float": 1.25,
		"packet_sway": 1.15,
		"pulse_scale": 1.08,
		"emote_bias": 1.15,
	},
	"supervisor": {
		"bob_amplitude": 1.4,
		"bob_speed": 1.6,
		"wobble_amplitude": 1.8,
		"wobble_speed": 5.5,
		"sway_amplitude": 0.6,
		"lean_amplitude": -0.04,
		"fidget_min": 4.5,
		"fidget_max": 9.5,
		"packet_float": 0.8,
		"packet_sway": 0.7,
		"pulse_scale": 0.99,
		"emote_bias": 0.85,
	},
}

var body_sprite: Node2D  # Body node, set by agent controller
var agent_sprite: Sprite2D  # The actual sprite, set by agent controller
var mover: Node = null  # AgentMover reference, set by controller
var agent_color: Color = Color.WHITE
var packet_sprite: Sprite2D = null
var shadow_node: CanvasItem = null
var aura_node: CanvasItem = null

# Role sprite textures: "front", "iso_left", "iso_right"
var _role_textures: Dictionary = {}
var _current_sprite_key: String = "front"

# Idle fidget
var _fidget_timer: float = 0.0
var _fidget_interval: float = 5.0  # randomized

# Playback speed
var _playback_speed: float = 1.0

# Emotes
var _emote_node: Label = null
var _emote_timer: float = 0.0
const EMOTE_DURATION = 2.0

const EMOTES = {
	"thinking": "?",
	"success": "!",
	"error": "X",
	"blocked": "...",
	"lightbulb": "*",
}

# Direction to sprite key mapping
# S=0, SW=1, W=2, NW=3, N=4, NE=5, E=6, SE=7
const DIR_TO_SPRITE = {
	0: "front",      # S
	1: "iso_left",    # SW
	2: "iso_left",    # W
	3: "iso_left",    # NW
	4: "front",       # N
	5: "iso_right",   # NE
	6: "iso_right",   # E
	7: "iso_right",   # SE
}


func _ready() -> void:
	_motion_seed = float((get_parent().get_instance_id() if get_parent() else 1) % 997) * 0.013
	_fidget_interval = randf_range(3.0, 8.0)
	_blink_interval = randf_range(2.5, 6.5)
	_cache_motion_bases()
	EventBus.playback_speed_changed.connect(func(speed): _playback_speed = speed)


func set_body_sprite(sprite: Node2D) -> void:
	body_sprite = sprite
	_cache_motion_bases()


func set_agent_sprite(sprite: Sprite2D) -> void:
	agent_sprite = sprite
	_cache_motion_bases()


func set_mover(node: Node) -> void:
	mover = node


func set_role_profile(role: String) -> void:
	_role_name = role.to_lower().strip_edges() if role != "" else "default"
	_apply_role_profile()


func set_walking(walking: bool) -> void:
	_is_walking = walking


func set_packet_sprite(sprite: Sprite2D) -> void:
	packet_sprite = sprite
	_cache_motion_bases()


func set_shadow_node(node: CanvasItem) -> void:
	shadow_node = node
	_cache_motion_bases()


func set_aura_node(node: CanvasItem) -> void:
	aura_node = node
	_cache_motion_bases()


func set_role_textures(textures: Dictionary) -> void:
	_role_textures = textures


func play_squash() -> void:
	_squash_timer = squash_duration
	_squash_type = "squash"


func play_stretch() -> void:
	_squash_timer = squash_duration
	_squash_type = "stretch"


func show_emote(emote_type: String) -> void:
	if _emote_node:
		_emote_node.queue_free()

	_emote_node = Label.new()
	_emote_node.text = EMOTES.get(emote_type, "?")
	_emote_node.position = Vector2(-4, -36)
	var settings = LabelSettings.new()
	settings.font_size = 16
	settings.font_color = Color.WHITE
	settings.outline_size = 2
	settings.outline_color = Color.BLACK
	_emote_node.label_settings = settings

	if body_sprite:
		body_sprite.add_child(_emote_node)
	_emote_timer = EMOTE_DURATION


func _update_emote(delta: float) -> void:
	if _emote_timer > 0:
		_emote_timer -= delta
		if _emote_timer <= 0 and _emote_node:
			_emote_node.queue_free()
			_emote_node = null
		elif _emote_node:
			# Float upward and fade
			_emote_node.position.y -= delta * 5.0
			_emote_node.modulate.a = clampf(_emote_timer / EMOTE_DURATION, 0.0, 1.0)


func _process(delta: float) -> void:
	_time += delta * _playback_speed
	_update_blink(delta)

	if not body_sprite:
		return

	# Skip if off-screen
	var parent_node = get_parent()
	if parent_node and not parent_node.is_visible_in_tree():
		return
	var cam = get_viewport().get_camera_2d()
	if cam:
		var screen_pos = parent_node.get_global_transform_with_canvas().origin
		var viewport_rect = get_viewport().get_visible_rect()
		var margin = 100.0
		if screen_pos.x < -margin or screen_pos.x > viewport_rect.size.x + margin:
			return
		if screen_pos.y < -margin or screen_pos.y > viewport_rect.size.y + margin:
			return

	_update_emote(delta)

	# Update facing direction from mover velocity (8-directional)
	if mover and mover.velocity_direction.length() > 0.1:
		var angle = mover.velocity_direction.angle()
		_facing_direction = int(round(angle / (PI / 4))) % 8
		if _facing_direction < 0:
			_facing_direction += 8

	# Swap sprite texture based on facing direction
	_update_sprite_direction()

	var profile = _get_profile()
	var offset_y = 0.0
	var offset_x = 0.0
	var rotation_z = 0.0
	var scale_mod = Vector2.ONE
	var bob_amp = bob_amplitude * float(profile.get("bob_amplitude", 1.0))
	var bob_speed_mod = bob_speed * float(profile.get("bob_speed", 1.0))
	var wobble_amp = wobble_amplitude * float(profile.get("wobble_amplitude", 1.0))
	var wobble_speed_mod = wobble_speed * float(profile.get("wobble_speed", 1.0))
	var sway_amp = float(profile.get("sway_amplitude", 1.0))
	var lean_amp = float(profile.get("lean_amplitude", 0.0))
	var pulse_scale = float(profile.get("pulse_scale", 1.0))

	if _is_walking:
		# Wobble walk: sinusoidal rotation + vertical bounce
		rotation_z = sin(_time * wobble_speed_mod) * deg_to_rad(wobble_amp)
		offset_y = -abs(sin(_time * wobble_speed_mod * 0.5)) * 4.0 * pulse_scale
		offset_x = sin(_time * wobble_speed_mod * 0.5 + _motion_seed) * sway_amp * 1.5
	else:
		# Idle bob
		offset_y = sin(_time * bob_speed_mod) * bob_amp
		offset_x = sin(_time * bob_speed_mod * 0.65 + _motion_seed) * sway_amp
		rotation_z = sin(_time * bob_speed_mod * 0.4 + _motion_seed) * lean_amp
		_update_fidget(delta)

	# Squash/stretch
	if _squash_timer > 0:
		_squash_timer -= delta
		var t = _squash_timer / squash_duration
		if _squash_type == "squash":
			scale_mod = Vector2(1.0 + 0.2 * t, 1.0 - 0.15 * t)
		else:
			scale_mod = Vector2(1.0 - 0.1 * t, 1.0 + 0.2 * t)

	# Gentle posture pulse based on role and activity
	scale_mod *= Vector2(1.0, 1.0) * pulse_scale

	body_sprite.rotation = rotation_z
	body_sprite.position = _get_body_base_position() + Vector2(offset_x, offset_y)
	body_sprite.scale = scale_mod
	_update_aura(offset_y, profile)
	_update_shadow(offset_y, profile)
	_update_packet(offset_y, profile)
	_update_sprite_breath(profile)


func _update_sprite_direction() -> void:
	if _role_textures.is_empty() or not agent_sprite:
		return
	var sprite_key = DIR_TO_SPRITE.get(_facing_direction, "front")
	if sprite_key != _current_sprite_key and _role_textures.has(sprite_key):
		agent_sprite.texture = _role_textures[sprite_key]
		_current_sprite_key = sprite_key


func _cache_motion_bases() -> void:
	if body_sprite:
		_body_base_position = body_sprite.position
	if agent_sprite and _agent_base_scale == Vector2.ONE:
		_agent_base_scale = agent_sprite.scale
	if packet_sprite and _packet_base_scale == Vector2.ONE:
		_packet_base_scale = packet_sprite.scale
		_packet_base_position = packet_sprite.position
	if shadow_node and _shadow_base_scale == Vector2.ONE:
		_shadow_base_scale = shadow_node.scale
		_shadow_base_position = shadow_node.position
	if aura_node and _aura_base_scale == Vector2.ONE:
		_aura_base_scale = aura_node.scale
		_aura_base_position = aura_node.position


func _get_body_base_position() -> Vector2:
	return _body_base_position


func _get_profile() -> Dictionary:
	return ROLE_PROFILES.get(_role_name, ROLE_PROFILES["default"])


func _apply_role_profile() -> void:
	var profile = _get_profile()
	_fidget_interval = randf_range(float(profile.get("fidget_min", 3.0)), float(profile.get("fidget_max", 8.0)))


func _update_blink(delta: float) -> void:
	_blink_timer -= delta
	if _blink_timer > 0.0:
		return
	_blink_interval -= delta
	if _blink_interval > 0.0:
		return
	_blink_timer = 0.09
	_blink_interval = randf_range(2.5, 6.5)


func _update_sprite_breath(profile: Dictionary) -> void:
	if not agent_sprite:
		return
	var breath = 1.0 + sin(_time * 2.0 + _motion_seed) * 0.015 * float(profile.get("pulse_scale", 1.0))
	var blink_scale = 1.0
	if _blink_timer > 0.0:
		var blink_progress = clampf(_blink_timer / 0.09, 0.0, 1.0)
		blink_scale = 1.0 - blink_progress * 0.3
	agent_sprite.scale = _agent_base_scale * Vector2(breath, blink_scale)


func _update_shadow(offset_y: float, profile: Dictionary) -> void:
	if not shadow_node:
		return
	var depth = clampf(1.0 - abs(offset_y) / 18.0, 0.55, 1.0)
	var stretch = 1.0 + float(profile.get("bob_amplitude", 1.0)) * 0.03
	shadow_node.position = _shadow_base_position + Vector2(0, maxf(offset_y * 0.15, -2.0))
	shadow_node.scale = _shadow_base_scale * Vector2(stretch, depth)
	shadow_node.modulate.a = 0.18 + depth * 0.12


func _update_aura(offset_y: float, profile: Dictionary) -> void:
	if not aura_node:
		return
	var pulse = 0.5 + sin(_time * 2.4 + _motion_seed) * 0.5
	var busy_boost = 0.05 if _is_walking else 0.0
	aura_node.position = _aura_base_position + Vector2(0, -6 + offset_y * 0.08)
	aura_node.scale = _aura_base_scale * Vector2(1.0 + pulse * 0.08, 1.0 + pulse * 0.08)
	var tint = agent_color
	tint.a = 0.12 + pulse * 0.08 + busy_boost
	aura_node.modulate = tint


func _update_packet(offset_y: float, profile: Dictionary) -> void:
	if not packet_sprite or not packet_sprite.visible:
		return
	var packet_float = float(profile.get("packet_float", 1.0))
	var packet_sway = float(profile.get("packet_sway", 1.0))
	packet_sprite.position = _packet_base_position + Vector2(
		sin(_time * 3.2 + _motion_seed) * 1.2 * packet_sway,
		cos(_time * 2.6 + _motion_seed) * 0.8 * packet_float + offset_y * -0.08
	)
	packet_sprite.scale = _packet_base_scale * Vector2(1.0 + packet_float * 0.03, 1.0 + packet_float * 0.03)


func _update_fidget(delta: float) -> void:
	_fidget_timer -= delta
	if _fidget_timer <= 0:
		var profile = _get_profile()
		_fidget_timer = randf_range(float(profile.get("fidget_min", 3.0)), float(profile.get("fidget_max", 8.0)))
		var fidget = randi() % 3
		match fidget:
			0:
				play_squash()
			1:
				# Look-around: change facing to random direction
				_facing_direction = randi() % 8
			2:
				play_stretch()
