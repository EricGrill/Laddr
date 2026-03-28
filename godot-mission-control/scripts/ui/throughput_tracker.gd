extends Node
class_name ThroughputTracker

## Ring buffer of recent events for 5-minute client-side interpolation.
## Server values are authoritative; local counts bridge between pushes.

const WINDOW_SECONDS: float = 300.0  # 5 minutes

# Ring buffer: array of {timestamp: float, event_type: String}
var _buffer: Array[Dictionary] = []

# Server baseline from last metrics_changed
var _server_baseline: Dictionary = {}

# Timestamp of last server push (for pruning, not full clear)
var _last_push_time: float = 0.0


func _ready() -> void:
	WorldState.job_created.connect(_on_job_created)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.metrics_changed.connect(_on_metrics_changed)


func _on_job_created(_job_id: String) -> void:
	_buffer.append({"timestamp": Time.get_unix_time_from_system(), "event_type": "inbound"})


func _on_job_completed(_job_id: String) -> void:
	_buffer.append({"timestamp": Time.get_unix_time_from_system(), "event_type": "completed"})


func _on_job_failed(_job_id: String, _reason: String) -> void:
	_buffer.append({"timestamp": Time.get_unix_time_from_system(), "event_type": "failed"})


func _on_metrics_changed() -> void:
	var throughput = WorldState.metrics.get("throughput", {})
	if throughput.is_empty():
		return
	_server_baseline = throughput
	# Prune entries older than push time (not full clear — avoids transit race)
	var now := Time.get_unix_time_from_system()
	_last_push_time = now
	_prune_old_entries(now)


func _prune_old_entries(now: float) -> void:
	var cutoff := now - WINDOW_SECONDS
	_buffer = _buffer.filter(func(entry): return entry["timestamp"] >= cutoff)


func _count_local_since_push(event_type: String) -> int:
	var count := 0
	for entry in _buffer:
		if entry["timestamp"] >= _last_push_time and entry["event_type"] == event_type:
			count += 1
	return count


# --- Public API ---

func get_5m_inbound() -> int:
	var base: int = _server_baseline.get("inbound", {}).get("5m", 0)
	return base + _count_local_since_push("inbound")


func get_5m_completed() -> int:
	var base: int = _server_baseline.get("completed", {}).get("5m", 0)
	return base + _count_local_since_push("completed")


func get_5m_failed() -> int:
	var base: int = _server_baseline.get("failed", {}).get("5m", 0)
	return base + _count_local_since_push("failed")


func get_1h_inbound() -> int:
	return _server_baseline.get("inbound", {}).get("1h", 0)


func get_1h_completed() -> int:
	return _server_baseline.get("completed", {}).get("1h", 0)


func get_24h_inbound() -> int:
	return _server_baseline.get("inbound", {}).get("24h", 0)


func get_24h_completed() -> int:
	return _server_baseline.get("completed", {}).get("24h", 0)


func get_saturation() -> float:
	return _server_baseline.get("capacity", {}).get("saturation", 0.0)


func get_capacity_status() -> String:
	return _server_baseline.get("capacity", {}).get("status", "healthy")


func get_imbalance_minutes() -> float:
	return _server_baseline.get("capacity", {}).get("imbalanceSustainedMinutes", 0.0)
