extends Node
## Procedural Level 1 test: generation, streaming, navigation, entities.
##   godot --headless --path . res://dev/tests/procgen_test.tscn [-- <screenshot_dir>]

var _failures := 0
var _shots := ""


func _ready() -> void:
	Engine.max_physics_steps_per_frame = 32
	var args := OS.get_cmdline_user_args()
	_shots = args[0] if args.size() > 0 else ""
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		_failures += 1


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func shot(file: String) -> void:
	if _shots == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shots.path_join(file))


func regions() -> int:
	var n := 0
	for c in Game.level.get_children():
		if c.get_node_or_null(^"Navigation"):
			n += 1
	return n


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	Game.start_run()
	while Game.state != Game.State.PLAYING and Time.get_ticks_msec() - t0 < 120000:
		await wait(0.25)
	var load_s := (Time.get_ticks_msec() - t0) / 1000.0
	check(Game.state == Game.State.PLAYING, "procedural level loads (%.1fs)" % load_s)
	var level := Game.level as ProceduralLevel
	check(level != null, "level is a ProceduralLevel")
	if level == null:
		get_tree().quit(1)
		return
	var L := level.layout
	print("INFO  seed %d, exits %s" % [level.level_seed, L.exits.map(func(e: Dictionary) -> String: return String(e.kind))])
	check(level.loaded_chunks().size() >= 9, "spawn area chunks loaded (%d)" % level.loaded_chunks().size())
	var player := Game.player
	check(player.weapons.size() == 1 and player.current_weapon.data.id == &"m1911", "player starts with only the M1911")
	check(player.current_weapon.loaded_rounds() == 8 and player.count_ammo(&".45ACP") == 7, "M1911 has 7+1 loaded and one spare magazine")
	var spawn_y := player.global_position.y
	await wait(2.0)
	check(player.is_on_floor() and absf(player.global_position.y - spawn_y) < 0.6, "player stands on the generated floor (y %.2f)" % player.global_position.y)
	var t := 0.0
	while regions() < 4 and t < 30.0:
		await wait(0.5)
		t += 0.5
	check(regions() >= 4, "navigation baked for loaded chunks (%d)" % regions())
	await shot("p01_spawn.png")
	# Path from spawn to a far point within the loaded area.
	var map := player.get_world_3d().navigation_map
	await wait(1.0)
	var target := L.spawn_position + Vector3(20, 0, 20)
	var path := NavigationServer3D.map_get_path(map, L.spawn_position, NavigationServer3D.map_get_closest_point(map, target), true)
	check(path.size() >= 2, "navmesh path across chunk borders (%d points)" % path.size())

	# Stream: walk the player through the complex by teleporting to corridor cells.
	var builder := level.builder
	var times: Array = []
	var far := L.exits[0]["position"] as Vector3
	var stops := [L.spawn_position.lerp(far, 0.33), L.spawn_position.lerp(far, 0.66), far]
	for p: Vector3 in stops:
		var c := L.world_to_cell(p)
		# find a walkable floor cell near the stop
		var best := Vector3i(-1, 0, 0)
		for r in 6:
			for dx in range(-r, r + 1):
				for dz in range(-r, r + 1):
					if best.x < 0 and L.kind_at(c.x + dx, c.z + dz, 0) == LevelLayout.Kind.FLOOR:
						best = Vector3i(c.x + dx, c.z + dz, 0)
		if best.x < 0:
			continue
		var tb := Time.get_ticks_usec()
		var data := builder.build(builder.chunk_of(L.cell_center(best.x, best.y, 0)))
		times.append((Time.get_ticks_usec() - tb) / 1000.0)
		player.global_position = L.cell_center(best.x, best.y, 0) + Vector3.UP * 0.1
		player.velocity = Vector3.ZERO
		var tt := 0.0
		while not level.loaded_chunks().has(builder.chunk_of(player.global_position)) and tt < 20.0:
			await wait(0.25)
			tt += 0.25
		await wait(1.0)
		check(level.loaded_chunks().has(builder.chunk_of(player.global_position)), "chunk under the player streams in (%.1fs)" % tt)
	check(level.loaded_chunks().size() <= 64, "far chunks unloaded (%d loaded)" % level.loaded_chunks().size())
	print("INFO  chunk build times (ms): %s" % [times])
	var inst: Array = level.instantiate_ms
	var avg := 0.0
	for v in inst:
		avg += v
	print("INFO  instantiation jobs on main thread: avg %.1f ms, max %.1f ms over %d jobs" % [avg / maxi(inst.size(), 1), inst.max(), inst.size()])
	await shot("p02_far.png")

	# Exits: an exit near the player, interactable
	var exit_rec: Dictionary = L.exits[0]
	var exit_cell: Vector3i = exit_rec["cell"]
	player.global_position = L.cell_center(exit_cell.x, exit_cell.y, exit_cell.z) + Vector3.UP * 0.1
	await wait(2.5)
	var door: ExitDoor = level.exit_nodes.get(0)
	check(is_instance_valid(door), "exit door spawned with its chunk")
	# Locked exits: the breaker unlocks them
	for i in L.exits.size():
		var e: Dictionary = L.exits[i]
		if e["kind"] == &"locked":
			level._on_lever_pulled(i)
			check(L.exits[i]["unlocked"], "breaker unlocks the locked exit")
	var pickups := 0
	var weapons := 0
	for p in L.pickups:
		pickups += 1
		if p["kind"] == &"weapon":
			weapons += 1
	check(weapons == 4 and pickups >= 30, "pickups placed (%d, %d weapons)" % [pickups, weapons])
	# Take a weapon pickup through the real interaction path
	var rec: Dictionary = L.pickups[0]
	var pk := Pickup.create(rec)
	level.add_child(pk)
	pk.global_position = player.global_position
	pk.interact(player)
	await wait(0.3)
	check(player.weapons.size() == 2 and rec["taken"], "weapon pickup adds the weapon (%s)" % rec["id"])
	if is_instance_valid(door):
		door.interact(player)
		await wait(1.0)
		check(Game.state == Game.State.FINISHED, "walking through the exit ends the level")
	print("FAILURES: %d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
