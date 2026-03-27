extends Node
## Tracks active filters for the UI. Agents and stations check this
## to determine visibility.

signal filters_changed()

var job_state_filter: String = ""       # "" means show all
var job_priority_filter: String = ""
var job_type_filter: String = ""
var agent_role_filter: String = ""
var agent_state_filter: String = ""
var station_type_filter: String = ""


func clear_all() -> void:
	job_state_filter = ""
	job_priority_filter = ""
	job_type_filter = ""
	agent_role_filter = ""
	agent_state_filter = ""
	station_type_filter = ""
	filters_changed.emit()


func set_filter(category: String, value: String) -> void:
	match category:
		"job_state": job_state_filter = value
		"job_priority": job_priority_filter = value
		"job_type": job_type_filter = value
		"agent_role": agent_role_filter = value
		"agent_state": agent_state_filter = value
		"station_type": station_type_filter = value
	filters_changed.emit()


func passes_agent_filter(agent_data: Dictionary) -> bool:
	if agent_role_filter != "" and agent_data.get("role", "") != agent_role_filter:
		return false
	if agent_state_filter != "" and agent_data.get("state", "") != agent_state_filter:
		return false
	return true


func passes_job_filter(job_data: Dictionary) -> bool:
	if job_state_filter != "" and job_data.get("state", "") != job_state_filter:
		return false
	if job_priority_filter != "" and job_data.get("priority", "") != job_priority_filter:
		return false
	if job_type_filter != "" and job_data.get("type", "") != job_type_filter:
		return false
	return true
