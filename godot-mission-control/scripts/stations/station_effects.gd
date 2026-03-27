extends Node
## Drives station-specific animations based on type and state.
## Attached as a child of station_controller.

var station_type: String = ""
var station_state: String = "idle"
var queue_depth: int = 0
var capacity: int = 1

var _time: float = 0.0
var _parent: Node2D


func _ready() -> void:
	_parent = get_parent()


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

	var saturation = float(queue_depth) / max(capacity, 1)

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


func _animate_intake(saturation: float) -> void:
	# Mailbox flag wobble when queue grows
	var wobble = sin(_time * 3.0) * (2.0 + saturation * 5.0)
	# Applied to a child node if it exists
	var flag = _parent.get_node_or_null("Flag")
	if flag:
		flag.rotation_degrees = wobble


func _animate_router(saturation: float) -> void:
	# Spinning tray — faster when busy
	var speed = 1.0 + saturation * 3.0
	var tray = _parent.get_node_or_null("Tray")
	if tray:
		tray.rotation += speed * 0.02


func _animate_research(saturation: float) -> void:
	# Floating books — orbit faster when busy
	var speed = 1.0 + saturation * 2.0
	var books = _parent.get_node_or_null("Books")
	if books:
		books.position = Vector2(cos(_time * speed) * 15, sin(_time * speed) * 8)


func _animate_code(saturation: float) -> void:
	# Screen flicker
	var screen = _parent.get_node_or_null("Screen")
	if screen and screen is ColorRect:
		var brightness = 0.3 + saturation * 0.5 + sin(_time * 10.0) * 0.1
		screen.color = Color(0.1, brightness, 0.2, 1.0)


func _animate_review(saturation: float) -> void:
	# Magnifying glass bob
	var glass = _parent.get_node_or_null("Glass")
	if glass:
		glass.position.y = sin(_time * 2.0) * 4.0


func _animate_output(saturation: float) -> void:
	# Conveyor belt movement
	var belt = _parent.get_node_or_null("Belt")
	if belt:
		belt.position.x = fmod(_time * 20.0, 10.0)


func _animate_supervisor(saturation: float) -> void:
	# Alert lights blink
	var alert = _parent.get_node_or_null("AlertLight")
	if alert and alert is ColorRect:
		alert.visible = saturation > 0.5 and fmod(_time, 1.0) > 0.5


func _animate_error(saturation: float) -> void:
	# Red lamp flash
	var lamp = _parent.get_node_or_null("Lamp")
	if lamp and lamp is ColorRect:
		var flash = 0.5 + sin(_time * 6.0) * 0.5
		lamp.color = Color(flash, 0, 0, 1.0)
	# Bin wobble
	if _parent:
		_parent.rotation = sin(_time * 4.0) * deg_to_rad(1.0 + saturation * 3.0)
