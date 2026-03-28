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

# Map backend station types to sprite filenames (for types without their own sprite)
const TYPE_TO_SPRITE = {
	"dispatcher": "router",
	"llm": "research",
	"tool": "code",
}

@onready var label_node: Label = $Label
@onready var sprite_node: Sprite2D = $Sprite
@onready var queue_label: Label = $QueueLabel
@onready var info_label: Label = $InfoLabel
@onready var click_area: Area2D = $ClickArea


func setup(id: String, type: String, lbl: String, cap: int, color: Color) -> void:
	station_id = id
	station_type = type
	station_label = lbl
	capacity = cap
	_original_color = color


func _ready() -> void:
	# Apply setup params now that @onready nodes are available
	if label_node:
		label_node.text = station_label
		var label_settings = LabelSettings.new()
		label_settings.font_size = 14
		label_settings.font_color = Color.WHITE
		label_settings.outline_size = 3
		label_settings.outline_color = Color(0, 0, 0, 0.8)
		label_node.label_settings = label_settings

	if info_label:
		var info_settings = LabelSettings.new()
		info_settings.font_size = 10
		info_settings.font_color = Color(0.7, 0.8, 0.7, 0.9)
		info_settings.outline_size = 2
		info_settings.outline_color = Color(0, 0, 0, 0.6)
		info_label.label_settings = info_settings

	if queue_label:
		var q_settings = LabelSettings.new()
		q_settings.font_size = 12
		q_settings.font_color = Color(1.0, 0.9, 0.5, 1.0)
		q_settings.outline_size = 2
		q_settings.outline_color = Color(0, 0, 0, 0.7)
		queue_label.label_settings = q_settings

	# Load station sprite texture (map backend types to available sprites)
	if sprite_node and station_type != "":
		var sprite_name = TYPE_TO_SPRITE.get(station_type, station_type)
		var tex_path = STATION_SPRITE_BASE + sprite_name + ".png"
		var tex = load(tex_path)
		if tex:
			sprite_node.texture = tex

	# Worker stations get a big info screen panel below the sprite
	var is_worker_station = station_id.begins_with("station-")
	if is_worker_station:
		if sprite_node:
			sprite_node.scale = Vector2(0.8, 0.8)
		# Create a visible info panel programmatically (scene InfoLabel is too small)
		var panel = ColorRect.new()
		panel.name = "WorkerInfoPanel"
		panel.size = Vector2(180, 55)
		panel.position = Vector2(-90, 45)
		panel.color = Color(0.06, 0.1, 0.15, 0.9)
		panel.z_index = 5
		add_child(panel)
		var border = ColorRect.new()
		border.size = Vector2(180, 2)
		border.position = Vector2(-90, 45)
		border.color = Color(0.2, 0.8, 0.95, 0.7)
		border.z_index = 5
		add_child(border)
		# Replace info_label with a new properly sized one inside the panel
		if info_label:
			info_label.queue_free()
		info_label = Label.new()
		info_label.name = "WorkerInfoText"
		info_label.size = Vector2(170, 48)
		info_label.position = Vector2(-85, 49)
		info_label.z_index = 6
		info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		var ws = LabelSettings.new()
		ws.font_size = 11
		ws.font_color = Color(0.4, 0.95, 1.0, 1.0)
		ws.outline_size = 1
		ws.outline_color = Color(0, 0, 0, 0.6)
		info_label.label_settings = ws
		add_child(info_label)

	WorldState.station_changed.connect(_on_station_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)
	WorldState.metrics_changed.connect(_on_metrics_changed)

	# Deferred initial update — setup() ran before @onready nodes existed
	call_deferred("_deferred_init")

	if click_area:
		click_area.input_event.connect(_on_click_area_input)

	var effects = get_node_or_null("StationEffects")
	if effects:
		effects.setup(station_type, capacity)


func _deferred_init() -> void:
	# Initial data update after tree is ready
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


func _on_worker_changed(worker_id_changed: String, _is_new: bool) -> void:
	# If this is our worker station, refresh the display
	var data = WorldState.stations.get(station_id, {})
	var our_worker = data.get("workerId", "")
	if our_worker == worker_id_changed:
		_update_from_data(data)


func _on_metrics_changed() -> void:
	var data = WorldState.stations.get(station_id, {})
	if not data.is_empty() and station_id.begins_with("station-"):
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

	# Worker stations show model + task on their "screen"
	if info_label:
		# workerId can be null, string, or missing
		var worker_id_val = str(data.get("workerId", ""))
		if worker_id_val != "" and worker_id_val != "null" and worker_id_val != "<null>":
			# This is a worker station — show detailed info
			var worker_data = WorldState.workers.get(worker_id_val, {})
			# Fallback: try stripping "station-" prefix from our ID
			if worker_data.is_empty():
				var fallback_id = station_id.replace("station-", "")
				worker_data = WorldState.workers.get(fallback_id, {})
			var active = worker_data.get("activeJobs", 0)
			var caps = worker_data.get("capabilities", [])
			var lines = []

			# Extract model name
			for cap in caps:
				var cap_str = ""
				if cap is Dictionary:
					cap_str = str(cap.get("id", ""))
				else:
					cap_str = str(cap)
				var c = cap_str.to_lower()
				if "embed" in c:
					continue
				if "gpt" in c or "claude" in c or "llama" in c or "gemini" in c or "mistral" in c or "qwen" in c or "deepseek" in c or "gemma" in c or "nemotron" in c:
					var clean = cap_str
					for prefix in ["openai/", "anthropic/", "google/", "meta/", "mistralai/", "qwen/", "deepseek-ai/", "nvidia/"]:
						clean = clean.replace(prefix, "")
					lines.append(clean.left(24))
					break

			if active > 0:
				lines.append("%d active" % active)
				# Find current job title
				for jid in WorldState.jobs:
					var job = WorldState.jobs[jid]
					if job.get("state", "") == "processing":
						var raw = str(job.get("type", ""))
						for line in raw.split("\n"):
							var t = line.strip_edges()
							if t.begins_with("# "):
								lines.append(t.substr(2).left(22))
								break
						break
			else:
				lines.append("idle")

			info_label.text = "\n".join(lines)
		else:
			info_label.text = state if state != "idle" else ""

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
