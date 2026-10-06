extends Node
## Renders a tour of a generated Level 1: one screenshot per kind of space.
##   godot --rendering-driver vulkan --path . res://dev/tests/procgen_tour.tscn -- <out_dir> [seed]

var _out := ""


func _ready() -> void:
	Engine.max_physics_steps_per_frame = 200
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://"
	if args.size() > 1:
		seed(int(args[1]))
	_run.call_deferred()


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(file))
	print("shot ", file)


func _run() -> void:
	Game.start_run()
	while Game.state != Game.State.PLAYING:
		await wait(0.5)
	var tf := 0.0
	while (UI.get_node("Fade").color.a > 0.01 or UI.get_node("TitleCard").modulate.a > 0.01) and tf < 300.0:
		await wait(0.5)
		tf += 0.5
	await wait(2.0)
	var level := Game.level as ProceduralLevel
	var L := level.layout
	var player := Game.player
	player.health.max_health = 1e9
	player.health.current = 1e9
	for npc in get_tree().get_nodes_in_group(&"npc"):
		npc.queue_free()
	await shot("t00_spawn.png")
	var picks := {}
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				var k := L.kind_at(x, z, s)
				var zn := L.zone_of(x, z, s)
				if zn == null:
					continue
				var key := ""
				if k == LevelLayout.Kind.FLOOR and L.has_flag(x, z, s, LevelLayout.STAIR):
					key = "stairs_%s" % zn.type
				elif k == LevelLayout.Kind.CATWALK:
					key = "catwalk"
				elif k == LevelLayout.Kind.FLOOR and L.kind_at(x, z, s + 1) == LevelLayout.Kind.HOLE:
					key = "collapse"
				elif k == LevelLayout.Kind.FLOOR:
					key = "%s_%d" % [zn.type, mini(s, 1)]
				if key != "" and not picks.has(key) and L.distance[L.idx(x, z, s)] > 0 and (x + z) % 3 == 0:
					picks[key] = Vector3i(x, z, s)
	for a in L.anomalies:
		picks["anomaly_%s" % a["kind"]] = a["cell"]
	picks["exit"] = L.exits[0]["cell"]
	var i := 1
	for key: String in picks:
		var c: Vector3i = picks[key]
		var center := L.cell_center(c.x, c.y, c.z)
		# Stand at the cell edge looking across it (and into the next cell).
		var best_dir := 0
		for d in 4:
			if not L.has_wall(c.x, c.y, c.z, d):
				best_dir = d
		var back := -LevelLayout.dir_vector(best_dir)
		var pos := center + back * 3.0 + Vector3.UP * 0.1
		if key.begins_with("anomaly") or key == "exit":
			# Face the thing on its wall from a few metres back.
			var rec: Dictionary = L.exits[0] if key == "exit" else L.anomalies.filter(func(a: Dictionary) -> bool: return a["cell"] == c).front()
			var v := LevelLayout.dir_vector(rec["dir"])
			var at: Vector3 = rec["position"]
			pos = Vector3(at.x, center.y, at.z) - v * (3.5 if key != "anomaly_odd_corpse" else 2.0) + Vector3.UP * 0.1
			back = -v
		player.global_position = pos
		player.velocity = Vector3.ZERO
		var t := 0.0
		while (not level.loaded_chunks().has(level.builder.chunk_of(pos)) or not level._jobs.is_empty()) and t < 120.0:
			await wait(0.5)
			t += 0.5
		await wait(1.5)
		player.global_position = pos
		player.velocity = Vector3.ZERO
		var look := -back
		player.rotation.y = atan2(-look.x, -look.z)
		var pitch := 18.0 if key == "catwalk" or key.begins_with("hall") or key.begins_with("warehouse") else -6.0
		if key == "anomaly_odd_corpse" or key == "anomaly_odd_container":
			pitch = -22.0
		player.set(&"_pitch", deg_to_rad(pitch))
		await wait(2.0)
		await shot("t%02d_%s.png" % [i, key])
		i += 1
	get_tree().quit()
