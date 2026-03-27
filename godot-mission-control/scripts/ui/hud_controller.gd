extends Control
## Top bar HUD showing connection status and live metrics.

@onready var connection_dot: ColorRect = $HBoxContainer/ConnectionDot
@onready var connection_label: Label = $HBoxContainer/ConnectionLabel
@onready var metrics_label: Label = $HBoxContainer/MetricsLabel


func _ready() -> void:
	WebSocketClient.connection_state_changed.connect(_on_connection_state_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	_on_connection_state_changed(WebSocketClient.connection_state)


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
	var active_agents = m.get("activeAgents", WorldState.agents.size())
	var errors = m.get("errorCount", 0)
	var queue_depth = m.get("totalQueueDepth", 0)
	metrics_label.text = "Jobs: %d | Agents: %d | Queue: %d | Errors: %d" % [
		total_jobs, active_agents, queue_depth, errors
	]
