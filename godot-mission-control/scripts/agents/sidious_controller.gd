extends Node2D
## Emperor Sidious — Venice overflow agent.
## Sits dormant at Command Deck. Wakes when queue > 100.
## Shows OVERFLOW ACTIVE, BUDGET EXHAUSTED, or sleeping.

var _sprite: Sprite2D
var _label: Label
var _status_card: Node2D
var _status_text: Label
var _is_awake: bool = false
var _lightning_particles: Array = []
var _pulse_time: float = 0.0

const WAKE_THRESHOLD = 100
const SPRITE_BASE = "res://assets/sprites/workers/sidious/"


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(0.45, 0.45)
	var tex = load(SPRITE_BASE + "sidious_front.png")
	if tex:
		_sprite.texture = tex
	_sprite.modulate = Color(0.4, 0.4, 0.5, 0.7)
	add_child(_sprite)

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

	# Status card
	_status_card = Node2D.new()
	_status_card.visible = false
	_status_card.position = Vector2(0, -80)

	var bg = ColorRect.new()
	bg.size = Vector2(200, 80)
	bg.position = Vector2(-100, -45)
	bg.color = Color(0.12, 0.04, 0.18, 0.92)
	_status_card.add_child(bg)

	var border = ColorRect.new()
	border.size = Vector2(200, 2)
	border.position = Vector2(-100, -45)
	border.color = Color(0.6, 0.2, 0.9, 0.9)
	_status_card.add_child(border)

	_status_text = Label.new()
	_status_text.position = Vector2(-94, -40)
	_status_text.size = Vector2(188, 72)
	var st_settings = LabelSettings.new()
	st_settings.font_size = 12
	st_settings.font_color = Color(0.9, 0.7, 1.0, 1.0)
	_status_text.label_settings = st_settings
	_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_card.add_child(_status_text)
	add_child(_status_card)

	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot)


func _on_snapshot() -> void:
	_check_state()

func _on_metrics_changed() -> void:
	_check_state()


func _check_state() -> void:
	var metrics = WorldState.metrics
	var queue = metrics.get("realQueueDepth", 0)
	var spend = metrics.get("dailyVeniceSpend", 0.0)
	var budget = metrics.get("dailyVeniceBudget", 5.0)

	var should_wake = queue > WAKE_THRESHOLD

	if should_wake and not _is_awake:
		_wake_up()
	elif not should_wake and _is_awake:
		_go_to_sleep()

	if _is_awake:
		var processing_count = 0
		var job_title = ""
		for jid in WorldState.jobs:
			var job = WorldState.jobs[jid]
			if job.get("state", "") == "processing":
				processing_count += 1
				if job_title == "":
					var raw = str(job.get("type", ""))
					for line in raw.split("\n"):
						var t = line.strip_edges()
						if t.begins_with("# "):
							job_title = t.substr(2).left(24)
							break

		var budget_exhausted = spend >= budget
		var lines = []

		if budget_exhausted:
			lines.append("BUDGET EXHAUSTED")
			lines.append("Local workers only")
		else:
			lines.append("OVERFLOW ACTIVE")
			if job_title != "":
				lines.append(job_title)

		lines.append("Q:%d | Run:%d" % [queue, processing_count])
		lines.append("Workers: %d online" % WorldState.workers.size())
		_status_text.text = "\n".join(lines)

		# Change lightning color based on budget state
		var bolt_color = Color(1.0, 0.3, 0.3, 0.8) if budget_exhausted else Color(0.7, 0.3, 1.0, 0.8)
		for bolt in _lightning_particles:
			if is_instance_valid(bolt):
				bolt.color = bolt_color


func _wake_up() -> void:
	_is_awake = true
	_status_card.visible = true
	_label.text = "Sidious"

	var tween = create_tween()
	tween.tween_property(_sprite, "modulate", Color(1.0, 0.85, 1.0, 1.0), 0.5)

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

	for bolt in _lightning_particles:
		if is_instance_valid(bolt):
			bolt.queue_free()
	_lightning_particles.clear()


func _process(delta: float) -> void:
	if not _is_awake:
		_sprite.position.y = sin(Time.get_ticks_msec() / 2000.0) * 1.5
		return

	_pulse_time += delta

	for bolt in _lightning_particles:
		if is_instance_valid(bolt):
			bolt.visible = randf() > 0.3
			bolt.position = Vector2(randf_range(-35, 35), randf_range(-45, -5))

	var pulse = 0.85 + sin(_pulse_time * 3.0) * 0.15
	_sprite.modulate = Color(pulse, pulse * 0.8, 1.0, 1.0)
	_status_card.position.y = -80 + sin(_pulse_time * 1.5) * 2.0
