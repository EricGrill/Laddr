extends VBoxContainer
## Scrolling list of recent notable events.
## Auto-posts alerts for failures, errors, and saturation.

const MAX_ALERTS = 20
const FADE_DURATION = 10.0

var _alerts: Array = []  # Array of {label: Label, time: float}


func _ready() -> void:
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.worker_removed.connect(_on_worker_removed)


func _process(delta: float) -> void:
	# Fade old alerts
	var to_remove = []
	for alert in _alerts:
		alert["time"] -= delta
		if alert["time"] <= 0:
			to_remove.append(alert)
		else:
			var alpha = clampf(alert["time"] / FADE_DURATION, 0.0, 1.0)
			alert["label"].modulate.a = alpha

	for alert in to_remove:
		alert["label"].queue_free()
		_alerts.erase(alert)


func post_alert(message: String, severity: String = "warning") -> void:
	var label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var settings = LabelSettings.new()
	settings.font_size = 11
	match severity:
		"error":
			settings.font_color = Color.html("#e74c3c")
		"warning":
			settings.font_color = Color.html("#f5b041")
		"info":
			settings.font_color = Color.html("#85c1e9")
	label.label_settings = settings

	add_child(label)
	move_child(label, 0)  # Newest at top
	_alerts.append({"label": label, "time": FADE_DURATION})

	# Trim old alerts
	while _alerts.size() > MAX_ALERTS:
		var oldest = _alerts.pop_back()
		oldest["label"].queue_free()

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
