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

@onready var label_node: Label = $Label
@onready var sprite_node: ColorRect = $Sprite
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
	if sprite_node:
		sprite_node.color = color


func _ready() -> void:
	WorldState.station_changed.connect(_on_station_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)


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

	# Saturation color feedback
	if sprite_node:
		var saturation_ratio = float(queue_depth) / max(capacity, 1)
		if saturation_ratio > 0.8:
			sprite_node.color = Color.html("#e74c3c")  # red
		elif saturation_ratio > 0.5:
			sprite_node.color = Color.html("#f5b041")  # yellow
		else:
			sprite_node.color = _original_color


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		EventBus.entity_selected.emit("station", station_id)
		EventBus.camera_focus_requested.emit(global_position)
