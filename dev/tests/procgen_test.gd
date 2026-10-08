extends Node
## Procedural Level 1 test: generation, building, navigation, stairs, entities.
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


## Path query without the default 4096-polygon search limit (the whole
## level is one navigation mesh of ~10k polygons).
func nav_path(map: RID, a: Vector3, b: Vector3) -> PackedVector3Array:
	var q := NavigationPathQueryParameters3D.new()
	q.map = map
	q.start_position = a
	q.target_position = b
	q.path_search_max_polygons = 0
	var res := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(q, res)
	return res.path


func stats(a: Array) -> String:
	if a.is_empty():
		return "-"
	var total := 0.0
	for v in a:
		total += v
	return "avg %.0f ms, max %.0f ms, total %.0f ms over %d" % [total / a.size(), a.max(), total, a.size()]


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	seed(int(args[1]) if args.size() > 1 else 7)
	Game.start_run()
	while Game.state != Game.State.PLAYING and Time.get_ticks_msec() - t0 < 180000:
		await wait(0.25)
	var load_s := (Time.get_ticks_msec() - t0) / 1000.0
	check(Game.state == Game.State.PLAYING, "procedural level builds and play starts (%.1fs)" % load_s)
	var level := Game.level as ProceduralLevel
	check(level != null, "level is a ProceduralLevel")
	if level == null:
		get_tree().quit(1)
		return
	var L := level.layout
	var count := level.builder.chunk_count()
	print("INFO  seed %d, %dx%d cells (%.0f m), exits %s" % [level.level_seed, L.size.x, L.size.y, L.size.x * L.cell,
		L.exits.map(func(e: Dictionary) -> String: return String(e.kind))])
	print("INFO  chunk builds (worker threads): %s" % stats(level.build_ms))
	print("INFO  chunk instantiation (main thread): %s" % stats(level.instantiate_ms))
	check(level.loaded_chunks().size() == count.x * count.y, "every chunk built (%d)" % level.loaded_chunks().size())
	var meshes := level.find_children("*", "MeshInstance3D", true, false).size()
	var lights := level.find_children("*", "Light3D", true, false).size()
	var decals := level.find_children("*", "Decal", true, false).size()
	var bodies := level.find_children("*", "StaticBody3D", true, false).size()
	print("INFO  nodes: %d mesh instances, %d lights, %d decals, %d static bodies" % [meshes, lights, decals, bodies])
	# Scanned props (ModelProps): drawn as MultiMeshes named after the model.
	var kinds := {}
	var placed := 0
	for mmi in level.find_children("*", "MultiMeshInstance3D", true, false):
		var n := (mmi as MultiMeshInstance3D).multimesh.instance_count
		kinds[String(mmi.name).get_slice("@", 0)] = kinds.get(String(mmi.name).get_slice("@", 0), 0) + n
		placed += n
	print("INFO  scanned props: %s" % [kinds])
	check(level.builder.models.meshes.size() == ModelProps.MODELS.size(), "every scanned model loads (%d of %d)" % [
		level.builder.models.meshes.size(), ModelProps.MODELS.size()])
	check(kinds.size() >= 12 and placed >= 100, "scanned props placed (%d of %d kinds, %d in all)" % [kinds.size(),
		ModelProps.MODELS.size(), placed])
	var player := Game.player
	check(player.weapons.size() == 1 and player.current_weapon.data.id == &"m1911", "player starts with only the M1911")
	check(player.current_weapon.loaded_rounds() == 8 and player.count_ammo(&".45ACP") == 7, "M1911 has 7+1 loaded and one spare magazine")
	var spawn_y := player.global_position.y
	await wait(2.0)
	check(player.is_on_floor() and absf(player.global_position.y - spawn_y) < 0.6, "player stands on the generated floor (y %.2f)" % player.global_position.y)
	var nav := level.get_node_or_null(^"Navigation") as NavigationRegion3D
	check(nav != null and nav.navigation_mesh.get_polygon_count() > 1000, "one navigation mesh for the level (%d polygons, baked in %.0f ms)" % [
		nav.navigation_mesh.get_polygon_count() if nav else 0, level.nav_bake_ms])
	var map := player.get_world_3d().navigation_map

	# Stairs: every flight must be walkable on the navmesh, bottom to landing.
	var stairs := 0
	var walkable := 0
	var bad: Array = []
	for s: int in L.all_storeys():
		for z in L.size.y:
			for x in L.size.x:
				if not L.has_flag(x, z, s, LevelLayout.STAIR) or L.distance[L.idx(x, z, s)] < 0:
					continue
				stairs += 1
				var rr := level.builder.run_rect(L.stair_dir(x, z, s), L.stair_side(x, z, s))
				var o := L.cell_origin(x, z, s)
				var a := LevelLayout.dir_vector(L.stair_dir(x, z, s))
				var mid := o + Vector3(rr.position.x + rr.size.x * 0.5, 0, rr.position.y + rr.size.y * 0.5)
				var bottom := mid - a * (LevelLayout.RUN * 0.5 - 0.6) + Vector3.UP * 0.45
				var landing := mid + a * (LevelLayout.RUN * 0.5 + 0.9) + Vector3.UP * L.storey_height
				var from := NavigationServer3D.map_get_closest_point(map, bottom + Vector3.UP * 0.3)
				var to := NavigationServer3D.map_get_closest_point(map, landing + Vector3.UP * 0.3)
				var path := nav_path(map, from, to)
				var ok := path.size() >= 2 and path[path.size() - 1].distance_to(to) < 0.5 and to.distance_to(landing) < 1.5 \
					and from.distance_to(bottom) < 1.0
				if ok:
					walkable += 1
				else:
					bad.append(Vector3i(x, z, s))
	print("INFO  unwalkable stairs: %s" % [bad])
	check(stairs > 0 and walkable >= stairs * 0.9, "stairs walkable on the navmesh (%d of %d)" % [walkable, stairs])

	# Enemies and loot stand on walkable ground, not inside machines.
	var inside := 0
	for e: Dictionary in L.enemies + L.pickups:
		var p: Vector3 = e["position"]
		var q := NavigationServer3D.map_get_closest_point(map, p)
		if q.distance_to(p) > 0.8:
			inside += 1
			var c := L.world_to_cell(p)
			print("INFO  off the navmesh: %s at %s in %s (nearest walkable %.1f m)" % [e.get("id", e.get("kind")), c, L.zone_name(c.x, c.z, c.y), q.distance_to(p)])
	check(inside <= 1, "enemies and pickups on walkable ground (%d off)" % inside)
	check(L.enemies.size() == 8 and get_tree().get_nodes_in_group(&"npc").size() == 8, "8 scavengers spawned")

	# Furniture never cuts the level apart: both sides of every door are
	# reachable from the spawn on the navmesh.
	var start := NavigationServer3D.map_get_closest_point(map, L.spawn_position)
	var doors := 0
	var blocked: Array = []
	for s: int in L.all_storeys():
		for z in L.size.y:
			for x in L.size.x:
				if L.distance[L.idx(x, z, s)] < 0:
					continue
				for d in [1, 2]:
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					if not L.has_door(x, z, s, d) or not L.is_walkable(x, z, s) or not L.is_walkable(n.x, n.y, s):
						continue
					doors += 1
					var edge := L.cell_center(x, z, s) + LevelLayout.dir_vector(d) * (L.cell * 0.5)
					for side: float in [-1.0, 1.0]:
						var want := edge + LevelLayout.dir_vector(d) * (side * 1.0)
						var q := NavigationServer3D.map_get_closest_point(map, want + Vector3.UP * 0.3)
						var path := nav_path(map, start, q)
						if q.distance_to(want) > 1.2 or path.size() < 2 or path[path.size() - 1].distance_to(q) > 0.5:
							var c := Vector3i(x, z, s) + (Vector3i(LevelLayout.DIRS[d].x, LevelLayout.DIRS[d].y, 0) if side > 0.0 else Vector3i.ZERO)
							var rm := L.room_of(c.x, c.y, c.z)
							blocked.append("%s side of door %s/%d in %s/%s (snap %.1f m off)" % [c, Vector3i(x, z, s), d, L.zone_name(c.x, c.y, c.z),
								rm.use if rm else &"-", q.distance_to(want)])
							break
	if not blocked.is_empty():
		for b in blocked:
			print("INFO  door cut off: %s" % b)
	check(blocked.size() <= doors / 100, "both sides of every door reachable (%d doors, %d cut off)" % [doors, blocked.size()])

	# Every exit is reachable by navigation from the spawn (to the clear lane in front of its door).
	var exit_rec: Dictionary = L.exits[0]
	var exit_cell: Vector3i = exit_rec["cell"]
	var reached := 0
	var longest := 0.0
	for e: Dictionary in L.exits:
		var front: Vector3 = e["position"] - LevelLayout.dir_vector(e["dir"]) * 1.4
		var far := NavigationServer3D.map_get_closest_point(map, front + Vector3.UP * 0.3)
		var path := nav_path(map, L.spawn_position, far)
		var length := 0.0
		for i in range(1, path.size()):
			length += path[i - 1].distance_to(path[i])
		if path.size() >= 2 and path[path.size() - 1].distance_to(far) < 1.0 and far.distance_to(front) < 1.5:
			reached += 1
			longest = maxf(longest, length)
		else:
			print("INFO  exit %s not reached: path ends %s, target %s" % [e["cell"], path[path.size() - 1] if path.size() > 0 else Vector3.ZERO, far])
	check(reached == L.exits.size(), "navmesh paths from the spawn to every exit (%d of %d, longest %.0f m)" % [reached, L.exits.size(), longest])

	# Teleport around, including upper storeys: always lands on a floor.
	var stops: Array[Vector3] = []
	for s: int in L.all_storeys():
		var found := 0
		for z in L.size.y:
			for x in L.size.x:
				if found >= 2 or L.distance[L.idx(x, z, s)] < 0 or L.kind_at(x, z, s) != LevelLayout.Kind.FLOOR:
					continue
				for d in 4:
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					if found < 2 and L.has_door(x, z, s, d) and L.is_walkable(n.x, n.y, s) and (x * 7 + z * 3) % 5 == 0:
						var want := L.cell_center(x, z, s) + LevelLayout.dir_vector(d) * (L.cell * 0.5 - 1.2)
						stops.append(NavigationServer3D.map_get_closest_point(map, want + Vector3.UP * 0.3))
						found += 1
	var landed := 0
	for p in stops:
		player.global_position = p + Vector3.UP * 0.2
		player.velocity = Vector3.ZERO
		for f in 90:
			await get_tree().physics_frame
		# Not falling through (it may land on a corpse or a scavenger standing there).
		if absf(player.global_position.y - p.y) < 0.8 and player.velocity.y > -2.0:
			landed += 1
		else:
			print("INFO  did not land at %s (now %s, on floor %s)" % [p, player.global_position, player.is_on_floor()])
	check(landed == stops.size(), "floors hold the player on every storey (%d of %d)" % [landed, stops.size()])

	# No holes: rays straight down across every reachable floor and catwalk
	# strip find something to stand on at floor height.
	var space := player.get_world_3d().direct_space_state
	var holes: Array = []
	var probes := 0
	for s: int in L.all_storeys():
		for z in L.size.y:
			for x in L.size.x:
				if L.distance[L.idx(x, z, s)] < 0:
					continue
				var k := L.kind_at(x, z, s)
				var pts: Array[Vector2] = []
				if k == LevelLayout.Kind.FLOOR:
					var rects: Array[Rect2] = [Rect2(0.5, 0.5, L.cell - 1.0, L.cell - 1.0)]
					if L.zone_of(x, z, s).type == &"connector" or L.has_flag(x, z, s, LevelLayout.NARROW):
						rects.assign(level.builder.narrow_open(x, z, s, L.style_at(x, z, s)))
					for r in rects:
						for i in 3:
							for j in 3:
								pts.append(r.position + r.size * Vector2((i + 0.5) / 3.0, (j + 0.5) / 3.0))
				elif k == LevelLayout.Kind.CATWALK:
					var sides := (L.flags_at(x, z, s) >> 4) & 15
					for side in 4:
						if sides & (1 << side):
							var r := level.builder.strip(side, LevelLayout.STRIP)
							for i in 5:
								var f := (i + 0.5) / 5.0
								pts.append(r.position + r.size * (Vector2(f, 0.5) if r.size.x > r.size.y else Vector2(0.5, f)))
				var hole := Rect2()
				if L.has_flag(x, z, s, LevelLayout.STAIR_ABOVE):
					hole = level.builder.run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s)).grow(0.3)
				var feat := level.builder.level_feature(x, z, s)
				if not feat.is_empty() and feat["kind"] == &"pit":
					hole = feat["rect"]  # its floor is lower: walked below
				var drop := level.builder.drop_rect(x, z, s).grow(0.3) if L.has_drop(x, z, s) else Rect2()
				var o := L.cell_origin(x, z, s)
				for p in pts:
					if hole.has_point(p) or drop.has_point(p):
						continue
					probes += 1
					var from := o + Vector3(p.x, 1.2, p.y)
					var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 1.6, Layers.WORLD)
					var hit := space.intersect_ray(q)
					if hit.is_empty() or hit["position"].y < o.y - 0.12:
						holes.append(Vector3i(x, z, s))
						if holes.size() <= 12:
							print("INFO  nothing to stand on at %s in %s %s (cell %s)" % [o + Vector3(p.x, 0, p.y), L.zone_name(x, z, s),
								LevelLayout.Kind.keys()[k], Vector3i(x, z, s)])
	check(holes.is_empty(), "solid footing across every floor and catwalk (%d probes, %d holes)" % [probes, holes.size()])

	# Walk up and down flights: the player must get onto the landing and back
	# off the bottom step (no lip at the top, no snag at the foot).
	player.health.max_health = 1e9
	player.health.current = 1e9
	for npc in get_tree().get_nodes_in_group(&"npc"):
		npc.process_mode = Node.PROCESS_MODE_DISABLED
	var flights := 0
	var climbed := 0
	var descended := 0
	for s: int in L.all_storeys():
		for z in L.size.y:
			for x in L.size.x:
				if flights >= 5 or not L.has_flag(x, z, s, LevelLayout.STAIR) or L.distance[L.idx(x, z, s)] < 0:
					continue
				flights += 1
				var rr := level.builder.run_rect(L.stair_dir(x, z, s), L.stair_side(x, z, s))
				var o := L.cell_origin(x, z, s)
				var a := LevelLayout.dir_vector(L.stair_dir(x, z, s))
				var mid := o + Vector3(rr.position.x + rr.size.x * 0.5, 0, rr.position.y + rr.size.y * 0.5)
				if await _walk(player, mid - a * (LevelLayout.RUN * 0.5 + 0.5), a,
						func() -> bool: return player.global_position.y > o.y + L.storey_height - 0.2 and (player.global_position - mid).dot(a) > LevelLayout.RUN * 0.5):
					climbed += 1
				else:
					print("INFO  stuck going up the flight at %s (now %s)" % [Vector3i(x, z, s), player.global_position])
				if await _walk(player, mid + a * (LevelLayout.RUN * 0.5 + 0.8) + Vector3.UP * L.storey_height, -a,
						func() -> bool: return player.global_position.y < o.y + 0.2 and (player.global_position - mid).dot(a) < -LevelLayout.RUN * 0.5):
					descended += 1
				else:
					print("INFO  stuck going down the flight at %s (now %s)" % [Vector3i(x, z, s), player.global_position])
	check(flights > 0 and climbed == flights and descended == flights, "player walks up and down flights (%d of %d up, %d down)" % [climbed, flights, descended])

	# Drop-downs: through the hole onto the heap in the room below.
	var drops := 0
	var dropped := 0
	for s in range(1, L.storeys):
		for z in L.size.y:
			for x in L.size.x:
				if not L.has_drop(x, z, s):
					continue
				drops += 1
				var hr := level.builder.drop_rect(x, z, s)
				var top := L.cell_origin(x, z, s) + Vector3(hr.get_center().x, 0.3, hr.get_center().y)
				player.global_position = top
				player.velocity = Vector3.ZERO
				await wait(2.0)
				if player.global_position.y < top.y - 3.0 and player.global_position.y > top.y - L.storey_height - 0.5 and player.is_on_floor():
					dropped += 1
				else:
					print("INFO  drop at %s: ended at %s" % [Vector3i(x, z, s), player.global_position])
	print("INFO  %d drop-downs" % drops)
	check(drops > 0 and dropped == drops, "drop-downs land on the storey below (%d of %d)" % [dropped, drops])

	# Platforms and pits: up the steps onto a platform, up out of a pit.
	var feats := {&"podium": 0, &"pit": 0}
	var walked := {&"podium": 0, &"pit": 0}
	var tried := {&"podium": 0, &"pit": 0}
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				var f := level.builder.level_feature(x, z, s)
				if f.is_empty() or L.distance[L.idx(x, z, s)] < 0:
					continue
				var kind: StringName = f["kind"]
				feats[kind] += 1
				if tried[kind] >= 3:
					continue
				tried[kind] += 1
				var rect: Rect2 = f["rect"]
				var out := LevelLayout.dir_vector(f["side"])
				var c := L.cell_origin(x, z, s) + Vector3(rect.get_center().x, 0, rect.get_center().y)
				var half := (rect.size.y if (f["side"] as int) % 2 == 0 else rect.size.x) * 0.5
				var h: float = f["h"]
				var ok := false
				if kind == &"podium":
					var from := c + out * (half + (f["n"] as int) * LevelLayout.FOOT * 0.0 + (f["n"] as int) * 0.3 + 0.5)
					ok = await _walk(player, from, -out, func() -> bool: return player.global_position.y > c.y + h - 0.1)
				else:
					var from := c - out * 0.2 + Vector3.UP * -h
					ok = await _walk(player, from, out, func() -> bool: return player.global_position.y > c.y - 0.1 and (player.global_position - c).dot(out) > half)
				if ok:
					walked[kind] += 1
				else:
					print("INFO  could not get %s %s at %s (now %s)" % ["onto the platform" if kind == &"podium" else "out of the pit", f["rect"], Vector3i(x, z, s), player.global_position])
	print("INFO  %d platforms, %d pits" % [feats[&"podium"], feats[&"pit"]])
	check(feats[&"podium"] > 0 and walked[&"podium"] == tried[&"podium"] and walked[&"pit"] == tried[&"pit"],
		"steps up onto platforms (%d of %d) and out of pits (%d of %d)" % [walked[&"podium"], tried[&"podium"], walked[&"pit"], tried[&"pit"]])
	for npc in get_tree().get_nodes_in_group(&"npc"):
		npc.process_mode = Node.PROCESS_MODE_INHERIT

	# Exits
	var door: ExitDoor = level.exit_nodes.get(0)
	check(is_instance_valid(door), "exit door placed")
	for i in L.exits.size():
		var e: Dictionary = L.exits[i]
		if e["kind"] == &"locked":
			level._on_lever_pulled(i)
			check(L.exits[i]["unlocked"], "breaker unlocks the locked exit")
	if level.profile.terrain:
		var size := Vector2(L.size) * L.cell
		var ground_space := level.get_world_3d().direct_space_state
		var probe := func(x: float, z: float) -> float:
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, 120, z), Vector3(x, -20, z), Layers.WORLD)
			var hit := ground_space.intersect_ray(q)
			return hit["position"].y if hit else -99.0
		var flat := absf(level.ground_height(size.x * 0.5, size.y * 0.5) + 0.06) < 0.001
		var out: float = probe.call(-150.0, size.y * 0.5)
		var want := level.ground_height(-150.0, size.y * 0.5)
		check(flat and out > 1.0 and absf(out - want) < 0.5,
			"landscape flat under the site, hills outside (%.1f m, collision at %.1f m)" % [want, out])
	var pickups := 0
	var weapons := 0
	for p in L.pickups:
		pickups += 1
		if p["kind"] == &"weapon":
			weapons += 1
	check(weapons == level.profile.weapon_pickups.size() and pickups >= 14, "pickups placed (%d, %d weapons)" % [pickups, weapons])
	var rec: Dictionary = L.pickups[0]
	var pk := Pickup.create(rec)
	level.add_child(pk)
	pk.global_position = player.global_position
	pk.interact(player)
	await wait(0.3)
	check(player.weapons.size() == 2 and rec["taken"], "weapon pickup adds the weapon (%s)" % rec["id"])
	if is_instance_valid(door):
		player.global_position = door.global_position - LevelLayout.dir_vector(exit_rec["dir"]) * 1.2 + Vector3.UP * 0.1
		door.interact(player)
		await wait(1.0)
		check(Game.state == Game.State.FINISHED, "walking through the exit ends the level")
	print("FAILURES: %d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


## Holds forward from `from` facing `dir` until `arrived` or 12 s pass.
func _walk(player: Player, from: Vector3, dir: Vector3, arrived: Callable) -> bool:
	player.global_position = from + Vector3.UP * 0.1
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(-dir.x, -dir.z)
	player.set(&"_pitch", 0.0)
	for f in 10:
		await get_tree().physics_frame
	Input.action_press(&"move_forward")
	var ok := false
	for f in 720:
		await get_tree().physics_frame
		if arrived.call():
			ok = true
			break
	Input.action_release(&"move_forward")
	return ok
