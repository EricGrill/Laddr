extends Node2D
## Emperor Sidious — Venice overflow agent.
## Sits dormant at Command Deck. Wakes when queue > 100.
## Visually: sleeping on throne → eyes glow, lightning crackles when active.

var _sprite: Sprite2D
var _label: Label
var _status_card: Node2D
var _status_text: Label
var _is_awake: bool = false
var _lightning_particles: Array = []
var _lightning_timer: float = 0.0
var _pulse_time: float = 0.0

const WAKE_THRESHOLD = 100
const SPRITE_BASE = "res://assets/sprites/workers/sidious/"


func _ready() -> void:
	# Create sprite
	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(0.45, 0.45)
	var tex = load(SPRITE_BASE + "sidious_front.png")
	if tex:
		_sprite.texture = tex
	_sprite.modulate = Color(0.4, 0.4, 0.5, 0.7)  # Dim = sleeping
	add_child(_sprite)

	# Name label
	_label = Label.new()
	_label.text = "Sidious"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-30, 35)
	_label.size = Vector2(60, 20)
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 11
	lbl_settings.font_color = Color(0.7, 0.5, 0.9, 0.9)
	lbl_settings.outline_size = 2
	lbl_settings.outline_color = Color(0, 0, 0, 0.7)
	_label.label_settings = lbl_settings
	add_child(_label)

	# Status card (hidden until awake)
	_status_card = Node2D.new()
	_status_card.visible = false
	_status_card.position = Vector2(0, -80)

	var bg = ColorRect.new()
	bg.size = Vector2(160, 50)
	bg.position = Vector2(-80, -30)
	bg.color = Color(0.15, 0.05, 0.2, 0.92)
	_status_card.add_child(bg)

	var border = ColorRect.new()
	border.size = Vector2(160, 2)
	border.position = Vector2(-80, -30)
	border.color = Color(0.6, 0.2, 0.9, 0.9)
	_status_card.add_child(border)

	_status_text = Label.new()
	_status_text.position = Vector2(-74, -26)
	_status_text.size = Vector2(148, 44)
	var st_settings = LabelSettings.new()
	st_settings.font_size = 11
	st_settings.font_color = Color(0.9, 0.7, 1.0, 1.0)
	_status_text.label_settings = st_settings
	_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_card.add_child(_status_text)
	add_child(_status_card)

	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot)


func _on_snapshot() -> void:
	_check_overflow()


func _on_metrics_changed() -> void:
	_check_overflow()


func _check_overflow() -> void:
	var metrics = WorldState.metrics
	var queue = metrics.get("realQueueDepth", 0)
	var overflow = metrics.get("overflowActive", false)
	var spend = metrics.get("dailyVeniceSpend", 0.0)
	var budget = metrics.get("dailyVeniceBudget", 5.0)

	if overflow and not _is_awake:
		_wake_up()
	elif not overflow and _is_awake:
		_go_to_sleep()

	if _is_awake:
		_status_text.text = "OVERFLOW ACTIVE\nQueue: %d\nVenice: $%.2f/$%.0f" % [queue, spend, budget]


func _wake_up() -> void:
	_is_awake = true
	_status_card.visible = true
	_label.text = "Sidious [ACTIVE]"

	# Dramatic wake: brighten sprite, add purple glow
	var tween = create_tween()
	tween.tween_property(_sprite, "modulate", Color(1.0, 0.85, 1.0, 1.0), 0.5)

	# Spawn lightning particles
	for i in range(4):
		var bolt = ColorRect.new()
		bolt.size = Vector2(2, 12)
		bolt.color = Color(0.7, 0.3, 1.0, 0.8)
		bolt.position = Vector2(randf_range(-30, 30), randf_range(-40, -10))
		_sprite.add_child(bolt)
		_lightning_particles.append(bolt)


func _go_to_sleep() -> void:
	_is_awake = false
	_status_card.visible = false
	_label.text = "Sidious"

	var tween = create_tween()
	tween.tween_property(_sprite, "modulate", Color(0.4, 0.4, 0.5, 0.7), 1.0)

	# Remove lightning
	for bolt in _lightning_particles:
		if is_instance_valid(bolt):
			bolt.queue_free()
	_lightning_particles.clear()


func _process(delta: float) -> void:
	if not _is_awake:
		# Gentle idle bob
		_sprite.position.y = sin(Time.get_ticks_msec() / 2000.0) * 1.5
		return

	_pulse_time += delta

	# Lightning flicker
	for bolt in _lightning_particles:
		if is_instance_valid(bolt):
			bolt.visible = randf() > 0.3
			bolt.position = Vector2(randf_range(-35, 35), randf_range(-45, -5))
			bolt.rotation = randf_range(-0.5, 0.5)

	# Sprite energy pulse
	var pulse = 0.85 + sin(_pulse_time * 3.0) * 0.15
	_sprite.modulate = Color(pulse, pulse * 0.8, 1.0, 1.0)

	# Status card float
	_status_card.position.y = -80 + sin(_pulse_time * 1.5) * 3.0
