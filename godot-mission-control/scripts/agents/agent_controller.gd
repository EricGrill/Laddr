extends CharacterBody2D
## Agent FSM brain. Subscribes to WorldState signals and drives mover/animator.
## Extends CharacterBody2D for move_and_slide() collision support.

enum State { IDLE, MOVING, PICKING_UP, CARRYING, WORKING, DELIVERING, BLOCKED, ERRORED, OFFLINE }

@export var worker_id: String = ""
@export var agent_color: Color = Color.html("#d4836b")  # Claude terracotta

var current_state: State = State.IDLE
var current_job_id: String = ""
var target_station_id: String = ""
var role: String = ""

@onready var mover: Node = $AgentMover
@onready var animator: Node = $AgentAnimator
@onready var body: Node2D = $Body
@onready var eyes: Node2D = $Body/Eyes
@onready var label_node: Label = $Label
@onready var job_packet_visual: Node2D = $Body/JobPacket
@onready var click_area: Area2D = $ClickArea

var _nav_graph: NavGraph
var _pickup_timer: float = 0.0
var _pickup_duration: float = 0.5


func setup(id: String, nav: NavGraph, color: Color) -> void:
	worker_id = id
	_nav_graph = nav
	agent_color = color
	if body and body.has_method("set_color"):
		body.set_color(color)


func _ready() -> void:
	# Wire animator
	if animator:
		animator.body_sprite = body
		animator.eyes_sprite = eyes
		animator.mover = mover

	# Wire mover
	if mover:
		mover.arrived.connect(_on_arrived)

	# Subscribe to WorldState
	WorldState.job_assigned.connect(_on_job_assigned)
	WorldState.job_completed.connect(_on_job_completed)
	WorldState.job_failed.connect(_on_job_failed)
	WorldState.job_handoff.connect(_on_job_handoff)
	WorldState.agent_changed.connect(_on_agent_changed)
	WorldState.snapshot_loaded.connect(_on_snapshot_loaded)

	if click_area:
		click_area.input_event.connect(_on_click_area_input)

	# Hide job packet initially
	if job_packet_visual:
		job_packet_visual.visible = false

	_set_state(State.IDLE)


func _process(delta: float) -> void:
	# Pickup animation timer
	if current_state == State.PICKING_UP:
		_pickup_timer -= delta
		if _pickup_timer <= 0:
			_transition_to_carrying()

	# Update label
	if label_node:
		label_node.text = worker_id.left(8)


func _set_state(new_state: State) -> void:
	current_state = new_state
	if animator:
		animator.set_walking(new_state in [State.MOVING, State.CARRYING, State.DELIVERING])
	if job_packet_visual:
		job_packet_visual.visible = new_state in [State.CARRYING, State.DELIVERING, State.PICKING_UP]


# --- Signal handlers ---

func _on_job_assigned(job_id: String, agent_id: String, station_id: String) -> void:
	# Find which worker this agent represents
	if not _is_my_agent(agent_id):
		return
	current_job_id = job_id
	target_station_id = station_id
	# Move to the station where the job is
	_move_to_station(station_id)
	_set_state(State.MOVING)


func _on_job_completed(job_id: String) -> void:
	if job_id != current_job_id:
		return
	# Deliver to output dock
	target_station_id = "output_dock"
	_move_to_station("output_dock")
	_set_state(State.DELIVERING)
	if animator:
		animator.play_stretch()


func _on_job_failed(job_id: String, _reason: String) -> void:
	if job_id != current_job_id:
		return
	target_station_id = "error_chamber"
	_move_to_station("error_chamber")
	_set_state(State.ERRORED)


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
		"offline":
			_set_state(State.OFFLINE)
			if mover:
				mover.stop()


func _on_snapshot_loaded() -> void:
	# Find our agent data and sync state
	for agent_id in WorldState.agents:
		if _is_my_agent(agent_id):
			var data = WorldState.agents[agent_id]
			role = data.get("role", "")
			var job_id = data.get("currentJobId", "")
			if job_id != "":
				current_job_id = job_id
				# If agent has a job and station, go to working state
				var station = data.get("currentStationId", "")
				if station != "":
					_move_to_station(station)
					_set_state(State.CARRYING)
			break
	_apply_role_visuals()


func _apply_role_visuals() -> void:
	# Add visual accessory based on role
	var accessory = ColorRect.new()
	accessory.size = Vector2(8, 4)
	accessory.position = Vector2(-4, -14)

	match role:
		"router":
			accessory.color = Color.html("#5b9bd5")  # blue visor
			accessory.size = Vector2(16, 3)
			accessory.position = Vector2(-8, -6)
		"researcher":
			accessory.color = Color.html("#85c1e9")  # glasses
			accessory.size = Vector2(12, 3)
			accessory.position = Vector2(-6, -4)
		"coder":
			accessory.color = Color.html("#333333")  # headphones
			accessory.size = Vector2(18, 3)
			accessory.position = Vector2(-9, -12)
		"reviewer":
			accessory.color = Color.html("#a8d8b9")  # clipboard
			accessory.size = Vector2(6, 8)
			accessory.position = Vector2(10, -6)
		"deployer":
			accessory.color = Color.html("#82e0aa")  # tool belt
			accessory.size = Vector2(16, 2)
			accessory.position = Vector2(-8, 4)
		"supervisor":
			accessory.color = Color.html("#f5b041")  # tiny hat
			accessory.size = Vector2(10, 4)
			accessory.position = Vector2(-5, -14)
			# Also make supervisor slightly larger
			if body:
				body.scale = Vector2(1.2, 1.2)
		_:
			accessory.queue_free()
			return

	accessory.name = "Accessory"
	if body:
		body.add_child(accessory)


func _on_arrived() -> void:
	match current_state:
		State.MOVING:
			# Arrived at pickup location
			_set_state(State.PICKING_UP)
			_pickup_timer = _pickup_duration
			if animator:
				animator.play_squash()
		State.CARRYING:
			# Arrived at work station
			_set_state(State.WORKING)
			if animator:
				animator.play_squash()
		State.DELIVERING:
			# Delivered job, go idle
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)
			if animator:
				animator.play_stretch()
		State.ERRORED:
			# Dropped off at error chamber
			current_job_id = ""
			if job_packet_visual:
				job_packet_visual.visible = false
			_set_state(State.IDLE)


func _transition_to_carrying() -> void:
	# After pickup, find the job's target station and carry there
	var job_data = WorldState.jobs.get(current_job_id, {})
	var target = job_data.get("currentStationId", "")
	if target == "" or target == target_station_id:
		# Job might need to go to dispatcher first
		target = "dispatcher"
	target_station_id = target
	_move_to_station(target)
	_set_state(State.CARRYING)
	if animator:
		animator.play_stretch()


func _move_to_station(station_id: String) -> void:
	if not _nav_graph:
		return
	# Find closest station to current position to use as path start
	var from_id = _find_nearest_station_id()
	var path = _nav_graph.find_path(from_id, station_id)
	if path.is_empty():
		# Fallback: move directly
		var target_pos = _nav_graph.get_position(station_id)
		if target_pos != Vector2.ZERO:
			path = [target_pos]
	if mover and not path.is_empty():
		mover.start_path(path)


func _find_nearest_station_id() -> String:
	var best_id = ""
	var best_dist = INF
	# Check all nav graph nodes
	for station_id in WorldState.stations:
		var pos = _nav_graph.get_position(station_id)
		if pos == Vector2.ZERO:
			continue
		var dist = position.distance_to(pos)
		if dist < best_dist:
			best_dist = dist
			best_id = station_id
	# Also check waypoints (they might be closer)
	return best_id if best_id != "" else "intake"


func _is_my_agent(agent_id: String) -> bool:
	# Match agent to this worker node.
	# The backend uses agent IDs that correspond to worker IDs.
	# Check if the agent's worker matches our worker_id.
	var agent_data = WorldState.agents.get(agent_id, {})
	var agent_worker = agent_data.get("workerId", agent_id)
	return agent_worker == worker_id or agent_id == worker_id


func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		EventBus.entity_selected.emit("agent", worker_id)
		EventBus.camera_focus_requested.emit(global_position)
