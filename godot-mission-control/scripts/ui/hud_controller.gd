extends Control
## Top bar HUD showing connection status and live metrics.

@onready var connection_dot: ColorRect = $HBoxContainer/ConnectionDot
@onready var connection_label: Label = $HBoxContainer/ConnectionLabel
@onready var metrics_label: Label = $HBoxContainer/MetricsLabel
@onready var speed_slider: HSlider = $HBoxContainer/SpeedSlider
@onready var speed_label: Label = $HBoxContainer/SpeedLabel

# Speed values mapped to slider steps 0..3
const SPEED_VALUES = [0.5, 1.0, 2.0, 4.0]


func _ready() -> void:
	WebSocketClient.connection_state_changed.connect(_on_connection_state_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	_on_connection_state_changed(WebSocketClient.connection_state)

	if speed_slider:
		speed_slider.min_value = 0
		speed_slider.max_value = 3
		speed_slider.step = 1
		speed_slider.value = 1  # Default 1.0x
		speed_slider.value_changed.connect(_on_speed_slider_changed)

	if speed_label:
		speed_label.text = "1.0x"


func _on_speed_slider_changed(value: float) -> void:
	var idx = clamp(int(value), 0, SPEED_VALUES.size() - 1)
	var speed = SPEED_VALUES[idx]
	if speed_label:
		speed_label.text = "%sx" % str(speed)
	EventBus.playback_speed_changed.emit(speed)


func _on_connection_state_changed(state: String) -> void:
	if connection_label:
		connection_label.text = state.capitalize()
	if connection_dot:
		match state:
			"connected":
				connection_dot.color = Color.GREEN
			"connecting":
				connection_dot.color = Color.YELLOW
			"disconnected":
				connection_dot.color = Color.RED


func _on_metrics_changed() -> void:
	_update_metrics()


func _on_snapshot_loaded() -> void:
	_update_metrics()


func _update_metrics() -> void:
	if not metrics_label:
		return
	var m = WorldState.metrics
	var total_jobs = m.get("totalJobs", WorldState.jobs.size())
	var workers_online = WorldState.workers.size()
	var errors = m.get("errorCount", 0)
	var busy_workers = 0
	for wid in WorldState.workers:
		var w = WorldState.workers[wid]
		if w.get("activeJobs", 0) > 0:
			busy_workers += 1
	metrics_label.text = "Jobs: %d | Workers: %d/%d busy | Errors: %d" % [
		total_jobs, busy_workers, workers_online, errors
	]
