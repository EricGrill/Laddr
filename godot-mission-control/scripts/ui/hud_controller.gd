extends Control
## Top bar HUD showing connection status, live metrics, and kiosk toggle.

@onready var connection_dot: ColorRect = $VBoxContainer/HBoxContainer/ConnectionDot
@onready var connection_label: Label = $VBoxContainer/HBoxContainer/ConnectionLabel
@onready var metrics_label: Label = $VBoxContainer/HBoxContainer/MetricsLabel
@onready var speed_slider: HSlider = $VBoxContainer/HBoxContainer/SpeedSlider
@onready var speed_label: Label = $VBoxContainer/HBoxContainer/SpeedLabel
@onready var kiosk_button: Button = $VBoxContainer/HBoxContainer/KioskButton
@onready var background: ColorRect = $Background

# Throughput display
@onready var metrics_label_2: Label = $VBoxContainer/HBoxContainer2/MetricsLabel2
@onready var throughput_tracker: ThroughputTracker = $ThroughputTracker

# Speed values mapped to slider steps 0..3
const SPEED_VALUES = [0.5, 1.0, 2.0, 4.0]

var _capacity_pulse_active: bool = false
var _kiosk_mode: bool = false
var _status_tween: Tween = null
var _background_tween: Tween = null
var _background_base_color: Color = Color(0.1, 0.1, 0.12, 0.85)
var _background_kiosk_color: Color = Color(0.05, 0.05, 0.08, 0.5)
var _hud_time: float = 0.0


func _ready() -> void:
	WebSocketClient.connection_state_changed.connect(_on_connection_state_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	_on_connection_state_changed(WebSocketClient.connection_state)

	if connection_dot:
		connection_dot.pivot_offset = connection_dot.size / 2.0

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
	if background:
		_background_base_color = background.color
		background.color = _background_base_color

	# Start in kiosk mode by default
	call_deferred("_toggle_kiosk")


func _toggle_kiosk() -> void:
	_kiosk_mode = not _kiosk_mode

	var ui_layer = get_parent()
	if not ui_layer:
		return

	var inspector = ui_layer.get_node_or_null("Inspector")
	var mission_panel = ui_layer.get_node_or_null("MissionPanel")
	var job_board = ui_layer.get_node_or_null("JobBoard")

	if _kiosk_mode:
		# Hide side panels, KEEP job board visible
		if inspector:
			inspector.visible = false
		if mission_panel:
			mission_panel.visible = false
		# Make HUD transparent and minimal
		if background:
			_tween_background(background.color, _background_kiosk_color)
		# Hide non-essential HUD elements
		if connection_dot:
			connection_dot.visible = false
		if connection_label:
			connection_label.visible = false
		if speed_slider:
			speed_slider.visible = false
		if speed_label:
			speed_label.visible = false
		var prefix = $VBoxContainer/HBoxContainer.get_node_or_null("SpeedPrefixLabel")
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
			_tween_background(background.color, _background_base_color)
		if connection_dot:
			connection_dot.visible = true
		if connection_label:
			connection_label.visible = true
		if speed_slider:
			speed_slider.visible = true
		if speed_label:
			speed_label.visible = true
		var prefix = $VBoxContainer/HBoxContainer.get_node_or_null("SpeedPrefixLabel")
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
		_animate_status_dot(state)


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

	# Throughput line
	if not throughput_tracker or not metrics_label_2:
		return
	var in_5m := throughput_tracker.get_5m_inbound()
	var in_1h := throughput_tracker.get_1h_inbound()
	var in_24h := throughput_tracker.get_24h_inbound()
	var out_5m := throughput_tracker.get_5m_completed()
	var out_1h := throughput_tracker.get_1h_completed()
	var out_24h := throughput_tracker.get_24h_completed()
	var sat := throughput_tracker.get_saturation()
	var cap_status := throughput_tracker.get_capacity_status()

	var throughput_text := "In: %d/5m  %d/hr  %d/day   Out: %d/5m  %d/hr  %d/day   Sat: %d%%  ● %s" % [
		in_5m, in_1h, in_24h, out_5m, out_1h, out_24h, int(sat * 100), cap_status.to_upper()
	]
	metrics_label_2.text = throughput_text

	# Saturation color
	var sat_pct := sat * 100.0
	if sat_pct > 80.0:
		metrics_label_2.modulate = Color.GREEN
	elif sat_pct > 50.0:
		metrics_label_2.modulate = Color.YELLOW
	else:
		metrics_label_2.modulate = Color.RED

	_capacity_pulse_active = cap_status != "healthy"


func _process(delta: float) -> void:
	_hud_time += delta
	if connection_dot and connection_dot.visible:
		var pulse = 1.0 + sin(_hud_time * 3.5) * 0.035
		connection_dot.scale = Vector2(pulse, pulse)

	# Capacity status pulse on throughput line
	if metrics_label_2:
		if _capacity_pulse_active:
			var alpha := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 500.0)
			metrics_label_2.modulate.a = alpha
		else:
			metrics_label_2.modulate.a = 1.0


func _animate_status_dot(state: String) -> void:
	if not connection_dot:
		return
	if _status_tween and _status_tween.is_running():
		_status_tween.kill()

	var pulse_color = connection_dot.color
	var target_scale = Vector2.ONE
	match state:
		"connected":
			target_scale = Vector2(1.25, 1.25)
			pulse_color = Color(0.4, 1.0, 0.6, 1.0)
		"connecting":
			target_scale = Vector2(1.18, 1.18)
			pulse_color = Color(1.0, 0.88, 0.4, 1.0)
		"disconnected":
			target_scale = Vector2(1.3, 1.3)
			pulse_color = Color(1.0, 0.35, 0.35, 1.0)

	connection_dot.scale = Vector2(0.85, 0.85)
	_status_tween = create_tween()
	_status_tween.set_parallel(true)
	_status_tween.tween_property(connection_dot, "scale", target_scale, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_status_tween.tween_property(connection_dot, "color", pulse_color, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_status_tween.finished.connect(func():
		if connection_dot:
			connection_dot.scale = Vector2.ONE
	)


func _tween_background(_from_color: Color, to_color: Color) -> void:
	if not background:
		return
	if _background_tween and _background_tween.is_running():
		_background_tween.kill()
	_background_tween = create_tween()
	_background_tween.tween_property(background, "color", to_color, 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
