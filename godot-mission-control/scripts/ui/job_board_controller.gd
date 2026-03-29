extends Control
## Bottom panel showing active/processing jobs with full details.

@onready var title_label: Label = $VBox/Header/Title
@onready var stats_label: Label = $VBox/Header/StatsLabel
@onready var top_border: ColorRect = $TopBorder
@onready var job_list: HBoxContainer = $VBox/ScrollContainer/JobList

var _job_cards: Dictionary = {}  # job_id -> PanelContainer
var _update_timer: float = 0.0
var _time: float = 0.0
var _last_render_signature: String = ""


func _ready() -> void:
	WorldState.snapshot_loaded.connect(_rebuild)
	WorldState.job_changed.connect(_on_job_changed)
	WorldState.metrics_changed.connect(_update_stats)

	# Style header
	if title_label:
		var ts = LabelSettings.new()
		ts.font_size = 14
		ts.font_color = Color(0.2, 0.9, 1.0, 1.0)
		title_label.label_settings = ts

	if stats_label:
		var ss = LabelSettings.new()
		ss.font_size = 12
		ss.font_color = Color(0.7, 0.8, 0.85, 0.9)
		stats_label.label_settings = ss
	if top_border:
		top_border.color = Color(0.2, 0.85, 0.95, 0.7)


func _process(delta: float) -> void:
	_time += delta
	_update_live_pulse()
	_update_timer -= delta
	if _update_timer <= 0:
		_update_timer = 2.0
		_rebuild()


func _rebuild() -> void:
	var signature = _build_render_signature()
	_update_stats_from_world()
	if signature == _last_render_signature:
		return
	_last_render_signature = signature

	# Clear old cards
	for child in job_list.get_children():
		child.queue_free()
	_job_cards.clear()

	# Get processing jobs first, then recent queued
	var processing = []
	var queued = []
	var completed_count = 0
	var failed_count = 0

	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var state = job.get("state", "queued")
		match state:
			"processing":
				processing.append(job)
			"queued":
				queued.append(job)
			"completed":
				completed_count += 1
			"failed":
				failed_count += 1

	_update_stats_from_counts(processing.size(), queued.size(), completed_count, failed_count)

	# Show processing jobs first (most important), then a few queued
	var display_jobs = processing.duplicate()
	# Add a few queued jobs if space
	var remaining_slots = max(0, 8 - display_jobs.size())
	if remaining_slots > 0:
		display_jobs.append_array(queued.slice(0, remaining_slots))

	for job in display_jobs:
		var card = _create_job_card(job)
		job_list.add_child(card)
		var jid = job.get("id", "")
		_job_cards[jid] = card
		_animate_card_entry(card, job.get("state", "queued"))


func _create_job_card(job: Dictionary) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(240, 170)
	panel.modulate = Color(1, 1, 1, 0)
	panel.scale = Vector2(0.96, 0.96)
	panel.pivot_offset = panel.custom_minimum_size / 2.0

	# Style the panel
	var style = StyleBoxFlat.new()
	var state = job.get("state", "queued")
	match state:
		"processing":
			style.bg_color = Color(0.1, 0.15, 0.22, 0.95)
			style.border_color = Color(0.2, 0.85, 0.95, 0.8)
		"queued":
			style.bg_color = Color(0.1, 0.1, 0.15, 0.9)
			style.border_color = Color(0.4, 0.4, 0.5, 0.5)
		"completed":
			style.bg_color = Color(0.08, 0.15, 0.1, 0.9)
			style.border_color = Color(0.3, 0.8, 0.4, 0.7)
		"failed":
			style.bg_color = Color(0.18, 0.08, 0.08, 0.9)
			style.border_color = Color(0.9, 0.3, 0.3, 0.7)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	panel.set_meta("job_state", state)
	panel.set_meta("pulse_seed", randf_range(0.0, TAU))

	var vbox = VBoxContainer.new()
	panel.add_child(vbox)

	var pulse = ColorRect.new()
	pulse.name = "PulseStrip"
	pulse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pulse.custom_minimum_size = Vector2(0, 3)
	pulse.anchor_left = 0.0
	pulse.anchor_top = 0.0
	pulse.anchor_right = 1.0
	pulse.anchor_bottom = 0.0
	pulse.offset_left = 0.0
	pulse.offset_top = 0.0
	pulse.offset_right = 0.0
	pulse.offset_bottom = 3.0
	pulse.color = _state_color(state, 0.0)
	panel.add_child(pulse)

	# State badge
	var state_label = Label.new()
	var state_settings = LabelSettings.new()
	state_settings.font_size = 11
	match state:
		"processing":
			state_label.text = "PROCESSING"
			state_settings.font_color = Color(0.3, 0.95, 1.0, 1.0)
		"queued":
			state_label.text = "QUEUED"
			state_settings.font_color = Color(0.6, 0.6, 0.7, 0.8)
		"completed":
			state_label.text = "COMPLETED"
			state_settings.font_color = Color(0.4, 0.9, 0.5, 1.0)
		"failed":
			state_label.text = "FAILED"
			state_settings.font_color = Color(0.95, 0.3, 0.3, 1.0)
	state_label.label_settings = state_settings
	vbox.add_child(state_label)

	# Job title - extract from "type" field (which is the prompt/system prompt)
	var raw_type = str(job.get("type", "Unknown Job"))
	var title = _extract_title(raw_type)
	var title_label_node = Label.new()
	title_label_node.text = title
	var title_settings = LabelSettings.new()
	title_settings.font_size = 13
	title_settings.font_color = Color.WHITE
	title_label_node.label_settings = title_settings
	title_label_node.autowrap_mode = TextServer.AUTOWRAP_WORD
	title_label_node.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(title_label_node)

	# Job ID (short)
	var id_label = Label.new()
	id_label.text = str(job.get("id", "")).left(8)
	var id_settings = LabelSettings.new()
	id_settings.font_size = 10
	id_settings.font_color = Color(0.5, 0.55, 0.6, 0.7)
	id_label.label_settings = id_settings
	vbox.add_child(id_label)

	# Priority
	var pri = job.get("priority", "normal")
	var pri_label = Label.new()
	var pri_settings = LabelSettings.new()
	pri_settings.font_size = 11
	match pri:
		"critical":
			pri_label.text = "CRITICAL"
			pri_settings.font_color = Color(1.0, 0.3, 0.3, 1.0)
		"high":
			pri_label.text = "HIGH"
			pri_settings.font_color = Color(1.0, 0.7, 0.2, 1.0)
		"normal":
			pri_label.text = "NORMAL"
			pri_settings.font_color = Color(0.5, 0.7, 0.9, 0.8)
		"low":
			pri_label.text = "LOW"
			pri_settings.font_color = Color(0.5, 0.5, 0.5, 0.7)
	pri_label.label_settings = pri_settings
	vbox.add_child(pri_label)

	# Time info
	var created = str(job.get("createdAt", ""))
	if created.length() > 16:
		created = created.substr(11, 5)  # Extract HH:MM
	var time_label = Label.new()
	time_label.text = "Created: %s" % created
	var time_settings = LabelSettings.new()
	time_settings.font_size = 10
	time_settings.font_color = Color(0.5, 0.6, 0.65, 0.7)
	time_label.label_settings = time_settings
	vbox.add_child(time_label)

	return panel


func _extract_title(raw: String) -> String:
	# The "type" field contains the system prompt. Extract a meaningful title.
	# Look for markdown heading: # Title
	var lines = raw.split("\n")
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed.begins_with("# "):
			return trimmed.substr(2).left(40)
		if trimmed.begins_with("## "):
			return trimmed.substr(3).left(40)
	# Fallback: first non-empty line, truncated
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed != "":
			return trimmed.left(40)
	return "Unknown Job"


func _on_job_changed(_job_id: String) -> void:
	# Will be refreshed on next timer tick
	_update_timer = 0


func _update_stats() -> void:
	_update_stats_from_world()
	_update_timer = 0  # Force rebuild on next frame


func _update_stats_from_counts(processing: int, queued: int, completed: int, failed: int) -> void:
	if stats_label:
		# Use real Redis queue depth if available (DB is capped at 100)
		var real_q = WorldState.metrics.get("realQueueDepth", queued)
		if real_q > queued:
			queued = real_q
		stats_label.text = "Queued: %d | Processing: %d | Done: %d | Failed: %d" % [
			queued, processing, completed, failed
		]


func _update_stats_from_world() -> void:
	# Use real metrics instead of counting from capped job snapshot
	var queued = WorldState.metrics.get("realQueueDepth", 0)
	var processing = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "") == "processing":
			processing += 1
	var throughput = WorldState.metrics.get("throughput", {})
	var completed = throughput.get("completed", {}).get("24h", 0)
	var failed = throughput.get("failed", {}).get("24h", 0)
	_update_stats_from_counts(processing, queued, completed, failed)


func _build_render_signature() -> String:
	var parts: Array[String] = []
	for jid in WorldState.jobs:
		parts.append(_job_state_signature(WorldState.jobs[jid]))
	parts.sort()
	return "|".join(parts)


func _job_state_signature(job: Dictionary) -> String:
	return "%s:%s:%s:%s:%s" % [
		str(job.get("id", "")),
		str(job.get("state", "queued")),
		str(job.get("priority", "normal")),
		str(job.get("assignedAgentId", "")),
		str(job.get("currentStationId", "")),
	]


func _animate_card_entry(card: PanelContainer, state: String) -> void:
	if not card:
		return
	var tween = card.create_tween()
	tween.set_parallel(true)
	var duration = 0.22
	if state == "processing":
		duration = 0.26
	elif state == "failed":
		duration = 0.24
	tween.tween_property(card, "modulate", Color(1, 1, 1, 1.0), duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2.ONE, duration + 0.02).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_live_pulse() -> void:
	if not top_border:
		return
	var processing = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "queued") == "processing":
			processing += 1
	var pulse = 0.0
	if processing > 0:
		pulse = 0.12 + sin(_time * 2.2) * 0.08
		top_border.color = Color(0.2 + pulse, 0.82 + pulse * 0.8, 0.95, 0.55 + pulse)
	else:
		top_border.color = Color(0.2, 0.85, 0.95, 0.45)

	for jid in _job_cards:
		var card = _job_cards[jid]
		if not card:
			continue
		var state = str(card.get_meta("job_state", "queued"))
		var seed = float(card.get_meta("pulse_seed", 0.0))
		var strip = card.get_node_or_null("PulseStrip")
		if strip and strip is ColorRect:
			strip.color = _state_color(state, 0.12 if state == "queued" else 0.2)
			if state == "processing":
				strip.color.a = 0.2 + sin(_time * 3.0 + seed) * 0.12
			elif state == "completed":
				strip.color.a = 0.14 + sin(_time * 1.8 + seed) * 0.06
			elif state == "failed":
				strip.color.a = 0.18 + sin(_time * 6.0 + seed) * 0.12
			else:
				strip.color.a = 0.08 + sin(_time * 1.4 + seed) * 0.04


func _state_color(state: String, alpha: float = 1.0) -> Color:
	match state:
		"processing":
			return Color(0.2, 0.85, 0.95, alpha)
		"completed":
			return Color(0.35, 0.8, 0.45, alpha)
		"failed":
			return Color(0.95, 0.35, 0.35, alpha)
		"queued":
			return Color(0.6, 0.6, 0.7, alpha)
		_:
			return Color(0.5, 0.7, 0.9, alpha)
