extends Node2D
## Triage Droid — scans and sorts jobs at the Dispatcher station.
## Visually picks up bricks, scans them, re-sorts by priority.
## Always active — shows job classification in its status card.

var _sprite: Sprite2D
var _label: Label
var _status_card: Node2D
var _status_text: Label
var _scan_timer: float = 0.0
var _scan_interval: float = 3.0
var _is_scanning: bool = false
var _scan_target: Vector2 = Vector2.ZERO
var _home_pos: Vector2 = Vector2.ZERO
var _sprite_textures: Dictionary = {}
var _jobs_scanned: int = 0

const SPRITE_BASE = "res://assets/sprites/workers/triage/"
const DIRECTIONS = ["front", "iso_left", "iso_right"]


func _ready() -> void:
	_home_pos = position

	# Load textures
	for dir in DIRECTIONS:
		var tex = load(SPRITE_BASE + "triage_" + dir + ".png")
		if tex:
			_sprite_textures[dir] = tex

	# Create sprite
	_sprite = Sprite2D.new()
	_sprite.scale = Vector2(0.4, 0.4)
	if _sprite_textures.has("front"):
		_sprite.texture = _sprite_textures["front"]
	add_child(_sprite)

	# Name label
	_label = Label.new()
	_label.text = "Triage Droid"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-40, 30)
	_label.size = Vector2(80, 20)
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 10
	lbl_settings.font_color = Color(0.5, 0.85, 1.0, 0.9)
	lbl_settings.outline_size = 2
	lbl_settings.outline_color = Color(0, 0, 0, 0.7)
	_label.label_settings = lbl_settings
	add_child(_label)

	# Status card
	_status_card = Node2D.new()
	_status_card.position = Vector2(0, -65)

	var bg = ColorRect.new()
	bg.size = Vector2(140, 45)
	bg.position = Vector2(-70, -28)
	bg.color = Color(0.06, 0.12, 0.18, 0.92)
	_status_card.add_child(bg)

	var border = ColorRect.new()
	border.size = Vector2(140, 2)
	border.position = Vector2(-70, -28)
	border.color = Color(0.3, 0.8, 1.0, 0.9)
	_status_card.add_child(border)

	_status_text = Label.new()
	_status_text.position = Vector2(-64, -24)
	_status_text.size = Vector2(128, 40)
	var st_settings = LabelSettings.new()
	st_settings.font_size = 10
	st_settings.font_color = Color(0.7, 0.92, 1.0, 1.0)
	_status_text.label_settings = st_settings
	_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_card.add_child(_status_text)
	add_child(_status_card)

	WorldState.snapshot_loaded.connect(_on_snapshot)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.metrics_changed.connect(_update_stats)


func _on_snapshot() -> void:
	_jobs_scanned = WorldState.jobs.size()
	_update_stats()


func _on_job_changed(_job_id: String) -> void:
	_jobs_scanned += 1
	_trigger_scan()


func _trigger_scan() -> void:
	if not _is_scanning:
		_is_scanning = true
		_scan_timer = 1.5


func _update_stats() -> void:
	var queued = 0
	var processing = 0
	var simple = 0
	var complex_count = 0

	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var state = job.get("state", "")
		if state == "queued":
			queued += 1
			# Estimate complexity from job type text
			var jtype = str(job.get("type", "")).to_lower()
			if _is_simple(jtype):
				simple += 1
			else:
				complex_count += 1
		elif state == "processing":
			processing += 1

	# Use real queue depth from metrics (DB caps at 100)
	var real_q = WorldState.metrics.get("realQueueDepth", queued)
	if real_q > queued:
		queued = real_q

	var lines = []
	if queued > 0:
		lines.append("SCANNING QUEUE")
		lines.append("Total: %d jobs" % queued)
		if simple > 0 or complex_count > 0:
			lines.append("%d fast / %d deep" % [simple, complex_count])
		lines.append("Processing: %d" % processing)
	else:
		lines.append("QUEUE CLEAR")
		lines.append("Standing by...")
	_status_text.text = "\n".join(lines)


func _is_simple(text: String) -> bool:
	for kw in ["summarize", "translate", "classify", "list", "format", "extract"]:
		if kw in text:
			return true
	return false


func _process(delta: float) -> void:
	# Scanning animation
	if _is_scanning:
		_scan_timer -= delta
		# Wobble while scanning
		_sprite.rotation = sin(Time.get_ticks_msec() / 150.0) * 0.08
		if _scan_timer <= 0:
			_is_scanning = false
			_sprite.rotation = 0
			_update_stats()
	else:
		# Idle bob
		_sprite.position.y = sin(Time.get_ticks_msec() / 1500.0) * 2.0

	# Scan beam effect (cyan line flashes when scanning)
	_status_card.position.y = -65 + sin(Time.get_ticks_msec() / 1200.0) * 2.0

	# Face direction based on queue state
	var queued = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "") == "queued":
			queued += 1

	if queued > 50 and _sprite_textures.has("iso_left"):
		_sprite.texture = _sprite_textures["iso_left"]  # Looking at intake
	elif _is_scanning and _sprite_textures.has("iso_right"):
		_sprite.texture = _sprite_textures["iso_right"]  # Scanning dispatcher
	elif _sprite_textures.has("front"):
		_sprite.texture = _sprite_textures["front"]
