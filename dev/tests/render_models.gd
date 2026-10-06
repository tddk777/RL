extends SceneTree
## Renders model scenes side by side to PNG for visual review.
##   godot --path . --script res://dev/tests/render_models.gd -- <out.png> <scene> [scene...]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0]
	var ui := root.get_node_or_null(^"UI")
	if ui:
		ui.visible = false  # hide the fade overlay
	var scenes := args.slice(1)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.16, 0.16, 0.17)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.52)
	env.environment.ambient_light_energy = 0.6
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var key := DirectionalLight3D.new()
	root.add_child(key)
	key.rotation_degrees = Vector3(-35, 40, 0)
	key.light_energy = 1.4
	var rim := DirectionalLight3D.new()
	root.add_child(rim)
	rim.rotation_degrees = Vector3(-20, -140, 0)
	rim.light_energy = 0.6
	var spacing := 0.32
	for i in scenes.size():
		var inst: Node3D = (load(scenes[i]) as PackedScene).instantiate()
		root.add_child(inst)
		inst.position = Vector3(0, -i * spacing, 0)
		inst.rotation_degrees = Vector3(0, 90, 0)  # barrel points -X... side view from +Z shows right side
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.fov = 30
	var center := Vector3(-0.2, -(scenes.size() - 1) * spacing * 0.5, 0)
	cam.look_at_from_position(center + Vector3(0.0, 0.05, 2.2 + scenes.size() * 0.45), center)
	for i in 8:
		await process_frame
	root.get_texture().get_image().save_png(out)
	quit()
