extends Node
## Agent animation: smooth directional sprite swapping, gentle walk,
## subtle idle breathing, emotes. Designed for chibi sprites.

@export var walk_bob: float = 3.0
@export var walk_speed: float = 5.0
@export var idle_bob: float = 1.5
@export var idle_speed: float = 1.2
@export var squash_duration: float = 0.15

var _time: float = 0.0
var _is_walking: bool = false
var _squash_timer: float = 0.0
var _squash_type: String = ""
var _facing_direction: int = 0
var _motion_seed: float = 0.0

var body_sprite: Node2D
var agent_sprite: Sprite2D
var mover: Node = null
var agent_color: Color = Color.WHITE
var packet_sprite: Sprite2D = null
var shadow_node: CanvasItem = null
var aura_node: CanvasItem = null

var _role_textures: Dictionary = {}
var _current_sprite_key: String = "front"
var _body_base_position: Vector2 = Vector2.ZERO
var _agent_base_scale: Vector2 = Vector2.ONE
var _packet_base_position: Vector2 = Vector2.ZERO
var _packet_base_scale: Vector2 = Vector2.ONE
var _shadow_base_position: Vector2 = Vector2.ZERO
var _shadow_base_scale: Vector2 = Vector2.ONE
var _aura_base_position: Vector2 = Vector2.ZERO
var _aura_base_scale: Vector2 = Vector2.ONE

var _fidget_timer: float = 0.0
var _playback_speed: float = 1.0
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

const DIR_TO_SPRITE = {
	0: "front", 1: "iso_left", 2: "iso_left", 3: "iso_left",
	4: "front", 5: "iso_right", 6: "iso_right", 7: "iso_right",
}


func _ready() -> void:
	_motion_seed = randf() * TAU
	_fidget_timer = randf_range(4.0, 10.0)
	EventBus.playback_speed_changed.connect(func(speed): _playback_speed = speed)


func set_body_sprite(sprite: Node2D) -> void:
	body_sprite = sprite
	if body_sprite:
		_body_base_position = body_sprite.position

func set_agent_sprite(sprite: Sprite2D) -> void:
	agent_sprite = sprite
	if agent_sprite:
		_agent_base_scale = agent_sprite.scale

func set_mover(node: Node) -> void:
	mover = node

func set_packet_sprite(sprite: Sprite2D) -> void:
	packet_sprite = sprite
	if packet_sprite:
		_packet_base_position = packet_sprite.position
		_packet_base_scale = packet_sprite.scale

func set_shadow_node(node: CanvasItem) -> void:
	shadow_node = node
	if shadow_node:
		_shadow_base_position = shadow_node.position
		_shadow_base_scale = shadow_node.scale

func set_aura_node(node: CanvasItem) -> void:
	aura_node = node
	if aura_node:
		_aura_base_position = aura_node.position
		_aura_base_scale = aura_node.scale

func set_role_profile(_role: String) -> void:
	pass  # Simplified — no per-role animation tweaks

func set_role_textures(textures: Dictionary) -> void:
	_role_textures = textures

func set_walking(walking: bool) -> void:
	_is_walking = walking

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
	_emote_node.position = Vector2(-4, -40)
	var settings = LabelSettings.new()
	settings.font_size = 16
	settings.font_color = Color.WHITE
	settings.outline_size = 2
	settings.outline_color = Color.BLACK
	_emote_node.label_settings = settings
	if body_sprite:
		body_sprite.add_child(_emote_node)
	_emote_timer = EMOTE_DURATION


func _process(delta: float) -> void:
	_time += delta * _playback_speed

	if not body_sprite:
		return

	# Update emote
	if _emote_timer > 0:
		_emote_timer -= delta
		if _emote_timer <= 0 and _emote_node:
			_emote_node.queue_free()
			_emote_node = null
		elif _emote_node:
			_emote_node.position.y -= delta * 4.0
			_emote_node.modulate.a = clampf(_emote_timer / EMOTE_DURATION, 0.0, 1.0)

	# Update facing direction from mover
	if mover and mover.velocity_direction.length() > 0.1:
		var angle = mover.velocity_direction.angle()
		_facing_direction = int(round(angle / (PI / 4))) % 8
		if _facing_direction < 0:
			_facing_direction += 8

	# Swap sprite based on direction
	if not _role_textures.is_empty() and agent_sprite:
		var key = DIR_TO_SPRITE.get(_facing_direction, "front")
		if key != _current_sprite_key and _role_textures.has(key):
			agent_sprite.texture = _role_textures[key]
			_current_sprite_key = key

	# Animation
	var offset_y = 0.0
	var scale_mod = Vector2.ONE

	if _is_walking:
		# Smooth walk: gentle vertical bounce, NO rotation/wobble
		offset_y = -abs(sin(_time * walk_speed)) * walk_bob
	else:
		# Idle: very gentle breathing bob
		offset_y = sin(_time * idle_speed + _motion_seed) * idle_bob
		# Occasional fidget
		_fidget_timer -= delta
		if _fidget_timer <= 0:
			_fidget_timer = randf_range(5.0, 12.0)
			if randi() % 2 == 0:
				play_squash()
			else:
				_facing_direction = randi() % 8

	# Squash/stretch
	if _squash_timer > 0:
		_squash_timer -= delta
		var t = _squash_timer / squash_duration
		if _squash_type == "squash":
			scale_mod = Vector2(1.0 + 0.12 * t, 1.0 - 0.08 * t)
		else:
			scale_mod = Vector2(1.0 - 0.06 * t, 1.0 + 0.12 * t)

	# Apply to body — ONLY vertical offset, no rotation, no sway
	body_sprite.position = _body_base_position + Vector2(0, offset_y)
	body_sprite.scale = scale_mod
	body_sprite.rotation = 0.0  # Never rotate

	# Subtle breathing on sprite
	if agent_sprite:
		var breath = 1.0 + sin(_time * 1.5 + _motion_seed) * 0.008
		agent_sprite.scale = _agent_base_scale * breath

	# Shadow tracks body
	if shadow_node:
		var depth = clampf(1.0 - abs(offset_y) / 20.0, 0.7, 1.0)
		shadow_node.position = _shadow_base_position
		shadow_node.modulate.a = 0.18 + depth * 0.08

	# Aura gentle pulse
	if aura_node:
		var pulse = 0.5 + sin(_time * 1.5 + _motion_seed) * 0.5
		aura_node.modulate = Color(agent_color.r, agent_color.g, agent_color.b, 0.08 + pulse * 0.04)

	# Packet floats gently above
	if packet_sprite and packet_sprite.visible:
		packet_sprite.position = _packet_base_position + Vector2(0, sin(_time * 2.0) * 1.5 + offset_y * -0.05)
