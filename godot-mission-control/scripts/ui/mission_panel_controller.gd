extends Control
## Left sidebar: agent roster and station queue dashboard.

@onready var panel: PanelContainer = $PanelContainer
@onready var agent_list: VBoxContainer = $PanelContainer/VBox/AgentList
@onready var station_list: VBoxContainer = $PanelContainer/VBox/StationList
@onready var toggle_button: Button = $ToggleButton

var _collapsed: bool = false
var _agent_rows: Dictionary = {}  # worker_id → HBoxContainer
var _station_rows: Dictionary = {}  # station_id → HBoxContainer
var _filter_section: VBoxContainer = null
var _panel_tween: Tween = null
var _panel_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	WorldState.snapshot_loaded.connect(_rebuild_all)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.worker_removed.connect(_on_worker_removed)
	WorldState.agent_changed.connect(_on_agent_changed)
	WorldState.station_changed.connect(_on_station_changed)
	if toggle_button:
		toggle_button.pressed.connect(_toggle_collapse)
	if panel:
		_panel_offset = panel.position
		panel.pivot_offset = panel.size / 2.0
	_build_filter_section()


func _build_filter_section() -> void:
	var vbox = $PanelContainer/VBox
	if not vbox:
		return

	_filter_section = VBoxContainer.new()
	_filter_section.name = "FilterSection"

	var title = Label.new()
	title.text = "Filters"
	var title_settings = LabelSettings.new()
	title_settings.font_size = 11
	title_settings.font_color = Color.html("#aaaaaa")
	title.label_settings = title_settings
	_filter_section.add_child(title)

	# Agent State filter
	_filter_section.add_child(_make_filter_row("Agent State", "agent_state",
		["", "idle", "running", "busy", "offline"]))

	# Agent Role filter
	_filter_section.add_child(_make_filter_row("Agent Role", "agent_role",
		["", "worker", "coordinator", "specialist"]))

	# Job State filter
	_filter_section.add_child(_make_filter_row("Job State", "job_state",
		["", "pending", "running", "completed", "failed"]))

	# Job Priority filter
	_filter_section.add_child(_make_filter_row("Job Priority", "job_priority",
		["", "low", "normal", "high", "critical"]))

	# Clear All button
	var clear_btn = Button.new()
	clear_btn.text = "Clear Filters"
	clear_btn.pressed.connect(func(): FilterState.clear_all())
	_filter_section.add_child(clear_btn)

	# Insert at the top of the VBox (before agent list)
	vbox.add_child(_filter_section)
	vbox.move_child(_filter_section, 0)


func _make_filter_row(label_text: String, category: String, options: Array) -> HBoxContainer:
	var row = HBoxContainer.new()

	var lbl = Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 11
	lbl.label_settings = lbl_settings
	row.add_child(lbl)

	var dropdown = OptionButton.new()
	dropdown.custom_minimum_size = Vector2(90, 0)
	for opt in options:
		dropdown.add_item(opt if opt != "" else "(all)")
	dropdown.item_selected.connect(func(idx: int):
		var val = options[idx]
		FilterState.set_filter(category, val)
	)
	row.add_child(dropdown)

	return row


func _toggle_collapse() -> void:
	_collapsed = not _collapsed
	_animate_panel(not _collapsed)
	if toggle_button:
		toggle_button.text = ">" if _collapsed else "<"


func _animate_panel(show: bool) -> void:
	if not panel:
		return
	if _panel_tween and _panel_tween.is_running():
		_panel_tween.kill()

	if show:
		panel.visible = true
		panel.modulate = Color(1, 1, 1, 0.0)
		panel.scale = Vector2(0.98, 0.98)
		panel.position = _panel_offset + Vector2(-18.0, 0.0)
		_panel_tween = create_tween()
		_panel_tween.set_parallel(true)
		_panel_tween.tween_property(panel, "modulate", Color(1, 1, 1, 1.0), 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_panel_tween.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_panel_tween.tween_property(panel, "position", _panel_offset, 0.26).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		return

	_panel_tween = create_tween()
	_panel_tween.set_parallel(true)
	_panel_tween.tween_property(panel, "modulate", Color(1, 1, 1, 0.0), 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_panel_tween.tween_property(panel, "scale", Vector2(0.98, 0.98), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_panel_tween.tween_property(panel, "position", _panel_offset + Vector2(-22.0, 0.0), 0.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_panel_tween.finished.connect(func():
		if panel:
			panel.visible = false
	)


func _rebuild_all() -> void:
	_clear_lists()
	for worker_id in WorldState.workers:
		_add_agent_row(worker_id)
	for station_id in WorldState.stations:
		_add_station_row(station_id)


func _clear_lists() -> void:
	for child in agent_list.get_children():
		child.queue_free()
	_agent_rows.clear()
	for child in station_list.get_children():
		child.queue_free()
	_station_rows.clear()


func _add_agent_row(worker_id: String) -> void:
	var row = HBoxContainer.new()
	row.name = worker_id

	# Color swatch
	var swatch = ColorRect.new()
	swatch.custom_minimum_size = Vector2(12, 12)
	var colors = [Color.html("#d4836b"), Color.html("#e8a87c"), Color.html("#f0c8a0"),
		Color.html("#c97b7b"), Color.html("#d4a574"), Color.html("#b07d62")]
	swatch.color = colors[worker_id.hash() % colors.size()]
	row.add_child(swatch)

	# Name label
	var name_label = Label.new()
	name_label.text = worker_id.left(12)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# State label
	var state_label = Label.new()
	state_label.name = "StateLabel"
	state_label.text = "idle"
	row.add_child(state_label)

	# Click to select
	var btn = Button.new()
	btn.text = ">"
	btn.flat = true
	btn.pressed.connect(func(): EventBus.entity_selected.emit("agent", worker_id))
	row.add_child(btn)

	agent_list.add_child(row)
	_agent_rows[worker_id] = row


func _add_station_row(station_id: String) -> void:
	var row = HBoxContainer.new()
	row.name = station_id

	var data = WorldState.stations.get(station_id, {})

	# Station name
	var name_label = Label.new()
	name_label.text = data.get("label", station_id).left(14)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# Queue depth bar
	var bar = ProgressBar.new()
	bar.name = "QueueBar"
	bar.custom_minimum_size = Vector2(80, 14)
	bar.max_value = data.get("capacity", 1)
	bar.value = data.get("queueDepth", 0)
	bar.show_percentage = false
	row.add_child(bar)

	# Depth label
	var depth_label = Label.new()
	depth_label.name = "DepthLabel"
	depth_label.text = "%d/%d" % [data.get("queueDepth", 0), data.get("capacity", 1)]
	row.add_child(depth_label)

	station_list.add_child(row)
	_station_rows[station_id] = row


func _on_worker_changed(worker_id: String, is_new: bool) -> void:
	if is_new and not _agent_rows.has(worker_id):
		_add_agent_row(worker_id)


func _on_worker_removed(worker_id: String) -> void:
	if _agent_rows.has(worker_id):
		_agent_rows[worker_id].queue_free()
		_agent_rows.erase(worker_id)


func _on_agent_changed(agent_id: String) -> void:
	# Find the matching worker row
	var agent_data = WorldState.agents.get(agent_id, {})
	var worker_id = agent_data.get("workerId", agent_id)
	if _agent_rows.has(worker_id):
		var row = _agent_rows[worker_id]
		var state_label = row.get_node_or_null("StateLabel")
		if state_label:
			state_label.text = agent_data.get("state", "idle")


func _on_station_changed(station_id: String) -> void:
	if not _station_rows.has(station_id):
		return
	var row = _station_rows[station_id]
	var data = WorldState.stations.get(station_id, {})

	var bar = row.get_node_or_null("QueueBar")
	if bar:
		bar.value = data.get("queueDepth", 0)

	var depth_label = row.get_node_or_null("DepthLabel")
	if depth_label:
		depth_label.text = "%d/%d" % [data.get("queueDepth", 0), data.get("capacity", 1)]
