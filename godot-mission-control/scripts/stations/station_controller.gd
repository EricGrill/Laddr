extends Node2D
## Generic station that configures itself based on station_id.
## Subscribes to WorldState for state changes.

@export var station_id: String = ""

var station_type: String = ""
var station_label: String = ""
var queue_depth: int = 0
var capacity: int = 1
var state: String = "idle"
var _original_color: Color = Color.GRAY
var _packet_nodes: Array = []
var _packet_pool: Array = []
const MAX_VISIBLE_PACKETS = 5
var _last_click_time: float = 0.0

const STATION_SPRITE_BASE = "res://assets/sprites/stations/"

@onready var label_node: Label = $Label
@onready var sprite_node: Sprite2D = $Sprite
@onready var queue_label: Label = $QueueLabel
@onready var click_area: Area2D = $ClickArea


func setup(id: String, type: String, lbl: String, cap: int, color: Color) -> void:
	station_id = id
	station_type = type
	station_label = lbl
	capacity = cap
	_original_color = color

	if label_node:
		label_node.text = lbl

	# Load station sprite texture
	if sprite_node:
		var tex_path = STATION_SPRITE_BASE + type + ".png"
		var tex = load(tex_path)
		if tex:
			sprite_node.texture = tex
		else:
			push_warning("Station sprite not found: %s" % tex_path)


func _ready() -> void:
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)

	var effects = get_node_or_null("StationEffects")
	if effects:
		effects.setup(station_type, capacity)


func _on_station_changed(changed_id: String) -> void:
	if changed_id != station_id:
		return
	var data = WorldState.stations.get(station_id, {})
	_update_from_data(data)


func _on_snapshot_loaded() -> void:
	var data = WorldState.stations.get(station_id, {})
	if not data.is_empty():
		_update_from_data(data)


func _update_from_data(data: Dictionary) -> void:
	state = data.get("state", "idle")
	queue_depth = data.get("queueDepth", 0)

	if queue_label:
		queue_label.text = str(queue_depth) if queue_depth > 0 else ""

	# Saturation feedback via modulate (tint the sprite)
	if sprite_node:
		var saturation_ratio = float(queue_depth) / max(capacity, 1)
		if saturation_ratio > 0.8:
			sprite_node.modulate = Color(1.3, 0.7, 0.7, 1)  # red tint
		elif saturation_ratio > 0.5:
			sprite_node.modulate = Color(1.2, 1.1, 0.7, 1)  # yellow tint
		else:
			sprite_node.modulate = Color.WHITE  # normal

	var effects = get_node_or_null("StationEffects")
	if effects:
		effects.update_state(state, queue_depth)

	_update_queue_visuals()


func _get_pooled_packet() -> Node2D:
	if _packet_pool.size() > 0:
		var pkt = _packet_pool.pop_back()
		pkt.visible = true
		return pkt
	return load("res://scenes/items/job_packet.tscn").instantiate()


func _return_to_pool(pkt: Node2D) -> void:
	pkt.visible = false
	_packet_pool.append(pkt)


func _update_queue_visuals() -> void:
	# Return old packet visuals to pool
	for pkt in _packet_nodes:
		_return_to_pool(pkt)
	_packet_nodes.clear()

	var data = WorldState.stations.get(station_id, {})
	var active_jobs = data.get("activeJobIds", [])

	var count = mini(active_jobs.size(), MAX_VISIBLE_PACKETS)
	for i in range(count):
		var job_id = active_jobs[i]
		var job_data = WorldState.jobs.get(job_id, {})
		var pkt = _get_pooled_packet()
		if not pkt.is_inside_tree():
			add_child(pkt)
		pkt.setup(job_id, job_data.get("priority", "normal"))
		pkt.position = Vector2(-20 + i * 10, 20)
		_packet_nodes.append(pkt)


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var now = Time.get_ticks_msec() / 1000.0
		if now - _last_click_time < 0.4:
			# Double click — zoom to fit
			EventBus.camera_focus_requested.emit(global_position)
		else:
			EventBus.entity_selected.emit("station", station_id)
		_last_click_time = now
