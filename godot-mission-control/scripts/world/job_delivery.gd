extends Node2D
## Animates spaceships delivering job bricks to the Intake station.
## Jobs pile up as labeled bricks. Ships fly in from off-screen.

var _intake_pos: Vector2 = Vector2.ZERO
var _ship_textures: Array = []
var _active_ships: Array = []  # Array of ship sprite nodes in flight
var _job_bricks: Array = []  # Array of brick nodes piled at intake
var _delivery_queue: Array = []  # Job IDs waiting for delivery animation
var _delivery_timer: float = 0.0
var _last_job_count: int = 0

const MAX_VISIBLE_BRICKS = 6
const BRICK_WIDTH = 60
const BRICK_HEIGHT = 16
const SHIP_SCALE = Vector2(0.8, 0.8)
const SHIP_SPEED = 120.0

# Spawn positions (far off-screen for dramatic approach)
const SPAWN_OFFSETS = [
	Vector2(-800, -300),  # top-left
	Vector2(800, -400),   # top-right
	Vector2(-700, 300),   # left
	Vector2(0, -700),     # top
]

const BRICK_COLORS = [
	Color(0.15, 0.25, 0.4, 0.95),   # dark blue
	Color(0.2, 0.15, 0.35, 0.95),   # purple
	Color(0.12, 0.3, 0.25, 0.95),   # teal
	Color(0.3, 0.18, 0.15, 0.95),   # brown
	Color(0.2, 0.2, 0.3, 0.95),     # slate
]


func _ready() -> void:
	# Load ship textures
	for ship_name in ["ship_red", "ship_blue", "ship_green", "ship_gold"]:
		var tex = load("res://assets/sprites/ships/%s.png" % ship_name)
		if tex:
			_ship_textures.append(tex)

	WorldState.snapshot_loaded.connect(_on_snapshot)
	WorldState.job_changed.connect(_on_job_changed)


func set_intake_position(pos: Vector2) -> void:
	_intake_pos = pos


func _on_snapshot() -> void:
	# On first snapshot, create initial brick pile for queued jobs
	var queued_count = 0
	for jid in WorldState.jobs:
		if WorldState.jobs[jid].get("state", "") == "queued":
			queued_count += 1

	_last_job_count = WorldState.jobs.size()

	# Create initial pile (don't animate every single one)
	var pile_count = mini(queued_count, MAX_VISIBLE_BRICKS)
	for i in range(pile_count):
		var jid = ""
		var title = "Job %d" % (i + 1)
		# Find actual job for title
		var idx = 0
		for j in WorldState.jobs:
			if WorldState.jobs[j].get("state", "") == "queued":
				if idx == i:
					jid = j
					title = _extract_title(WorldState.jobs[j].get("type", ""))
					break
				idx += 1
		_add_brick(title, false)


func _on_job_changed(job_id: String) -> void:
	# New job appeared — queue a delivery animation
	var job = WorldState.jobs.get(job_id, {})
	if job.get("state", "") == "queued":
		var total = WorldState.jobs.size()
		if total > _last_job_count:
			_last_job_count = total
			_delivery_queue.append(job_id)


func _process(delta: float) -> void:
	# Process delivery queue — stagger deliveries
	if not _delivery_queue.is_empty():
		_delivery_timer -= delta
		if _delivery_timer <= 0:
			_delivery_timer = 0.8  # Time between deliveries
			var jid = _delivery_queue.pop_front()
			var job = WorldState.jobs.get(jid, {})
			var title = _extract_title(job.get("type", ""))
			_spawn_delivery_ship(title)

	# Update active ships
	for ship_data in _active_ships.duplicate():
		_update_ship(ship_data, delta)


func _spawn_delivery_ship(job_title: String) -> void:
	if _ship_textures.is_empty() or _intake_pos == Vector2.ZERO:
		_add_brick(job_title, true)
		return

	var ship = Sprite2D.new()
	ship.texture = _ship_textures[randi() % _ship_textures.size()]
	ship.scale = SHIP_SCALE

	# Random spawn position
	var spawn_offset = SPAWN_OFFSETS[randi() % SPAWN_OFFSETS.size()]
	ship.position = _intake_pos + spawn_offset
	ship.z_index = 20

	# Look toward target
	var dir = (_intake_pos - ship.position).normalized()
	ship.rotation = dir.angle()

	add_child(ship)

	var data = {
		"node": ship,
		"target": _intake_pos + Vector2(randf_range(-20, 20), -30),
		"title": job_title,
		"phase": "flying",  # flying -> dropping -> leaving
		"timer": 0.0,
	}
	_active_ships.append(data)


func _update_ship(data: Dictionary, delta: float) -> void:
	var ship: Sprite2D = data["node"]
	if not is_instance_valid(ship):
		_active_ships.erase(data)
		return

	match data["phase"]:
		"flying":
			var dir = (data["target"] - ship.position).normalized()
			ship.position += dir * SHIP_SPEED * delta
			ship.rotation = dir.angle()

			# Arrived?
			if ship.position.distance_to(data["target"]) < 15:
				data["phase"] = "dropping"
				data["timer"] = 1.2
				# Drop the brick
				_add_brick(data["title"], true)

		"dropping":
			data["timer"] -= delta
			# Hover briefly
			ship.position.y += sin(Time.get_ticks_msec() / 200.0) * 0.5
			if data["timer"] <= 0:
				data["phase"] = "leaving"
				# Pick a random exit direction
				data["exit_dir"] = Vector2(randf_range(-1, 1), -1).normalized()

		"leaving":
			ship.position += data["exit_dir"] * SHIP_SPEED * 1.2 * delta
			ship.modulate.a -= delta * 0.6
			if ship.modulate.a <= 0:
				ship.queue_free()
				_active_ships.erase(data)


func _add_brick(title: String, animate: bool) -> void:
	# Remove oldest brick if too many
	if _job_bricks.size() >= MAX_VISIBLE_BRICKS:
		var old = _job_bricks.pop_front()
		if is_instance_valid(old):
			old.queue_free()

	var brick = Node2D.new()
	brick.z_index = 5

	# Position in pile — stack upward
	var stack_idx = _job_bricks.size()
	var row = stack_idx / 3
	var col = stack_idx % 3
	var pile_offset = Vector2(
		-BRICK_WIDTH + col * (BRICK_WIDTH + 4),
		20 - row * (BRICK_HEIGHT + 2)
	)
	var target_pos = _intake_pos + pile_offset

	if animate:
		# Start above and fall down
		brick.position = target_pos + Vector2(0, -80)
		brick.modulate.a = 0.5
	else:
		brick.position = target_pos

	# Background
	var bg = ColorRect.new()
	bg.size = Vector2(BRICK_WIDTH, BRICK_HEIGHT)
	bg.position = Vector2(-BRICK_WIDTH / 2, -BRICK_HEIGHT / 2)
	bg.color = BRICK_COLORS[randi() % BRICK_COLORS.size()]
	brick.add_child(bg)

	# Border top
	var border = ColorRect.new()
	border.size = Vector2(BRICK_WIDTH, 1)
	border.position = Vector2(-BRICK_WIDTH / 2, -BRICK_HEIGHT / 2)
	border.color = Color(0.4, 0.7, 0.9, 0.5)
	brick.add_child(border)

	# Title text
	var lbl = Label.new()
	lbl.text = title.left(12)
	lbl.position = Vector2(-BRICK_WIDTH / 2 + 3, -BRICK_HEIGHT / 2 + 1)
	lbl.size = Vector2(BRICK_WIDTH - 6, BRICK_HEIGHT - 2)
	var lbl_settings = LabelSettings.new()
	lbl_settings.font_size = 8
	lbl_settings.font_color = Color(0.8, 0.9, 1.0, 0.9)
	lbl.label_settings = lbl_settings
	brick.add_child(lbl)

	add_child(brick)
	_job_bricks.append(brick)

	if animate:
		# Animate falling into place
		var tween = create_tween()
		tween.tween_property(brick, "position", target_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BOUNCE)
		tween.parallel().tween_property(brick, "modulate:a", 1.0, 0.2)


func _extract_title(raw: String) -> String:
	var lines = raw.split("\n")
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed.begins_with("# "):
			return trimmed.substr(2).left(20)
		if trimmed.begins_with("## "):
			return trimmed.substr(3).left(20)
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed != "":
			return trimmed.left(20)
	return "Job"
