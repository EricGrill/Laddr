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

var body_sprite: Node2D  # Body node, set by agent controller
var agent_sprite: Sprite2D  # The actual sprite, set by agent controller
var mover: Node = null  # AgentMover reference, set by controller

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
	_fidget_interval = randf_range(3.0, 8.0)
	EventBus.playback_speed_changed.connect(func(speed): _playback_speed = speed)


func set_walking(walking: bool) -> void:
	_is_walking = walking


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

	var offset_y = 0.0
	var rotation_z = 0.0
	var scale_mod = Vector2.ONE

	if _is_walking:
		# Wobble walk: sinusoidal rotation + vertical bounce
		rotation_z = sin(_time * wobble_speed) * deg_to_rad(wobble_amplitude)
		offset_y = -abs(sin(_time * wobble_speed * 0.5)) * 4.0
	else:
		# Idle bob
		offset_y = sin(_time * bob_speed) * bob_amplitude
		_update_fidget(delta)

	# Squash/stretch
	if _squash_timer > 0:
		_squash_timer -= delta
		var t = _squash_timer / squash_duration
		if _squash_type == "squash":
			scale_mod = Vector2(1.0 + 0.2 * t, 1.0 - 0.15 * t)
		else:
			scale_mod = Vector2(1.0 - 0.1 * t, 1.0 + 0.2 * t)

	body_sprite.rotation = rotation_z
	body_sprite.position.y = offset_y
	body_sprite.scale = scale_mod


func _update_sprite_direction() -> void:
	if _role_textures.is_empty() or not agent_sprite:
		return
	var sprite_key = DIR_TO_SPRITE.get(_facing_direction, "front")
	if sprite_key != _current_sprite_key and _role_textures.has(sprite_key):
		agent_sprite.texture = _role_textures[sprite_key]
		_current_sprite_key = sprite_key


func _update_fidget(delta: float) -> void:
	_fidget_timer -= delta
	if _fidget_timer <= 0:
		_fidget_timer = randf_range(3.0, 8.0)
		var fidget = randi() % 3
		match fidget:
			0:
				play_squash()
			1:
				# Look-around: change facing to random direction
				_facing_direction = randi() % 8
			2:
				play_stretch()
