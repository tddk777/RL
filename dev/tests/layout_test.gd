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
		var ok := L.exits.size() >= 2 and reach > 1500 and L.enemies.size() >= 15
		for e in L.exits:
			if L.distance[L.idx(e.cell.x, e.cell.y, e.cell.z)] < 0:
				ok = false
			if e.kind == &"locked" and (e.lever as Dictionary).is_empty():
				ok = false
		var reached_upper := 0
		for s in range(1, L.storeys):
			reached_upper += per_storey[s]
		if reached_upper < 200:
			ok = false
		# Determinism
		var again := LayoutGenerator.generate(profile, seed)
		if again.kind != L.kind or again.flags != L.flags:
			print("  not deterministic!")
			ok = false
		if not ok:
			failures += 1
			print("  FAIL")
		if seed == 1:
			for s in L.storeys:
				print("--- storey %d ---" % s)
				print(L.ascii(s))
	print("FAILURES: %d" % failures)
	quit(1 if failures else 0)
