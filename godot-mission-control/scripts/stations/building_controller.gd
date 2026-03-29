extends Node2D
## City building controller for Daystrom City cyberpunk mission control.
## Simpler than station_controller — no click areas, no packet pool, no effects.
## Just sprite + label + glow, placed by CityBuilder at fixed positions.

var station_id: String = ""
var station_type: String = ""
var station_label: String = ""
var queue_depth: int = 0
var capacity: int = 1
var accent_color: Color = Color(0.2, 0.8, 1.0)

var _state: String = "idle"
var _erroring: bool = false

const STATION_SPRITE_BASE = "res://assets/sprites/stations/"

const TYPE_TO_SPRITE = {
	"dispatcher": "router",
	"llm": "research",
	"tool": "code",
}

@onready var label_node: Label = $Label
@onready var sprite_node: Sprite2D = $Sprite
@onready var queue_label: Label = $QueueLabel
@onready var glow_rect: ColorRect = $Glow


func setup(id: String, type: String, lbl: String, cap: int, color: Color) -> void:
	station_id = id
	station_type = type
	station_label = lbl
	capacity = cap
	accent_color = color


func _ready() -> void:
	# Station name label — accent color, outlined
	if label_node:
		label_node.text = station_label
		var ls = LabelSettings.new()
		ls.font_size = 12
		ls.font_color = accent_color
		ls.outline_size = 2
		ls.outline_color = Color(0, 0, 0, 0.85)
		label_node.label_settings = ls

	# Queue depth label — yellow, small
	if queue_label:
		var qs = LabelSettings.new()
		qs.font_size = 10
		qs.font_color = Color(1.0, 0.9, 0.3, 1.0)
		qs.outline_size = 2
		qs.outline_color = Color(0, 0, 0, 0.7)
		queue_label.label_settings = qs
		queue_label.text = ""

	# Load station sprite
	if sprite_node and station_type != "":
		var sprite_name = TYPE_TO_SPRITE.get(station_type, station_type)
		var tex_path = STATION_SPRITE_BASE + sprite_name + ".png"
		var tex = load(tex_path)
		if tex:
			sprite_node.texture = tex

	# Initial glow — dim idle state
	_apply_glow()

	WorldState.station_changed.connect(_on_station_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	call_deferred("_deferred_init")


func _deferred_init() -> void:
	var data = WorldState.stations.get(station_id, {})
	if not data.is_empty():
		_update_from_data(data)


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
	_state = data.get("state", "idle")
	queue_depth = data.get("queueDepth", 0)
	_erroring = (_state == "error" or _state == "erroring")

	if queue_label:
		queue_label.text = str(queue_depth) if queue_depth > 0 else ""

	_apply_glow()


func _apply_glow() -> void:
	if not glow_rect:
		return

	var saturation_ratio = float(queue_depth) / max(capacity, 1)

	if _erroring:
		# Red glow
		glow_rect.color = Color(1.0, 0.2, 0.2, 0.25)
	elif saturation_ratio > 0.8:
		# Amber / saturated glow
		glow_rect.color = Color(1.0, 0.6, 0.1, 0.25)
	elif queue_depth > 0:
		# Active — bright accent
		glow_rect.color = Color(accent_color.r, accent_color.g, accent_color.b, 0.2)
	else:
		# Idle — dim accent
		glow_rect.color = Color(accent_color.r, accent_color.g, accent_color.b, 0.08)
