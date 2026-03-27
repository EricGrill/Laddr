extends Node2D
## Visual representation of a job in the world.
## Can be queued at a station, carried by an agent, or animating.

var job_id: String = ""
var priority: String = "normal"
var state: String = "queued"

@onready var body: Sprite2D = $Body

var _time: float = 0.0

const PACKET_SPRITE_BASE = "res://assets/sprites/packets/packet_"

# Preload packet textures
var _packet_textures: Dictionary = {}


func _ready() -> void:
	for pri in ["low", "normal", "high", "critical"]:
		var tex = load(PACKET_SPRITE_BASE + pri + ".png")
		if tex:
			_packet_textures[pri] = tex


func setup(id: String, pri: String) -> void:
	job_id = id
	priority = pri
	_update_sprite()


func set_state(new_state: String) -> void:
	state = new_state
	match state:
		"completed":
			if body:
				body.modulate = Color(0.5, 1.0, 0.7, 1)  # green tint
		"failed":
			if body:
				body.modulate = Color(1.3, 0.5, 0.5, 1)  # red tint


func _update_sprite() -> void:
	if body:
		if _packet_textures.has(priority):
			body.texture = _packet_textures[priority]
		elif _packet_textures.has("normal"):
			body.texture = _packet_textures["normal"]


func _process(delta: float) -> void:
	_time += delta

	# Pulse effect for high/critical priority
	if priority in ["high", "critical"] and body:
		var pulse = 0.8 + sin(_time * 4.0) * 0.2
		body.self_modulate = Color(pulse, pulse, pulse, 1.0)

	# Processing spin
	if state == "processing":
		rotation = _time * 2.0
