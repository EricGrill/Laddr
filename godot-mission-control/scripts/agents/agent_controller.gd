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

var _nav_graph  # RoadSystem or NavGraph — both have find_path() and get_position()
var _pickup_timer: float = 0.0
var _pickup_duration: float = 0.5

# Activity simulation
var _activity_timer: float = 0.0
var _activity_interval: float = 4.0
var _home_station_id: String = ""

# Work cycle state machine for simulated activity
enum CyclePhase { HOME, TO_INTAKE, AT_INTAKE, TO_WORK, WORKING, TO_OUTPUT, AT_OUTPUT, TO_HOME }
var _cycle_phase: CyclePhase = CyclePhase.HOME
var _cycle_work_station: String = ""  # Station to process at based on capabilities
var _work_timer: float = 0.0
var _work_fidget_timer: float = 2.0

# Preloaded sprite textures per role
var _sprite_textures: Dictionary = {}

const SPRITE_BASE = "res://assets/sprites/agents/"
const WORKER_SPRITE_BASE = "res://assets/sprites/workers/"
const ROLES = ["router", "researcher", "coder", "reviewer", "deployer", "supervisor"]
const DIRECTIONS = ["front", "iso_left", "iso_right"]

# Stations agents visit when busy
const WORK_STATIONS = ["dispatcher", "intake", "output-dock"]


func setup(id: String, nav, color: Color) -> void:
	worker_id = id
	_nav_graph = nav
	agent_color = color
	_home_station_id = "station-" + id


func _ready() -> void:
	if animator:
		animator.set_body_sprite(body)
		animator.set_agent_sprite(agent_sprite)
		animator.set_mover(mover)
		animator.set_packet_sprite(job_packet_visual)
		animator.set_shadow_node($Body.get_node_or_null("Shadow"))
		animator.set_aura_node($Body.get_node_or_null("Aura"))
		animator.agent_color = agent_color

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

	# Hide status card — info shown on worker stations instead
	if status_card:
		status_card.visible = false
		status_card.queue_free()
		status_card = null

	_set_state(State.IDLE)
	_apply_role_visuals()
	_activity_timer = randf_range(1.0, 5.0)


func _process(delta: float) -> void:
	# Pickup animation timer
	if current_state == State.PICKING_UP:
		_pickup_timer -= delta
		if _pickup_timer <= 0:
			_transition_to_carrying()

	# Simple name label only — job info shows on worker station
	if label_node:
		var worker_data = WorldState.workers.get(worker_id, {})
		label_node.text = worker_data.get("name", worker_id.left(10))

	# Update status card
	_update_status_card()

	# Working fidget — periodic signs of life while processing at a station
	if current_state == State.WORKING and _cycle_phase == CyclePhase.WORKING:
		_work_timer -= delta
		_work_fidget_timer -= delta
		if _work_fidget_timer <= 0:
			_work_fidget_timer = randf_range(2.0, 4.0)
			_do_work_fidget()
		if _work_timer <= 0:
			# Done working — trigger delivery via _simulate_busy
			_activity_timer = 0.0

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
		var lines = []

		# Find current job title
		var job_title = ""
		for jid in WorldState.jobs:
			var job = WorldState.jobs[jid]
			if job.get("state", "") == "processing":
				var raw = str(job.get("type", ""))
				job_title = _extract_job_title(raw)
				break

		# Extract model from worker config
		var model_name = ""
		for cap in caps:
			var cap_str = ""
			if cap is Dictionary:
				cap_str = str(cap.get("id", ""))
			else:
				cap_str = str(cap)
			var c = cap_str.to_lower()
			if "embed" in c:
				continue
			if "gpt" in c or "claude" in c or "llama" in c or "gemini" in c or "mistral" in c or "qwen" in c or "deepseek" in c or "gemma" in c or "granite" in c:
				# Clean up model name
				model_name = cap_str.replace("openai-", "").replace("openai/", "")
				# Shorten common prefixes
				for prefix in ["anthropic/", "google/", "meta/", "mistralai/", "qwen/", "deepseek/", "nvidia/"]:
					model_name = model_name.replace(prefix, "")
				if model_name.length() > 22:
					model_name = model_name.left(22)
				break

		if job_title != "":
			lines.append(job_title)
		if model_name != "":
			lines.append(model_name)
		lines.append("%d active" % active)

		status_text.text = "\n".join(lines)
		status_card.position.y = -75 + sin(Time.get_ticks_msec() / 1000.0 * 1.5) * 2.0
	else:
		if status_card.visible and current_state == State.IDLE:
			status_card.visible = false


func _simulate_activity() -> void:
	if current_state == State.MOVING or current_state == State.CARRYING:
		return  # Already moving
	if current_state == State.WORKING and _cycle_phase == CyclePhase.WORKING and _work_timer > 0:
		return  # Still working — _process handles fidgets and completion

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
	# Drive a proper work cycle: home → intake → work station → output → home
	match _cycle_phase:
		CyclePhase.HOME, CyclePhase.AT_OUTPUT, CyclePhase.TO_HOME:
			# Start a new cycle — go pick up a job from intake
			_cycle_phase = CyclePhase.TO_INTAKE
			_pick_work_station()
			_move_to_station("intake")
			_set_state(State.MOVING)
			if animator:
				animator.show_emote("thinking")

		CyclePhase.AT_INTAKE:
			# Picked up job — carry it to the work station
			_cycle_phase = CyclePhase.TO_WORK
			_show_carried_packet()
			_move_to_station(_cycle_work_station)
			_set_state(State.CARRYING)
			if animator:
				animator.show_emote("lightbulb")

		CyclePhase.WORKING:
			# Done working — deliver to output
			_cycle_phase = CyclePhase.TO_OUTPUT
			_move_to_station("output-dock")
			_set_state(State.DELIVERING)
			if animator:
				animator.show_emote("success")

		_:
			pass  # Moving — wait for arrival


func _pick_work_station() -> void:
	# Choose a work station based on the worker's actual capabilities
	var worker_data = WorldState.workers.get(worker_id, {})
	var caps = worker_data.get("capabilities", [])
	var station_map = {"llm": "research", "code": "code", "tool": "code", "review": "review", "research": "research"}
	for cap in caps:
		var cap_str = str(cap.get("id", cap) if cap is Dictionary else cap).to_lower()
		for key in station_map:
			if key in cap_str:
				var target = station_map[key]
				if _nav_graph and _nav_graph.get_position(target) != Vector2.ZERO:
					_cycle_work_station = target
					return
	# Fallback to dispatcher
	_cycle_work_station = "dispatcher"


func _show_carried_packet() -> void:
	if not job_packet_visual:
		return
	job_packet_visual.visible = true
	# Try to match an actual job's priority
	var worker_station_id = "station-" + worker_id
	var pri = "normal"
	for jid in WorldState.jobs:
		var job = WorldState.jobs[jid]
		var assigned = str(job.get("assignedAgent", ""))
		var station = str(job.get("currentStationId", ""))
		if assigned == worker_id or station == worker_station_id:
			pri = str(job.get("priority", "normal"))
			break
	var tex = load("res://assets/sprites/packets/packet_%s.png" % pri)
	if tex:
		job_packet_visual.texture = tex


func _simulate_idle() -> void:
	# Reset cycle when idle
	_cycle_phase = CyclePhase.HOME

	# When idle, go home and stay there. Occasional fidget only.
	if _home_station_id != "" and _nav_graph:
		var home_pos = _nav_graph.get_position(_home_station_id)
		if home_pos != Vector2.ZERO and position.distance_to(home_pos) > 30:
			# Not home yet — go home
			_move_to_station(_home_station_id)
			_set_state(State.MOVING)
			return

	# Already home — just fidget occasionally
	if randf() < 0.3 and animator:
		animator.play_squash()
	# Hide packet when idle
	if job_packet_visual:
		job_packet_visual.visible = false


func _do_work_fidget() -> void:
	# Periodic signs of life while working at a station
	if not animator:
		return
	var roll = randf()
	if roll < 0.35:
		# Squash/bounce — the classic "I'm here" animation
		animator.play_squash()
	elif roll < 0.65:
		# Thinking emote — actively processing
		animator.show_emote("thinking")
	elif roll < 0.85:
		# Lightbulb — making progress
		animator.show_emote("lightbulb")
	else:
		# Stretch — taking a micro-break
		animator.play_stretch()


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
	var motion_role = role if role != "" else ROLES[worker_id.hash() % ROLES.size()]
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

	if not found_worker_sprite:
		# Fallback to role-based sprites when no custom worker art exists.
		for dir in DIRECTIONS:
			var path = SPRITE_BASE + motion_role + "/" + motion_role + "_" + dir + ".png"
			var tex = load(path)
			if tex:
				_sprite_textures[dir] = tex

	if _sprite_textures.has("front"):
		agent_sprite.texture = _sprite_textures["front"]
	if animator:
		animator.agent_color = agent_color
		animator.set_role_profile(motion_role)
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
			# Advance cycle: arrived at intake → pause to pick up
			if _cycle_phase == CyclePhase.TO_INTAKE:
				_cycle_phase = CyclePhase.AT_INTAKE
				_set_state(State.PICKING_UP)
				_pickup_timer = 0.8
				if animator:
					animator.play_squash()
			elif _cycle_phase == CyclePhase.TO_HOME:
				_cycle_phase = CyclePhase.HOME
				_set_state(State.IDLE)
				if animator:
					animator.play_squash()
			else:
				_set_state(State.IDLE)
				if animator:
					animator.play_squash()

		State.CARRYING:
			# Arrived at work station — start working
			if _cycle_phase == CyclePhase.TO_WORK:
				_cycle_phase = CyclePhase.WORKING
				_set_state(State.WORKING)
				# Scale work duration: more active jobs = longer stay at station
				var wd = WorldState.workers.get(worker_id, {})
				var job_count = wd.get("activeJobs", 1)
				_work_timer = randf_range(6.0, 12.0) + job_count * 3.0
				_work_fidget_timer = randf_range(1.5, 3.0)
				_activity_timer = _work_timer + 1.0  # Safety — work_timer drives delivery
				if animator:
					animator.play_squash()
					animator.show_emote("lightbulb")
			else:
				_set_state(State.WORKING)
				_activity_timer = randf_range(2.0, 5.0)
				if animator:
					animator.play_squash()

		State.DELIVERING:
			# Arrived at output-dock — job delivered
			_cycle_phase = CyclePhase.AT_OUTPUT
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			if animator:
				animator.play_stretch()
				animator.show_emote("success")
			# Check if still busy — start new cycle or go home
			var worker_data = WorldState.workers.get(worker_id, {})
			var active = worker_data.get("activeJobs", 0)
			if active > 0:
				_activity_timer = randf_range(1.0, 2.0)  # Quick turnaround
				_set_state(State.IDLE)
			else:
				# Go home
				_cycle_phase = CyclePhase.TO_HOME
				_move_to_station(_home_station_id)
				_set_state(State.MOVING)

		State.ERRORED:
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_cycle_phase = CyclePhase.HOME
			_set_state(State.IDLE)

		State.PICKING_UP:
			# Pickup timer handles transition, but if mover fires arrived during pickup
			pass


func _transition_to_carrying() -> void:
	# If we're in the work cycle (picked up at intake), use the cycle flow
	if _cycle_phase == CyclePhase.AT_INTAKE:
		_cycle_phase = CyclePhase.TO_WORK
		_show_carried_packet()
		_move_to_station(_cycle_work_station)
		_set_state(State.CARRYING)
		if animator:
			animator.play_stretch()
			animator.show_emote("lightbulb")
		return

	# Fallback for signal-driven jobs
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


func _extract_job_title(raw: String) -> String:
	# Extract a readable title from job type/system prompt
	var lines = raw.split("\n")
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed.begins_with("# "):
			return trimmed.substr(2).left(28)
		if trimmed.begins_with("## "):
			return trimmed.substr(3).left(28)
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed != "" and trimmed.length() > 3:
			return trimmed.left(28)
	return ""


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			EventBus.entity_selected.emit("agent", worker_id)
			EventBus.camera_focus_requested.emit(global_position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			EventBus.camera_follow_requested.emit("agent", worker_id)
