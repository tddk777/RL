extends Node3D
## Renders each weapon in first person (hip, aimed) in a neutral lit room.
##   godot --rendering-driver vulkan res://dev/tests/viewmodel_preview.tscn -- <out_dir>

var _out := ""


func _ready() -> void:
	Engine.max_physics_steps_per_frame = 200  # keep game time = real time at low fps
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://"
	_build_room()
	_run.call_deferred()


func _build_room() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.33, 0.35)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.56, 0.6)
	env.environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.6
	add_child(sun)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(40, 1, 40)
	bm.material = load("res://assets/materials/concrete_floor.tres")
	mesh.mesh = bm
	mesh.position.y = -0.5
	floor_body.add_child(mesh)
	add_child(floor_body)
	var target := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(1, 1.8, 0.1)
	tm.material = load("res://assets/materials/painted_steel_yellow.tres")
	target.mesh = tm
	target.position = Vector3(0, 1.6, -10)
	add_child(target)


func _run() -> void:
	UI.fade_in(0.01)
	var player: Player = load("res://player/player.tscn").instantiate()
	add_child(player)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().create_timer(1.5).timeout
	for i in ([2] if OS.get_cmdline_user_args().has("--mp5-only") else range(player.weapons.size())):
		player.equip(i)
		await get_tree().create_timer(1.2).timeout
		var id := String(player.current_weapon.data.id)
		await _shot("vm_%s_hip.png" % id)
		Input.action_press(&"aim")
		await get_tree().create_timer(1.2).timeout
		await _shot("vm_%s_ads.png" % id)
		Input.action_release(&"aim")
		await get_tree().create_timer(0.6).timeout
		if i == 0:
			player.current_weapon.reload()
			await get_tree().create_timer(player.current_weapon.data.reload_time * 0.45).timeout
			await _shot("vm_%s_reload.png" % id)
			await get_tree().create_timer(2.0).timeout
	# The rival, up close
	player.equip(0)
	var data: EnemyData = Registry.enemy(&"scavenger")
	var npc: NPC = data.scene.instantiate()
	npc.data = data
	add_child(npc)
	npc.global_position = Vector3(0.35, 0.0, -1.7)
	npc.rotation_degrees.y = 160.0
	npc.set_physics_process(false)
	npc.perception.set_physics_process(false)
	player.holder.visible = false
	player.set(&"_pitch", deg_to_rad(-12.0))
	await get_tree().create_timer(1.0).timeout
	await _shot("vm_npc_low_ready.png")
	npc.body.set_aim(player.head.global_position, true)
	await get_tree().create_timer(1.0).timeout
	await _shot("vm_npc_aiming.png")
	get_tree().quit()


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(file))
