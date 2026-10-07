extends Node
## Renders a tour of a generated Level 1: one screenshot per kind of space
## (zone type and room use), each taken from a doorway looking in.
##   godot --rendering-driver vulkan --path . res://dev/tests/procgen_tour.tscn -- <out_dir> [seed] [limit]

var _out := ""
var _limit := 40


func _ready() -> void:
	Engine.max_physics_steps_per_frame = 200
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://"
	seed(int(args[1]) if args.size() > 1 else 7)
	if args.size() > 2:
		_limit = int(args[2])
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
	var t := 0.0
	while (UI.get_node("Fade").color.a > 0.01 or UI.get_node("TitleCard").modulate.a > 0.01) and t < 300.0:
		await wait(0.5)
		t += 0.5
	await wait(1.0)
	var level := Game.level as ProceduralLevel
	var L := level.layout
	var player := Game.player
	player.health.max_health = 1e9
	player.health.current = 1e9
	for npc in get_tree().get_nodes_in_group(&"npc"):
		npc.queue_free()
	await shot("t00_spawn.png")
	# One view per kind of space: [key, position, look direction, pitch]
	var views: Array = []
	var seen := {}
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if L.kind_at(x, z, s) != LevelLayout.Kind.FLOOR or L.distance[L.idx(x, z, s)] < 2:
					continue
				var zn := L.zone_of(x, z, s)
				var rm := L.room_of(x, z, s)
				var key := String(zn.type)
				if rm and rm.use not in [&"", &"merged"]:
					key = String(rm.use)
				if L.has_flag(x, z, s, LevelLayout.STAIR):
					key = "stairs_" + String(zn.type)
				elif L.has_flag(x, z, s, LevelLayout.NARROW):
					key = "passage_" + String(zn.type)
				if zn.type in ChunkBuilder.TALL and s == 0:
					# Tall spaces: from a west wall, looking down the hall.
					if zn.cols.has(Vector2i(x - 1, z)) or not zn.cols.has(Vector2i(x + 1, z)) or not zn.cols.has(Vector2i(x + 2, z)):
						continue
					key = String(zn.type)
				if seen.has(key):
					continue
				# Stand in a doorway lane (always clear) and look into the cell.
				for d in 4:
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					var open := L.has_door(x, z, s, d) or (L.is_walkable(n.x, n.y, s) and not L.has_wall(x, z, s, d))
					if zn.type in ChunkBuilder.TALL and s == 0:
						open = d == 3
					if not open:
						continue
					var v := LevelLayout.dir_vector(d)
					var pos := L.cell_center(x, z, s) + v * (L.cell * 0.5 - 0.9)
					var pitch := -8.0
					if zn.type in ChunkBuilder.TALL and s == 0:
						pitch = 10.0
					views.append([key, pos, -v, pitch])
					seen[key] = true
					break
	for a in L.anomalies:
		var key := "anomaly_%s" % a["kind"]
		if seen.has(key):
			continue
		seen[key] = true
		var v := LevelLayout.dir_vector(a["dir"])
		var at: Vector3 = a["position"]
		var c: Vector3i = a["cell"]
		var floor_y := L.cell_center(c.x, c.y, c.z).y
		views.append([key, Vector3(at.x, floor_y, at.z) - v * (2.2 if a["kind"] == &"odd_corpse" else 3.2), v, -22.0 if a["kind"] != &"symbol" else 0.0])
	# The odd bits: a platform, a pit, a breach, a vent, a stash.
	var odd := {}
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if L.distance[L.idx(x, z, s)] < 0 and not (L.room_of(x, z, s) and L.room_of(x, z, s).use == &"stash"):
					continue
				var f := level.builder.level_feature(x, z, s)
				if not f.is_empty() and not odd.has(f["kind"]):
					odd[f["kind"]] = true
					var rect: Rect2 = f["rect"]
					var out := LevelLayout.dir_vector(f["side"])
					var c := L.cell_origin(x, z, s) + Vector3(rect.get_center().x, 0, rect.get_center().y)
					var half := (rect.size.y if (f["side"] as int) % 2 == 0 else rect.size.x) * 0.5
					views.append([String(f["kind"]), c + out * (half + 2.6), -out, -14.0 if f["kind"] == &"podium" else -32.0])
				for d in 4:
					var key := "breach" if L.has_breach(x, z, s, d) else ("vent" if L.has_vent(x, z, s, d) else "")
					if key != "" and not odd.has(key) and not L.has_flag(x, z, s, LevelLayout.NARROW):
						odd[key] = true
						var v := LevelLayout.dir_vector(d)
						var g := level.builder.gap_span(x, z, s, d)
						var sp := level.builder.edge_span(L.cell_origin(x, z, s), d)
						var at := sp.origin + sp.u * ((g.x + g.y) * 0.5)
						views.append([key, at - v * 3.2, v, -6.0 if key == "breach" else -18.0])
				var rm := L.room_of(x, z, s)
				if rm and rm.use == &"stash" and not odd.has("stash"):
					odd["stash"] = true
					for d in 4:
						if L.has_vent(x, z, s, d):
							var v := LevelLayout.dir_vector(d)
							views.append(["stash", L.cell_center(x, z, s) + v * (L.cell * 0.5 - 1.6), -v, -12.0])
	# From outside: a hall's windowed facade, a covered walkway, a corner of the complex.
	var outside_views := {}
	for z in L.size.y:
		for x in L.size.x:
			var zn := L.zone_of(x, z, 0)
			if zn == null:
				continue
			var key := ""
			if zn.type in [&"hall", &"foundry", &"warehouse"]:
				key = "outside_hall"
			elif zn.type == &"connector":
				key = "outside_walkway"
			elif zn.type in [&"office", &"maintenance"]:
				key = "outside_block"
			if key == "" or outside_views.has(key):
				continue
			for d in 4:
				var clear := true
				for k in range(1, 4):
					var n := Vector2i(x, z) + LevelLayout.DIRS[d] * k
					if L.is_enclosed(n.x, n.y, 0) or L.is_enclosed(n.x, n.y, 1):
						clear = false
				if not clear:
					continue
				var v := LevelLayout.dir_vector(d)
				var side := LevelLayout.dir_vector((d + 1) % 4)
				views.append([key, L.cell_center(x, z, 0) + v * 18.0 + side * 6.0, (-v * 18.0 - side * 6.0).normalized(), 14.0])
				outside_views[key] = true
				break
	var e: Dictionary = L.exits[0]
	var ev := LevelLayout.dir_vector(e["dir"])
	views.append(["exit_" + String(e["kind"]), (e["position"] as Vector3) - ev * 3.5, ev, -2.0])
	var i := 1
	for view in views:
		if i > _limit:
			break
		var pos: Vector3 = view[1]
		var look: Vector3 = view[2]
		player.global_position = pos + Vector3.UP * 0.1
		player.velocity = Vector3.ZERO
		player.rotation.y = atan2(-look.x, -look.z)
		player.set(&"_pitch", deg_to_rad(view[3]))
		await wait(1.5)
		player.global_position = pos + Vector3.UP * 0.1
		player.velocity = Vector3.ZERO
		await wait(1.0)
		await shot("t%02d_%s.png" % [i, view[0]])
		# The same view by torchlight, now and then.
		if i % 4 == 2 and not String(view[0]).begins_with("outside"):
			player.flashlight.toggle()
			await wait(0.5)
			await shot("t%02d_%s_torch.png" % [i, view[0]])
			player.flashlight.toggle()
		i += 1
	get_tree().quit()
