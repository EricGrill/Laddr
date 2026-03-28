extends Node
## Single source of truth for all entity state.
## Updated by WebSocketClient. Agents/stations/UI subscribe to signals.
## Stores camelCase keys as-is from the backend (no translation).

# Data stores
var agents: Dictionary = {}
var jobs: Dictionary = {}
var stations: Dictionary = {}
var workers: Dictionary = {}
var metrics: Dictionary = {}

# Direct backend event signals
signal agent_changed(agent_id: String)
signal job_changed(job_id: String)
signal station_changed(station_id: String)
signal job_completed(job_id: String)
signal job_created(job_id: String)
signal job_failed(job_id: String, reason: String)
signal metrics_changed()
signal worker_changed(worker_id: String, is_new: bool)
signal worker_removed(worker_id: String)

# Derived signals (from job_updated diffs)
signal job_assigned(job_id: String, agent_id: String, station_id: String)
signal job_handoff(job_id: String, from_station_id: String, to_station_id: String)

# Snapshot
signal snapshot_loaded()


func clear() -> void:
	agents.clear()
	jobs.clear()
	stations.clear()
	workers.clear()
	metrics.clear()


func load_snapshot(data: Dictionary) -> void:
	clear()
	for agent in data.get("agents", []):
		agents[agent["id"]] = agent
	for job in data.get("jobs", []):
		jobs[job["id"]] = job
	for station in data.get("stations", []):
		stations[station["id"]] = station
	for worker in data.get("workers", []):
		workers[worker["id"]] = worker
	metrics = data.get("metrics", {})
	snapshot_loaded.emit()


func handle_agent_updated(agent: Dictionary) -> void:
	agents[agent["id"]] = agent
	agent_changed.emit(agent["id"])


func handle_job_created(job: Dictionary) -> void:
	jobs[job["id"]] = job
	job_created.emit(job["id"])
	job_changed.emit(job["id"])


func handle_job_updated(job: Dictionary) -> void:
	var old_job = jobs.get(job["id"], {})
	jobs[job["id"]] = job

	# Derive assignment: assignedAgentId went from null/empty to a value
	var old_agent = old_job.get("assignedAgentId", "")
	var new_agent = job.get("assignedAgentId", "")
	if (old_agent == null or old_agent == "") and new_agent != null and new_agent != "":
		job_assigned.emit(job["id"], new_agent, job.get("currentStationId", ""))

	# Derive handoff: currentStationId changed (and old wasn't empty)
	var old_station = old_job.get("currentStationId", "")
	var new_station = job.get("currentStationId", "")
	if old_station != null and old_station != "" and old_station != new_station:
		job_handoff.emit(job["id"], old_station, new_station)

	job_changed.emit(job["id"])


func handle_job_completed(job_id: String) -> void:
	if jobs.has(job_id):
		jobs[job_id]["state"] = "completed"
	job_completed.emit(job_id)


func handle_job_failed(job_id: String, reason: String) -> void:
	if jobs.has(job_id):
		jobs[job_id]["state"] = "failed"
	job_failed.emit(job_id, reason)


func handle_station_updated(station: Dictionary) -> void:
	stations[station["id"]] = station
	station_changed.emit(station["id"])


func handle_metrics_updated(new_metrics: Dictionary) -> void:
	metrics = new_metrics
	metrics_changed.emit()


func handle_worker_registered(worker: Dictionary) -> void:
	var is_new = not workers.has(worker["id"])
	workers[worker["id"]] = worker
	worker_changed.emit(worker["id"], is_new)


func handle_worker_deregistered(worker_id: String) -> void:
	workers.erase(worker_id)
	worker_removed.emit(worker_id)
