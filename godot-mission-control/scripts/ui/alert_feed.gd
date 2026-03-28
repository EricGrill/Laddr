extends VBoxContainer
## Scrolling list of recent notable events.
## Auto-posts alerts for failures, errors, and saturation.

const MAX_ALERTS = 20
const FADE_DURATION = 10.0

var _alerts: Array = []  # Array of {label: Label, time: float}
var _time: float = 0.0


func _ready() -> void:
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.worker_removed.connect(_on_worker_removed)


func _process(delta: float) -> void:
	_time += delta
	# Fade old alerts
	var to_remove = []
	for alert in _alerts:
		alert["time"] -= delta
		if alert["time"] <= 0:
			to_remove.append(alert)
		else:
			var alpha = clampf(alert["time"] / FADE_DURATION, 0.0, 1.0)
			var node = alert["node"]
			if node:
				node.modulate.a = alpha
				var severity = str(alert.get("severity", "warning"))
				var seed = float(alert.get("seed", 0.0))
				var bar = alert.get("bar", null)
				if bar and bar is ColorRect:
					var pulse = 0.1
					match severity:
						"error":
							pulse = 0.2 + sin(_time * 7.5 + seed) * 0.12
						"warning":
							pulse = 0.15 + sin(_time * 4.0 + seed) * 0.06
						"info":
							pulse = 0.08 + sin(_time * 2.8 + seed) * 0.03
					var base = alert.get("accent", Color.WHITE)
					bar.color = Color(base.r, base.g, base.b, pulse)

	for alert in to_remove:
		alert["node"].queue_free()
		_alerts.erase(alert)


func post_alert(message: String, severity: String = "warning") -> void:
	var row = PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 36)
	row.modulate = Color(1, 1, 1, 0)
	row.scale = Vector2(0.96, 0.96)
	row.pivot_offset = Vector2(0, 18)

	var style = StyleBoxFlat.new()
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	match severity:
		"error":
			style.bg_color = Color(0.18, 0.08, 0.08, 0.96)
			style.border_color = Color(0.95, 0.3, 0.3, 0.75)
		"warning":
			style.bg_color = Color(0.14, 0.11, 0.07, 0.94)
			style.border_color = Color(0.95, 0.7, 0.22, 0.7)
		"info":
			style.bg_color = Color(0.08, 0.11, 0.16, 0.94)
			style.border_color = Color(0.35, 0.75, 0.95, 0.65)
	row.add_theme_stylebox_override("panel", style)

	var layout = HBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	row.add_child(layout)

	var bar = ColorRect.new()
	bar.custom_minimum_size = Vector2(4, 20)
	bar.color = _severity_color(severity, 0.9)
	layout.add_child(bar)

	var label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var settings = LabelSettings.new()
	settings.font_size = 11
	settings.font_color = _severity_color(severity, 1.0)
	label.label_settings = settings
	layout.add_child(label)

	add_child(row)
	move_child(row, 0)  # Newest at top
	_alerts.append({
		"node": row,
		"bar": bar,
		"time": FADE_DURATION,
		"severity": severity,
		"seed": randf_range(0.0, TAU),
		"accent": _severity_color(severity, 1.0),
	})
	_animate_alert_entry(row, severity)

	# Trim old alerts
	while _alerts.size() > MAX_ALERTS:
		var oldest = _alerts.pop_back()
		oldest["node"].queue_free()

	EventBus.alert_posted.emit(message, severity)


func _on_job_failed(job_id: String, reason: String) -> void:
	var msg = "Job %s failed" % job_id.left(12)
	if reason != "":
		msg += ": %s" % reason.left(40)
	post_alert(msg, "error")


func _on_station_changed(station_id: String) -> void:
	var data = WorldState.stations.get(station_id, {})
	var queue = data.get("queueDepth", 0)
	var cap = data.get("capacity", 1)
	if float(queue) / max(cap, 1) > 0.8:
		post_alert("Station %s saturated (%d/%d)" % [station_id, queue, cap], "warning")


func _on_worker_removed(worker_id: String) -> void:
	post_alert("Worker %s disconnected" % worker_id.left(12), "warning")


func _animate_alert_entry(node: Control, severity: String) -> void:
	if not node:
		return
	var tween = node.create_tween()
	tween.set_parallel(true)
	tween.tween_property(node, "modulate", Color(1, 1, 1, 1.0), 0.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var end_scale = Vector2.ONE
	if severity == "error":
		end_scale = Vector2(1.02, 1.02)
	tween.tween_property(node, "scale", end_scale, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _severity_color(severity: String, alpha: float) -> Color:
	match severity:
		"error":
			return Color(0.95, 0.3, 0.3, alpha)
		"warning":
			return Color(0.95, 0.7, 0.22, alpha)
		"info":
			return Color(0.35, 0.75, 0.95, alpha)
		_:
			return Color(1.0, 1.0, 1.0, alpha)
