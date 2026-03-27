@tool
extends EditorScript

## Generates a sprite preview scene for visual QA of all V1 sprites.
## Run from Editor > Run Script in Godot.

func _run() -> void:
	var root = Node2D.new()
	root.name = "SpritePreview"

	# Add camera
	var camera = Camera2D.new()
	camera.name = "Camera2D"
	camera.position = Vector2(600, 400)
	camera.zoom = Vector2(1.0, 1.0)
	root.add_child(camera)
	camera.owner = root

	# Background
	var bg = ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.15, 0.15, 0.2, 1.0)
	bg.position = Vector2(-100, -100)
	bg.size = Vector2(1400, 1000)
	bg.z_index = -10
	root.add_child(bg)
	bg.owner = root

	var roles = ["router", "researcher", "coder", "reviewer", "deployer", "supervisor"]
	var directions = ["front", "iso_left", "iso_right"]
	var station_types = ["intake", "router", "research", "code", "review", "output", "supervisor", "error"]
	var packet_priorities = ["low", "normal", "high", "critical"]

	var y_offset = 40
	var x_start = 80

	# Row labels and sprites for agents
	for dir_idx in range(directions.size()):
		var dir = directions[dir_idx]
		var label = Label.new()
		label.name = "Label_Agent_%s" % dir
		label.text = "Agents (%s)" % dir.replace("_", " ")
		label.position = Vector2(x_start - 60, y_offset + dir_idx * 120 - 10)
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color.WHITE)
		root.add_child(label)
		label.owner = root

		for role_idx in range(roles.size()):
			var role = roles[role_idx]
			var sprite = Sprite2D.new()
			sprite.name = "Agent_%s_%s" % [role, dir]
			sprite.texture = load("res://assets/sprites/agents/%s/%s_%s.png" % [role, role, dir])
			sprite.position = Vector2(x_start + role_idx * 140 + 100, y_offset + dir_idx * 120 + 30)
			sprite.scale = Vector2(0.1875, 0.1875)  # 256 * 0.1875 = 48px
			root.add_child(sprite)
			sprite.owner = root

	y_offset += 380

	# Stations row
	var station_label = Label.new()
	station_label.name = "Label_Stations"
	station_label.text = "Stations"
	station_label.position = Vector2(x_start - 60, y_offset - 10)
	station_label.add_theme_font_size_override("font_size", 14)
	station_label.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(station_label)
	station_label.owner = root

	for st_idx in range(station_types.size()):
		var st = station_types[st_idx]
		var sprite = Sprite2D.new()
		sprite.name = "Station_%s" % st
		sprite.texture = load("res://assets/sprites/stations/%s.png" % st)
		sprite.position = Vector2(x_start + st_idx * 140 + 100, y_offset + 40)
		sprite.scale = Vector2(0.25, 0.25)  # 256 * 0.25 = 64px
		root.add_child(sprite)
		sprite.owner = root

	y_offset += 120

	# Packets row
	var packet_label = Label.new()
	packet_label.name = "Label_Packets"
	packet_label.text = "Job Packets"
	packet_label.position = Vector2(x_start - 60, y_offset - 10)
	packet_label.add_theme_font_size_override("font_size", 14)
	packet_label.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(packet_label)
	packet_label.owner = root

	for p_idx in range(packet_priorities.size()):
		var p = packet_priorities[p_idx]
		var sprite = Sprite2D.new()
		sprite.name = "Packet_%s" % p
		sprite.texture = load("res://assets/sprites/packets/packet_%s.png" % p)
		sprite.position = Vector2(x_start + p_idx * 100 + 100, y_offset + 30)
		sprite.scale = Vector2(0.0625, 0.0625)  # 256 * 0.0625 = 16px
		root.add_child(sprite)
		sprite.owner = root

	# Save scene
	var scene = PackedScene.new()
	scene.pack(root)
	ResourceSaver.save(scene, "res://scenes/sprite_preview.tscn")
	print("Sprite preview scene saved to res://scenes/sprite_preview.tscn")
