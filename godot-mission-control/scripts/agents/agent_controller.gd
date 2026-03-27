extends CharacterBody2D
## Agent FSM brain. Subscribes to WorldState signals and drives mover/animator.
## Maps to a backend worker — reflects worker status, active jobs, and movement.

enum State { IDLE, MOVING, PICKING_UP, CARRYING, WORKING, DELIVERING, BLOCKED, ERRORED, OFFLINE }

@export var worker_id: String = ""
@export var agent_color: Color = Color.html("#d4836b")

var current_state: State = State.IDLE
var current_job_id: String = ""
var target_station_id: String = ""
var role: String = ""
var _worker_status: String = "online"
var _active_jobs: int = 0

@onready var mover: Node = $AgentMover
@onready var animator: Node = $AgentAnimator
@onready var body: Node2D = $Body
@onready var agent_sprite: Sprite2D = $Body/AgentSprite
@onready var label_node: Label = $Label
@onready var job_packet_visual: Sprite2D = $Body/JobPacket
@onready var status_card: Node2D = $Body/StatusCard
@onready var status_text: Label = $Body/StatusCard/StatusText
@onready var click_area: Area2D = $ClickArea

var _nav_graph: NavGraph
var _pickup_timer: float = 0.0
var _pickup_duration: float = 0.5

# Activity simulation
var _activity_timer: float = 0.0
var _activity_interval: float = 4.0
var _home_station_id: String = ""

# Preloaded sprite textures per role
var _sprite_textures: Dictionary = {}

const SPRITE_BASE = "res://assets/sprites/agents/"
const WORKER_SPRITE_BASE = "res://assets/sprites/workers/"
const ROLES = ["router", "researcher", "coder", "reviewer", "deployer", "supervisor"]
const DIRECTIONS = ["front", "iso_left", "iso_right"]

# Stations agents visit when busy
const WORK_STATIONS = ["dispatcher", "intake", "output-dock"]


func setup(id: String, nav: NavGraph, color: Color) -> void:
	worker_id = id
	_nav_graph = nav
	agent_color = color
	_home_station_id = "station-" + id


func _ready() -> void:
	if animator:
		animator.body_sprite = body
		animator.agent_sprite = agent_sprite
		animator.mover = mover

	if mover:
		mover.arrived.connect(_on_arrived)

	# Style label
	if label_node:
		var lbl_settings = LabelSettings.new()
		lbl_settings.font_size = 11
		lbl_settings.font_color = Color(0.9, 0.95, 1.0, 0.9)
		lbl_settings.outline_size = 2
		lbl_settings.outline_color = Color(0, 0, 0, 0.7)
		label_node.label_settings = lbl_settings

	WorldState.job_assigned.connect(_on_job_assigned)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.job_handoff.connect(_on_job_handoff)
	WorldState.agent_changed.connect(_on_agent_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)
	WorldState.worker_changed.connect(_on_worker_changed)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)

	if job_packet_visual:
		job_packet_visual.visible = false

	# Style status card text
	if status_text:
		var st_settings = LabelSettings.new()
		st_settings.font_size = 13
		st_settings.font_color = Color(0.85, 0.97, 1.0, 1.0)
		st_settings.outline_size = 1
		st_settings.outline_color = Color(0, 0, 0, 0.5)
		status_text.label_settings = st_settings
		status_text.autowrap_mode = TextServer.AUTOWRAP_WORD

	if status_card:
		status_card.visible = false

	_set_state(State.IDLE)
	_apply_role_visuals()
	_activity_timer = randf_range(1.0, 5.0)


func _process(delta: float) -> void:
	# Pickup animation timer
	if current_state == State.PICKING_UP:
		_pickup_timer -= delta
		if _pickup_timer <= 0:
			_transition_to_carrying()

	# Update label with worker info
	if label_node:
		var worker_data = WorldState.workers.get(worker_id, {})
		var name = worker_data.get("name", worker_id.left(10))
		var status = worker_data.get("status", "idle")
		var active = worker_data.get("activeJobs", 0)
		if active > 0:
			label_node.text = "%s (%d jobs)" % [name, active]
		else:
			label_node.text = "%s - %s" % [name, status]

	# Update status card
	_update_status_card()

	# Activity simulation — make agents move and do things based on worker state
	_activity_timer -= delta
	if _activity_timer <= 0:
		_activity_timer = randf_range(3.0, 7.0)
		_simulate_activity()


func _update_status_card() -> void:
	if not status_card or not status_text:
		return

	var worker_data = WorldState.workers.get(worker_id, {})
	var active = worker_data.get("activeJobs", 0)
	var status = worker_data.get("status", "online")
	var caps = worker_data.get("capabilities", [])

	var is_busy = active > 0 or current_state in [State.WORKING, State.CARRYING, State.DELIVERING]

	if is_busy:
		status_card.visible = true

		# Extract primary model name from capabilities
		var model_name = ""
		for cap in caps:
			var cap_str = ""
			if cap is Dictionary:
				cap_str = str(cap.get("id", ""))
			else:
				cap_str = str(cap)
			var c = cap_str.to_lower()
			if "embed" in c:
				continue  # Skip embedding models
			if "gpt" in c or "claude" in c or "llama" in c or "gemini" in c or "mistral" in c or "qwen" in c or "deepseek" in c:
				model_name = cap_str.get_file().replace("openai-", "")
				if model_name.length() > 20:
					model_name = model_name.left(20)
				break

		# Short card: model + job count
		if model_name != "":
			status_text.text = "%s\n%d job%s" % [model_name, active, "s" if active != 1 else ""]
		else:
			status_text.text = "%d job%s" % [active, "s" if active != 1 else ""]

		status_card.position.y = -75 + sin(Time.get_ticks_msec() / 1000.0 * 1.5) * 3.0
	else:
		if status_card.visible and current_state == State.IDLE:
			status_card.visible = false


func _simulate_activity() -> void:
	if current_state == State.MOVING or current_state == State.CARRYING:
		return  # Already moving

	var worker_data = WorldState.workers.get(worker_id, {})
	var active = worker_data.get("activeJobs", 0)
	var status = worker_data.get("status", "online")

	if status == "offline":
		_set_state(State.OFFLINE)
		return

	if active > 0 or status == "busy":
		# Worker is busy — simulate job processing
		_simulate_busy()
	else:
		# Worker is idle — occasional wandering
		_simulate_idle()


func _simulate_busy() -> void:
	var destinations = []
	for sid in ["dispatcher", "intake", "output-dock"]:
		if _nav_graph and _nav_graph.get_position(sid) != Vector2.ZERO:
			destinations.append(sid)
	if _home_station_id != "" and _nav_graph and _nav_graph.get_position(_home_station_id) != Vector2.ZERO:
		destinations.append(_home_station_id)

	if destinations.is_empty():
		if animator:
			animator.show_emote("lightbulb")
		return

	# Weighted: prefer home station and dispatcher
	var weighted = [_home_station_id, _home_station_id, "dispatcher", "dispatcher"]
	for sid in destinations:
		weighted.append(sid)
	var target = weighted[randi() % weighted.size()]
	if _nav_graph and _nav_graph.get_position(target) == Vector2.ZERO:
		target = destinations[randi() % destinations.size()]

	# Show carrying a packet
	if job_packet_visual:
		job_packet_visual.visible = true
		var priorities = ["normal", "high", "critical"]
		var pri = priorities[randi() % priorities.size()]
		var tex = load("res://assets/sprites/packets/packet_%s.png" % pri)
		if tex:
			job_packet_visual.texture = tex

	_move_to_station(target)
	_set_state(State.CARRYING)

	# Varied emotes while working
	if animator:
		var emotes = ["lightbulb", "thinking", "success", "lightbulb", "thinking"]
		animator.show_emote(emotes[randi() % emotes.size()])


func _simulate_idle() -> void:
	# Occasionally wander to a nearby station and back
	if randf() < 0.4:
		# Stay put, just fidget
		if animator:
			if randf() < 0.5:
				animator.play_squash()
			else:
				animator.show_emote("thinking")
		return

	# Wander to a random reachable station
	var destinations = []
	for sid in ["dispatcher", "intake", _home_station_id]:
		if _nav_graph and _nav_graph.get_position(sid) != Vector2.ZERO:
			destinations.append(sid)

	if not destinations.is_empty():
		var target = destinations[randi() % destinations.size()]
		_move_to_station(target)
		_set_state(State.MOVING)


func _set_state(new_state: State) -> void:
	current_state = new_state
	if animator:
		animator.set_walking(new_state in [State.MOVING, State.CARRYING, State.DELIVERING])
	if job_packet_visual:
		job_packet_visual.visible = new_state in [State.CARRYING, State.DELIVERING, State.PICKING_UP]


# --- Signal handlers ---

func _on_job_assigned(job_id: String, agent_id: String, station_id: String) -> void:
	if not _is_my_agent(agent_id):
		return
	current_job_id = job_id
	target_station_id = station_id
	_update_carried_packet()
	_move_to_station(station_id)
	_set_state(State.MOVING)


func _on_job_completed(job_id: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = "output-dock"
	_move_to_station("output-dock")
	_set_state(State.DELIVERING)
	if animator:
		animator.play_stretch()
		animator.show_emote("success")


func _on_job_failed(job_id: String, _reason: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = "error-chamber"
	_move_to_station("error-chamber")
	_set_state(State.ERRORED)
	if animator:
		animator.show_emote("error")


func _on_job_handoff(job_id: String, _from: String, to_station_id: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = to_station_id
	_move_to_station(to_station_id)
	_set_state(State.CARRYING)


func _on_agent_changed(agent_id: String) -> void:
	if not _is_my_agent(agent_id):
		return
	var agent_data = WorldState.agents.get(agent_id, {})
	var backend_state = agent_data.get("state", "")
	match backend_state:
		"blocked":
			_set_state(State.BLOCKED)
			if mover:
				mover.stop()
			if animator:
				animator.show_emote("blocked")
		"offline":
			_set_state(State.OFFLINE)
			if mover:
				mover.stop()


func _on_worker_changed(wid: String, _is_new: bool) -> void:
	if wid != worker_id:
		return
	# Worker data updated — our _process loop will pick up the changes


func _on_snapshot_loaded() -> void:
	for agent_id in WorldState.agents:
		if _is_my_agent(agent_id):
			var data = WorldState.agents[agent_id]
			role = data.get("role", "")
			var job_id = data.get("currentJobId", "")
			if job_id != "":
				current_job_id = job_id
				_update_carried_packet()
				var station = data.get("currentStationId", "")
				if station != "":
					_move_to_station(station)
					_set_state(State.CARRYING)
			break
	_apply_role_visuals()


func _apply_role_visuals() -> void:
	if not agent_sprite:
		return

	# Try worker-specific sprites first (e.g., maul, snoke, darth)
	# Use the worker's display name from backend, fallback to ID with suffix stripped
	var worker_data = WorldState.workers.get(worker_id, {})
	var worker_name = worker_data.get("name", worker_id).to_lower().strip_edges()
	# Also try stripping -01, -02 etc suffix from the ID
	if worker_name == "" or worker_name == worker_id:
		var parts = worker_id.to_lower().split("-")
		if parts.size() > 1 and parts[-1].is_valid_int():
			worker_name = "-".join(parts.slice(0, parts.size() - 1))
		else:
			worker_name = worker_id.to_lower()
	var found_worker_sprite = false
	for dir in DIRECTIONS:
		var path = WORKER_SPRITE_BASE + worker_name + "/" + worker_name + "_" + dir + ".png"
		var tex = load(path)
		if tex:
			_sprite_textures[dir] = tex
			found_worker_sprite = true

	# Fallback to role-based sprites
	if not found_worker_sprite:
		var actual_role = role if role != "" else ROLES[worker_id.hash() % ROLES.size()]
		for dir in DIRECTIONS:
			var path = SPRITE_BASE + actual_role + "/" + actual_role + "_" + dir + ".png"
			var tex = load(path)
			if tex:
				_sprite_textures[dir] = tex

	if _sprite_textures.has("front"):
		agent_sprite.texture = _sprite_textures["front"]
	if animator:
		animator.set_role_textures(_sprite_textures)


func _update_carried_packet() -> void:
	if not job_packet_visual:
		return
	var job_data = WorldState.jobs.get(current_job_id, {})
	var pri = job_data.get("priority", "normal")
	var packet_path = "res://assets/sprites/packets/packet_" + pri + ".png"
	var tex = load(packet_path)
	if tex:
		job_packet_visual.texture = tex


func _on_arrived() -> void:
	match current_state:
		State.MOVING:
			_set_state(State.IDLE)
			if animator:
				animator.play_squash()
		State.CARRYING:
			_set_state(State.WORKING)
			if animator:
				animator.play_squash()
				animator.show_emote("lightbulb")
			# After working briefly, go back idle
			_activity_timer = randf_range(2.0, 5.0)
		State.DELIVERING:
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)
			if animator:
				animator.play_stretch()
				animator.show_emote("success")
		State.ERRORED:
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)


func _transition_to_carrying() -> void:
	var job_data = WorldState.jobs.get(current_job_id, {})
	var target = job_data.get("currentStationId", "")
	if target == "" or target == target_station_id:
		target = "dispatcher"
	target_station_id = target
	_move_to_station(target)
	_set_state(State.CARRYING)
	if animator:
		animator.play_stretch()


func _move_to_station(station_id: String) -> void:
	if not _nav_graph:
		return
	var from_id = _find_nearest_station_id()
	var path = _nav_graph.find_path(from_id, station_id)
	if path.is_empty():
		var target_pos = _nav_graph.get_position(station_id)
		if target_pos != Vector2.ZERO:
			path = [target_pos]
	if mover and not path.is_empty():
		mover.start_path(path)


func _find_nearest_station_id() -> String:
	var best_id = ""
	var best_dist = INF
	for station_id in WorldState.stations:
		var pos = _nav_graph.get_position(station_id)
		if pos == Vector2.ZERO:
			continue
		var dist = position.distance_to(pos)
		if dist < best_dist:
			best_dist = dist
			best_id = station_id
	return best_id if best_id != "" else "intake"


func _is_my_agent(agent_id: String) -> bool:
	var agent_data = WorldState.agents.get(agent_id, {})
	var agent_worker = agent_data.get("workerId", agent_id)
	return agent_worker == worker_id or agent_id == worker_id


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			EventBus.entity_selected.emit("agent", worker_id)
			EventBus.camera_focus_requested.emit(global_position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			EventBus.camera_follow_requested.emit("agent", worker_id)
