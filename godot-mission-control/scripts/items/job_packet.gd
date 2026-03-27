extends Node2D
## Visual representation of a job in the world.
## Can be queued at a station, carried by an agent, or animating.

var job_id: String = ""
var priority: String = "normal"
var state: String = "queued"

@onready var body: ColorRect = $Body
@onready var priority_glow: ColorRect = $PriorityGlow

var _time: float = 0.0

const PRIORITY_COLORS = {
	"low": Color(0.5, 0.5, 0.5, 1),
	"normal": Color(0.35, 0.6, 0.85, 1),
	"high": Color(0.95, 0.6, 0.2, 1),
	"critical": Color(0.9, 0.2, 0.2, 1),
}


func setup(id: String, pri: String) -> void:
	job_id = id
	priority = pri
	_update_color()


func set_state(new_state: String) -> void:
	state = new_state
	match state:
		"completed":
			if body:
				body.color = Color.html("#82e0aa")  # green
		"failed":
			if body:
				body.color = Color.html("#e74c3c")  # red


func _update_color() -> void:
	if body:
		body.color = PRIORITY_COLORS.get(priority, PRIORITY_COLORS["normal"])


func _process(delta: float) -> void:
	_time += delta

	# Pulse effect for high/critical priority
	if priority in ["high", "critical"] and body:
		var pulse = 0.8 + sin(_time * 4.0) * 0.2
		body.self_modulate = Color(pulse, pulse, pulse, 1.0)

	# Processing spin
	if state == "processing":
		rotation = _time * 2.0
