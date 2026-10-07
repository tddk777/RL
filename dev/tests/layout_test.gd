extends SceneTree
## Generates layouts for several seeds and checks invariants. Prints an ASCII
## map of the ground floor for the first seed.
##   godot --headless --path . --script res://dev/tests/layout_test.gd

func _initialize() -> void:
	var profile: LevelProfile = load("res://levels/l1_industrial/l1_profile.tres")
	var failures := 0
	for seed in [1, 2, 3, 42, 1337, 98765]:
		var t0 := Time.get_ticks_msec()
		var L := LayoutGenerator.generate(profile, seed)
		var ms := Time.get_ticks_msec() - t0
		var walk := 0
		var reach := 0
		for i in L.kind.size():
			if L.kind[i] == LevelLayout.Kind.FLOOR or L.kind[i] == LevelLayout.Kind.CATWALK:
				walk += 1
				if L.distance[i] >= 0:
					reach += 1
		var types := {}
		for z in L.zones:
			types[z.type] = types.get(z.type, 0) + 1
		var stairs := 0
		for f in L.flags:
			if f & LevelLayout.STAIR:
				stairs += 1
		var per_storey := []
		for s in L.storeys:
			var c := 0
			for z in L.size.y:
				for x in L.size.x:
					if L.is_walkable(x, z, s) and L.distance[L.idx(x, z, s)] >= 0:
						c += 1
			per_storey.append(c)
		var exit_kinds := L.exits.map(func(e: Dictionary) -> String: return "%s@%d" % [e.kind, L.distance[L.idx(e.cell.x, e.cell.y, e.cell.z)]])
		print("seed %d: %d ms, zones %s, walkable %d reachable %d per storey %s, stairs %d, max dist %d, exits %s, enemies %d, pickups %d, anomalies %d" % [
			seed, ms, types, walk, reach, per_storey, stairs, L.max_distance, exit_kinds, L.enemies.size(), L.pickups.size(), L.anomalies.size()])
		var ok := L.exits.size() >= 2 and reach > 300 and L.enemies.size() >= 6
		# Maintenance tunnels: reachable, with stairs up into buildings.
		var tunnel := 0
		var tunnel_stairs := 0
		for s: int in range(-L.basement, 0):
			for z in L.size.y:
				for x in L.size.x:
					if L.is_walkable(x, z, s) and L.distance[L.idx(x, z, s)] >= 0:
						tunnel += 1
					if L.has_flag(x, z, s, LevelLayout.STAIR):
						tunnel_stairs += 1
		if L.basement > 0:
			print("  tunnels: %d reachable cells, %d stairs up" % [tunnel, tunnel_stairs])
			if tunnel < 8 or tunnel_stairs < 2:
				ok = false
		# Every flight lands on walkable floor in its own column, and every
		# hole has the flight under it.
		for s: int in L.all_storeys():
			for z in L.size.y:
				for x in L.size.x:
					if L.has_flag(x, z, s, LevelLayout.STAIR):
						if not L.is_walkable(x, z, s + 1) or not L.has_flag(x, z, s + 1, LevelLayout.STAIR_ABOVE) \
								or L.hole_dir(x, z, s + 1) != L.stair_dir(x, z, s) or L.hole_side(x, z, s + 1) != L.stair_side(x, z, s):
							print("  bad stair at %s" % Vector3i(x, z, s))
							ok = false
					if L.has_flag(x, z, s, LevelLayout.STAIR_ABOVE) and not L.has_flag(x, z, s - 1, LevelLayout.STAIR):
						print("  hole without stair at %s" % Vector3i(x, z, s))
						ok = false
		var families := {}
		for z in L.zones:
			families[z.style.family if z.style else &"?"] = true
		if families.size() < 2:
			print("  missing districts: %s" % [families.keys()])
			ok = false
		for e in L.exits:
			if L.distance[L.idx(e.cell.x, e.cell.y, e.cell.z)] < 0:
				ok = false
			if e.kind == &"locked" and (e.lever as Dictionary).is_empty():
				ok = false
		# Odd ways through: breaches and vents, each on both sides of its wall,
		# and stash rooms reachable only by crawling.
		var gaps := {"breach": 0, "vent": 0}
		for s in L.storeys:
			for z in L.size.y:
				for x in L.size.x:
					for d in 4:
						var n := Vector2i(x, z) + LevelLayout.DIRS[d]
						for kind: String in gaps:
							var flag := LevelLayout.BREACH if kind == "breach" else LevelLayout.VENT
							if L.extra_at(x, z, s) & (flag << d):
								if d == 1 or d == 2:
									gaps[kind] += 1
								if not (L.extra_at(n.x, n.y, s) & (flag << ((d + 2) % 4))):
									print("  one-sided %s at %s/%d" % [kind, Vector3i(x, z, s), d])
									ok = false
		var stashes := L.rooms.filter(func(r: LevelLayout.Room) -> bool: return r.use == &"stash").size()
		print("  breaches %d, vents %d, stashes %d" % [gaps["breach"], gaps["vent"], stashes])
		if gaps["breach"] < 5 or gaps["vent"] < 4:
			ok = false
		var reached_upper := 0
		for s in range(1, L.storeys):
			reached_upper += per_storey[s]
		if reached_upper < 60:
			ok = false
		# Determinism
		var again := LayoutGenerator.generate(profile, seed)
		if again.kind != L.kind or again.flags != L.flags or again.extra != L.extra:
			print("  not deterministic!")
			ok = false
		if not ok:
			failures += 1
			print("  FAIL")
		if seed == 1:
			for s: int in L.all_storeys():
				print("--- storey %d ---" % s)
				print(L.ascii(s))
	print("FAILURES: %d" % failures)
	quit(1 if failures else 0)
