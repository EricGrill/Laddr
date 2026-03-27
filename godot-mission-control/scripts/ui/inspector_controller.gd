extends Control
## Right-side panel that shows details of selected entity.
## Listens to EventBus for selection events.

@onready var panel: PanelContainer = $PanelContainer
@onready var title_label: Label = $PanelContainer/VBox/Title
@onready var details_label: RichTextLabel = $PanelContainer/VBox/Details

var _selected_type: String = ""
var _selected_id: String = ""


func _ready() -> void:
	panel.visible = false
	EventBus.entity_selected.connect(_on_entity_selected)
	EventBus.entity_deselected.connect(_on_entity_deselected)
	# Update on state changes
	WorldState.agent_changed.connect(func(id): _refresh_if_selected("agent", id))
	WorldState.job_changed.connect(func(id): _refresh_if_selected("job", id))
	WorldState.station_changed.connect(func(id): _refresh_if_selected("station", id))


func _on_entity_selected(entity_type: String, entity_id: String) -> void:
	_selected_type = entity_type
	_selected_id = entity_id
	panel.visible = true
	_refresh()


func _on_entity_deselected() -> void:
	_selected_type = ""
	_selected_id = ""
	panel.visible = false


func _refresh_if_selected(entity_type: String, entity_id: String) -> void:
	if entity_type == _selected_type and entity_id == _selected_id:
		_refresh()


func _refresh() -> void:
	match _selected_type:
		"agent":
			_show_agent()
		"job":
			_show_job()
		"station":
			_show_station()


func _show_agent() -> void:
	var data = WorldState.agents.get(_selected_id, {})
	if data.is_empty():
		# Try looking up by worker ID
		for aid in WorldState.agents:
			if WorldState.agents[aid].get("workerId", aid) == _selected_id:
				data = WorldState.agents[aid]
				break

	title_label.text = "Agent: %s" % _selected_id.left(12)
	var text = ""
	text += "[b]Role:[/b] %s\n" % data.get("role", "unknown")
	text += "[b]State:[/b] %s\n" % data.get("state", "unknown")
	text += "[b]Current Job:[/b] %s\n" % str(data.get("currentJobId", "none"))
	text += "[b]Efficiency:[/b] %s%%\n" % str(data.get("efficiency", "—"))
	var recent = data.get("recentJobIds", [])
	if not recent.is_empty():
		text += "[b]Recent Jobs:[/b]\n"
		for jid in recent.slice(0, 5):
			text += "  • %s\n" % jid.left(16)
	details_label.text = text


func _show_job() -> void:
	var data = WorldState.jobs.get(_selected_id, {})
	title_label.text = "Job: %s" % _selected_id.left(16)
	var text = ""
	text += "[b]Type:[/b] %s\n" % data.get("type", "unknown")
	text += "[b]Priority:[/b] %s\n" % data.get("priority", "normal")
	text += "[b]State:[/b] %s\n" % data.get("state", "unknown")
	text += "[b]Agent:[/b] %s\n" % str(data.get("assignedAgentId", "none"))
	text += "[b]Station:[/b] %s\n" % str(data.get("currentStationId", "none"))
	var history = data.get("history", [])
	if not history.is_empty():
		text += "[b]History:[/b]\n"
		for entry in history.slice(-5):
			text += "  • %s: %s\n" % [entry.get("event", ""), entry.get("at", "")]
	details_label.text = text


func _show_station() -> void:
	var data = WorldState.stations.get(_selected_id, {})
	title_label.text = "Station: %s" % data.get("label", _selected_id)
	var text = ""
	text += "[b]Type:[/b] %s\n" % data.get("type", "unknown")
	text += "[b]State:[/b] %s\n" % data.get("state", "idle")
	text += "[b]Capacity:[/b] %d\n" % data.get("capacity", 0)
	text += "[b]Queue Depth:[/b] %d\n" % data.get("queueDepth", 0)
	var active = data.get("activeJobIds", [])
	if not active.is_empty():
		text += "[b]Active Jobs:[/b]\n"
		for jid in active.slice(0, 5):
			text += "  • %s\n" % jid.left(16)
	details_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	# Click empty space to deselect
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if panel.visible and not _is_mouse_over_panel():
			# Let the click propagate — entity click handlers will re-select
			# Only deselect if nothing else catches it
			call_deferred("_check_deselect")


func _check_deselect() -> void:
	# If no entity was selected this frame, deselect
	pass  # Deselection handled by clicking empty space in main scene


func _is_mouse_over_panel() -> bool:
	var mouse = get_global_mouse_position()
	return panel.get_global_rect().has_point(mouse)
