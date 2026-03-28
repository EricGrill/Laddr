extends Control
## Top bar HUD showing connection status, live metrics, and kiosk toggle.

@onready var connection_dot: ColorRect = $HBoxContainer/ConnectionDot
@onready var connection_label: Label = $HBoxContainer/ConnectionLabel
@onready var metrics_label: Label = $HBoxContainer/MetricsLabel
@onready var speed_slider: HSlider = $HBoxContainer/SpeedSlider
@onready var speed_label: Label = $HBoxContainer/SpeedLabel
@onready var kiosk_button: Button = $HBoxContainer/KioskButton
@onready var background: ColorRect = $Background

# Speed values mapped to slider steps 0..3
const SPEED_VALUES = [0.5, 1.0, 2.0, 4.0]

var _kiosk_mode: bool = false


func _ready() -> void:
	WebSocketClient.connection_state_changed.connect(_on_connection_state_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	_on_connection_state_changed(WebSocketClient.connection_state)

	if speed_slider:
		speed_slider.min_value = 0
		speed_slider.max_value = 3
		speed_slider.step = 1
		speed_slider.value = 1
		speed_slider.value_changed.connect(_on_speed_slider_changed)

	if speed_label:
		speed_label.text = "1.0x"

	if kiosk_button:
		kiosk_button.pressed.connect(_toggle_kiosk)
		kiosk_button.add_theme_color_override("font_color", Color(0.5, 0.85, 0.95, 0.9))
		kiosk_button.add_theme_color_override("font_hover_color", Color(0.7, 0.95, 1.0, 1.0))


func _toggle_kiosk() -> void:
	_kiosk_mode = not _kiosk_mode

	var ui_layer = get_parent()
	if not ui_layer:
		return

	var inspector = ui_layer.get_node_or_null("Inspector")
	var mission_panel = ui_layer.get_node_or_null("MissionPanel")
	var job_board = ui_layer.get_node_or_null("JobBoard")

	if _kiosk_mode:
		# Hide ALL side panels and job board
		if inspector:
			inspector.visible = false
		if mission_panel:
			mission_panel.visible = false
		if job_board:
			job_board.visible = false
		# Make HUD transparent and minimal
		if background:
			background.color = Color(0.05, 0.05, 0.08, 0.5)
		# Hide non-essential HUD elements
		if connection_dot:
			connection_dot.visible = false
		if connection_label:
			connection_label.visible = false
		if speed_slider:
			speed_slider.visible = false
		if speed_label:
			speed_label.visible = false
		var prefix = $HBoxContainer.get_node_or_null("SpeedPrefixLabel")
		if prefix:
			prefix.visible = false
		if kiosk_button:
			kiosk_button.text = "EXIT KIOSK"
	else:
		# Restore everything
		if inspector:
			inspector.visible = true
		if mission_panel:
			mission_panel.visible = true
		if job_board:
			job_board.visible = true
		if background:
			background.color = Color(0.1, 0.1, 0.12, 0.85)
		if connection_dot:
			connection_dot.visible = true
		if connection_label:
			connection_label.visible = true
		if speed_slider:
			speed_slider.visible = true
		if speed_label:
			speed_label.visible = true
		var prefix = $HBoxContainer.get_node_or_null("SpeedPrefixLabel")
		if prefix:
			prefix.visible = true
		if kiosk_button:
			kiosk_button.text = "KIOSK"


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
	var queued = 0
	var processing = 0
	var completed = 0
	var failed = 0
	for jid in WorldState.jobs:
		var state = WorldState.jobs[jid].get("state", "queued")
		match state:
			"queued": queued += 1
			"processing": processing += 1
			"completed": completed += 1
			"failed": failed += 1
	var workers_online = WorldState.workers.size()
	var busy_workers = 0
	for wid in WorldState.workers:
		if WorldState.workers[wid].get("activeJobs", 0) > 0:
			busy_workers += 1

	# Use real Redis queue depth
	var real_q = WorldState.metrics.get("realQueueDepth", queued)
	if real_q > queued:
		queued = real_q
	var overflow = WorldState.metrics.get("overflowActive", false)
	var spend = WorldState.metrics.get("dailyVeniceSpend", 0.0)

	var text = "Q:%d  Run:%d  Done:%d  Fail:%d | Workers: %d/%d" % [
		queued, processing, completed, failed, busy_workers, workers_online
	]
	if overflow:
		text += " | OVERFLOW $%.2f" % spend
	metrics_label.text = text
