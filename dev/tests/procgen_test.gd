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
	ProceduralLevel.record_placements = true
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
	# Nothing floor-standing hangs in the air: from each prop's base, the
	# surface under it must be right there (hung things, found on walls with
	# nothing under them in reach, are skipped).
	var prop_space := level.get_world_3d().direct_space_state
	# Resting: a surface right under the base (front faces only, so a prop's
	# own collider doesn't count), or the top of another prop it is stacked on.
	var tops: Array = []  # [AABB of each sized placement]
	for rec: Array in level.placements:
		var pid: String = rec[0]
		var pxf: Transform3D = rec[1]
		var box := AABB()
		if level.builder.models.has(pid):
			box = level.builder.models.bounds[pid]
		elif ChunkBuilder.FOOTPRINTS.has(pid):
			var fp: Array = ChunkBuilder.FOOTPRINTS[pid]
			box = AABB(Vector3(0, float(fp[1]), 0) - (fp[0] as Vector3) * 0.5, fp[0])
		else:
			continue
		tops.append(pxf * box)
	var supported := func(base: Vector3) -> bool:
		# From a little above: shelf colliders are voxel boxes whose tops sit
		# up to a voxel (6-9 cm) over the surface drawn.
		for from_h: float in [0.05, 0.16]:
			var q := PhysicsRayQueryParameters3D.create(base + Vector3.UP * from_h, base + Vector3.DOWN * 0.08, Layers.WORLD | Layers.CLIP)
			q.hit_back_faces = false
			q.hit_from_inside = false
			var hit := prop_space.intersect_ray(q)
			if not hit.is_empty() and (hit.position as Vector3).y < base.y + 0.1:
				return true
		for t: AABB in tops:
			var top := t.end.y
			if absf(top - base.y) < 0.09 and base.x > t.position.x and base.x < t.end.x and base.z > t.position.z and base.z < t.end.z:
				return true
		return false
	var floating := {}
	var float_where: Array = []
	for rec: Array in level.placements:
		var id: String = rec[0]
		if ModelProps.MODELS.has(id) and ModelProps.MODELS[id].get("origin", &"base") != &"base":
			continue
		if id in ChunkBuilder.NODE_PROPS:
			continue  # lamps hang off walls and pillars
		var xf: Transform3D = rec[1]
		if not rec[2]:
			continue  # stacked dressing (pallets on pallets) has no collider of its own
		if xf.basis.y.dot(Vector3.UP) < 0.9:
			continue  # toppled / leaning things rest on an edge
		var base := xf.origin
		if supported.call(base):
			continue
		var hit := prop_space.intersect_ray(PhysicsRayQueryParameters3D.create(base, base + Vector3.DOWN * 0.8, Layers.WORLD | Layers.CLIP))
		if hit:  # (nothing in reach below: hung on a wall)
			floating[id] = floating.get(id, 0) + 1
			if float_where.size() < 12:
				float_where.append("%s %s gap %.2f" % [id, base.snapped(Vector3.ONE * 0.1), base.y - (hit.position as Vector3).y])
	var n_float: int = floating.values().reduce(func(a: int, b: int) -> int: return a + b, 0) if not floating.is_empty() else 0
	print("INFO  floating props by kind: %s" % [floating])
	for w: String in float_where:
		print("INFO    ", w)
	check(n_float <= 4, "floor props rest on something (%d of %d float)" % [n_float, level.placements.size()])
	# Pickups mostly on shelves, benches and desks, and resting on them.
	var on_surface := 0
	var resting := 0
	for rec: Dictionary in L.pickups:
		if rec.get("on_surface", false):
			on_surface += 1
			if supported.call(rec["position"] as Vector3):
				resting += 1
			else:
				print("INFO  pickup not resting at %s" % [(rec["position"] as Vector3).snapped(Vector3.ONE * 0.01)])
	print("INFO  pickups on surfaces: %d of %d (%d loot spots)" % [on_surface, L.pickups.size(), level.loot_spots.size()])
	check(on_surface >= L.pickups.size() / 3, "most pickups lie on shelves, benches or desks (%d of %d)" % [on_surface, L.pickups.size()])
	check(resting == on_surface, "and rest on them (%d of %d)" % [resting, on_surface])
	# Doors: most doorways empty or with a broken door, some working ones.
	var working := level.find_children("*", "Door", true, false)
	print("INFO  working doors: %d" % working.size())
	check(working.size() > 0, "some doors still work (%d)" % working.size())
	if not working.is_empty():
		var door := working[0] as Door
		var was := door.is_open()
		door.toggle(level.get_node_or_null("Player") as Node3D)
		await wait(1.2)
		check(door.is_open() != was, "a door opens and closes")
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
				var st := level.builder.stair_at(x, z, s)
				var bottom := st.p(st.foot - 0.6, st.inner_lo + st.lane * 0.5, 0.45)
				var landing := st.p(st.foot - 0.7, st.wall_lo + st.lane * 0.5, st.h + 0.45)
				var from := NavigationServer3D.map_get_closest_point(map, bottom + Vector3.UP * 0.3)
				var to := NavigationServer3D.map_get_closest_point(map, landing + Vector3.UP * 0.3)
				var path := nav_path(map, from, to)
				var ok := path.size() >= 2 and path[path.size() - 1].distance_to(to) < 0.5 and to.distance_to(landing) < 1.5 \
					and from.distance_to(bottom) < 1.0
				if ok:
					walkable += 1
				else:
					bad.append(Vector3i(x, z, s))
					print("INFO  stair %s dir %d side %d %s: foot snap %.2f, arrival snap %.2f, path ends %.2f from it (%d points)" % [
						Vector3i(x, z, s), L.stair_dir(x, z, s), L.stair_side(x, z, s), "steel" if st.steel else "concrete",
						from.distance_to(bottom), to.distance_to(landing), path[path.size() - 1].distance_to(to) if path.size() > 0 else -1.0, path.size()])
	print("INFO  unwalkable stairs: %s" % [bad])
	check(stairs > 0 and walkable >= stairs * 0.9, "stairs walkable on the navmesh (%d of %d)" % [walkable, stairs])

	# Enemies and loot stand on walkable ground, not inside machines.
	var inside := 0
	for e: Dictionary in L.enemies + L.pickups:
		if e.get("on_surface", false):
			continue  # on a shelf or bench, checked below
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

	# Split rooms: the back room is reachable through the partition's doorway.
	var splits := 0
	var shut: Array = []
	for s: int in L.all_storeys():
		for z in L.size.y:
			for x in L.size.x:
				if not L.has_split(x, z, s) or L.distance[L.idx(x, z, s)] < 0:
					continue
				splits += 1
				var psp := level.builder.split_span(L.cell_origin(x, z, s), L.split_side(x, z, s))
				var door := L.split_door(x, z, s)
				var want := psp.origin + psp.u * ((door.x + door.y) * 0.5) - psp.m * 1.0
				var q := NavigationServer3D.map_get_closest_point(map, want + Vector3.UP * 0.3)
				var path := nav_path(map, start, q)
				if q.distance_to(want) > 0.8 or path.size() < 2 or path[path.size() - 1].distance_to(q) > 0.5:
					shut.append(Vector3i(x, z, s))
	if not shut.is_empty():
		print("INFO  back rooms cut off: %s" % [shut])
	check(shut.is_empty(), "back rooms of split rooms reachable (%d of %d)" % [splits - shut.size(), splits])

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
				# Each switchback: up the first flight onto the half landing, up the
				# second onto the floor above; then back down both.
				var st := level.builder.stair_at(x, z, s)
				var half := st.h * 0.5
				var base_y := st.origin.y
				var along := func() -> float: return (player.global_position - st.origin).dot(st.a)
				var i_mid := st.inner_lo + st.lane * 0.5
				var w_mid := st.wall_lo + st.lane * 0.5
				var up1: bool = await _walk(player, st.p(st.foot - 0.5, i_mid, 0.0), st.a,
					func() -> bool: return player.global_position.y > base_y + half - 0.2 and along.call() > st.turn + 0.3)
				var up2: bool = up1 and await _walk(player, st.p(st.turn + 0.6, w_mid, half), -st.a,
					func() -> bool: return player.global_position.y > base_y + st.h - 0.2 and along.call() < st.foot - 0.3)
				if up2:
					climbed += 1
				else:
					print("INFO  stuck going up the stair at %s (%s, now %s)" % [Vector3i(x, z, s), "first flight" if not up1 else "second flight", player.global_position])
				var down1: bool = await _walk(player, st.p(st.foot - 0.7, w_mid, st.h), st.a,
					func() -> bool: return player.global_position.y < base_y + half + 0.2 and along.call() > st.turn + 0.3)
				var down2: bool = down1 and await _walk(player, st.p(st.turn + 0.6, i_mid, half), -st.a,
					func() -> bool: return player.global_position.y < base_y + 0.2 and along.call() < st.foot - 0.3)
				if down2:
					descended += 1
				else:
					print("INFO  stuck going down the stair at %s (%s, now %s)" % [Vector3i(x, z, s), "second flight" if not down1 else "first flight", player.global_position])
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
					var from := c + out * (half + (f["n"] as int) * 0.3 + 0.5)
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
	var want_guns := level.profile.weapon_pickups.size() if level.profile.weapon_pickup_count <= 0 \
		else mini(level.profile.weapon_pickups.size(), level.profile.weapon_pickup_count)
	check(weapons == want_guns and pickups >= 14, "pickups placed (%d, %d weapons)" % [pickups, weapons])
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
