extends Node
## Handles blob charm: 8-directional wobble walk, squash/stretch, idle bob, emotes.
## Reads velocity_direction from sibling AgentMover to determine facing.
## Inspired by Godot isometric demo's 8-directional animation system.

@export var wobble_amplitude: float = 3.0
@export var wobble_speed: float = 8.0
@export var bob_amplitude: float = 2.0
@export var bob_speed: float = 2.0
@export var squash_duration: float = 0.15

var _time: float = 0.0
var _is_walking: bool = false
var _squash_timer: float = 0.0
var _squash_type: String = ""  # "squash" or "stretch"
var _facing_direction: int = 0  # 0-7, like goblin.gd (S, SW, W, NW, N, NE, E, SE)

var body_sprite: Node2D  # Set by agent controller
var shadow_sprite: Node2D
var eyes_sprite: Node2D
var mover: Node = null  # AgentMover reference, set by controller

# Idle fidget
var _fidget_timer: float = 0.0
var _fidget_interval: float = 5.0  # randomized


func _ready() -> void:
	_fidget_interval = randf_range(3.0, 8.0)


func set_walking(walking: bool) -> void:
	_is_walking = walking


func play_squash() -> void:
	_squash_timer = squash_duration
	_squash_type = "squash"


func play_stretch() -> void:
	_squash_timer = squash_duration
	_squash_type = "stretch"


func _process(delta: float) -> void:
	_time += delta

	if not body_sprite:
		return

	# Update facing direction from mover velocity (8-directional, like goblin.gd)
	if mover and mover.velocity_direction.length() > 0.1:
		var angle = mover.velocity_direction.angle()
		# Divide into 8 slices of 45 degrees each, offset by 22.5 degrees
		_facing_direction = int(round(angle / (PI / 4))) % 8
		if _facing_direction < 0:
			_facing_direction += 8

	# Update eye positions based on facing direction (simulate looking)
	_update_eye_direction()

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


func _update_eye_direction() -> void:
	if not eyes_sprite:
		return
	# Shift eyes in the direction the blob is facing
	# 8 directions: S=0, SW=1, W=2, NW=3, N=4, NE=5, E=6, SE=7
	var offsets = [
		Vector2(0, 1),    # S
		Vector2(-1, 1),   # SW
		Vector2(-1, 0),   # W
		Vector2(-1, -1),  # NW
		Vector2(0, -1),   # N
		Vector2(1, -1),   # NE
		Vector2(1, 0),    # E
		Vector2(1, 1),    # SE
	]
	var offset = offsets[_facing_direction] * 1.5
	eyes_sprite.position = offset


func _update_fidget(delta: float) -> void:
	_fidget_timer -= delta
	if _fidget_timer <= 0:
		_fidget_timer = randf_range(3.0, 8.0)
		# Tiny hop
		play_squash()
