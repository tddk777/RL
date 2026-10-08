extends Node3D
## The AI in a bare arena with scattered cover (low walls, pillars, crates):
## takes cover and fires, gets pinned by near misses, flanks as a group,
## searches when the player hides, pushes on a heard reload. Prints a log of
## each NPC's state and tactic.
##   godot --headless res://dev/tests/ai_test.tscn [-- verbose]

var failures := 0
var player: Player
var verbose := false
var region: NavigationRegion3D


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func _ready() -> void:
	verbose = "verbose" in OS.get_cmdline_user_args()
	seed(12345)
	region = NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.25
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.3
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	region.navigation_mesh = nm
	add_child(region)
	NavigationServer3D.map_set_cell_size(get_world_3d().navigation_map, 0.25)
	NavigationServer3D.map_set_cell_height(get_world_3d().navigation_map, 0.25)
	_box(Vector3(0, -0.5, 0), Vector3(70, 1, 70))
	# Cover between the two sides: low walls, pillars, crates.
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in 26:
		var p := Vector3(r.randf_range(-22, 22), 0, r.randf_range(-24, 6))
		match i % 3:
			0:
				_box(p + Vector3.UP * 0.5, Vector3(2.2, 1.0, 0.4) if r.randf() < 0.5 else Vector3(0.4, 1.0, 2.2))
			1:
				_box(p + Vector3.UP * 1.5, Vector3(1.0, 3.0, 1.0))
			2:
				_box(p + Vector3.UP * 0.6, Vector3(1.2, 1.2, 1.2))
	# Cover off to the player's sides too (somewhere for a flanker to go).
	for e: float in [-1.0, 1.0]:
		_box(Vector3(e * 10.0, 0.5, 6.0), Vector3(2.2, 1.0, 0.4))
		_box(Vector3(e * 14.0, 1.5, 10.0), Vector3(1.0, 3.0, 1.0))
		_box(Vector3(e * 9.0, 0.6, 13.0), Vector3(1.2, 1.2, 1.2))
	# A wall the player can hide behind.
	_box(Vector3(0, 1.5, 14), Vector3(8, 3, 0.4))
	region.bake_navigation_mesh(false)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	light.add_to_group(&"world_lights")
	add_child(light)
	player = (load("res://player/player.tscn") as PackedScene).instantiate() as Player
	add_child(player)
	player.health.max_health = 1e9
	player.health.current = 1e9
	Game.player = player
	await _wait(1.0)
	await _run()
	print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)


func _box(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	region.add_child(body)


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()


func _spawn(p: Vector3) -> NPC:
	# Everyone on the default rifle: this tests behaviour, not the weapon draw.
	var data := Registry.enemy(&"scavenger").duplicate() as EnemyData
	data.weapon_pool = []
	var npc := data.scene.instantiate() as NPC
	npc.data = data
	add_child(npc)
	npc.global_position = p
	npc.look_at(Vector3(player.global_position.x, p.y, player.global_position.z), Vector3.UP)
	return npc


func _clear() -> void:
	for n in get_tree().get_nodes_in_group(&"npc"):
		n.queue_free()
	var d := get_tree().get_first_node_in_group(&"ai_director")
	if d:
		d.queue_free()
	await _wait(0.3)


func _tactic(npc: NPC) -> String:
	var c := npc.brain.current
	if npc.brain.current_name == &"combat":
		return String(["take_cover", "engage", "flank", "push", "retreat"][c.get(&"tactic")])
	return ""


func _log(npcs: Array, t: float) -> void:
	if not verbose:
		return
	for n: NPC in npcs:
		if not is_instance_valid(n):
			continue
		var extra := ""
		if n.brain.current_name == &"combat":
			var c := n.brain.current
			var sp: Tactics.Spot = c.get(&"spot")
			extra = " sees=%s peek=%s phase=%.1f react=%.1f spot=%s" % [n.perception.can_see_target, c.get(&"_peeking"), c.get(&"_phase"),
				c.get(&"_reaction"), sp.kind if sp else &"-"]
			extra += " trig=%s cd=%.2f mode=%d burst=%d pause=%.2f pulse=%.2f" % [n.weapon.get(&"_trigger"), n.weapon.get(&"_cooldown"),
				n.weapon.current_mode(), c.get(&"_burst_left"), c.get(&"_pause"), c.get(&"_pulse")]
		print("  t%5.1f %s %-11s %-10s %s crouch=%s sup=%.2f aw=%.2f rounds=%d role=%s agg=%.2f vuln=%s%s" % [t, n.name,
			n.brain.current_name, _tactic(n), n.global_position.snapped(Vector3(0.1, 0.1, 0.1)), n.crouched, n.suppression,
			n.perception.awareness, n.weapon.loaded_rounds(), n.director.role_of(n), n.aggression, n.director.player_vulnerable(), extra])


func _hidden_from_player(npc: NPC) -> bool:
	var q := PhysicsRayQueryParameters3D.create(player.head.global_position, npc.eye_position(), Layers.SIGHT_MASK, npc.exclude_rids())
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _run() -> void:
	# 1. One NPC, the player in the open: they take cover and shoot back.
	player.global_position = Vector3(0, 0, 10)
	player.rotation.y = 0.0
	var a := _spawn(Vector3(2, 0, -20))
	a.perception.alert_to(player.global_position)
	var fired := false
	var covered := false
	var max_rounds := a.weapon.loaded_rounds()
	var t := 0.0
	while t < 12.0:
		await _wait(0.5)
		t += 0.5
		_log([a], t)
		if a.weapon.loaded_rounds() < max_rounds or a.weapon.is_busy():
			fired = true
		if _tactic(a) == "engage" and not a.brain.current.get(&"_peeking") and _hidden_from_player(a):
			covered = true
	check(fired, "fights back from range (fired within 12 s)")
	check(covered, "hides behind cover between peeks")

	await _clear()

	# 2. Near misses pin them (an open lane off to the side of the arena).
	player.global_position = Vector3(30, 0, 22)
	var b := _spawn(Vector3(30, 0, 6))
	await _wait(0.3)
	for i in 6:
		var head := b.eye_position()
		var from := player.head.global_position
		Ballistics.fire(from, (head + Vector3(0.6, 0.7, 0.0)) - from, 715.0, 30.0, null, player, [player.get_rid(), player.hitbox.get_rid()])
		await _wait(0.08)
	await _wait(0.2)
	check(b.suppression > 0.4, "rounds cracking past pin them (suppression %.2f)" % b.suppression)
	check(b.perception.is_alerted(), "and give away roughly where they came from")
	await _clear()
	player.global_position = Vector3(0, 0, 10)

	# 3. Three of them: one works round the side.
	var squad: Array = []
	for x: float in [-6.0, 0.0, 6.0]:
		var n := _spawn(Vector3(x, 0, -18))
		squad.append(n)
	for n: NPC in squad:
		n.perception.alert_to(player.global_position)
	var flanked := false
	var had_flanker := false
	var start_angles := {}
	for n: NPC in squad:
		start_angles[n] = _bearing(n)
	t = 0.0
	while t < 16.0:
		await _wait(0.5)
		t += 0.5
		_log(squad, t)
		for n: NPC in squad:
			if is_instance_valid(n) and absf(angle_difference(start_angles[n], _bearing(n))) > deg_to_rad(35.0):
				flanked = true
			if is_instance_valid(n) and n.director.role_of(n) == AIDirector.ROLE_FLANK:
				had_flanker = true
	check(had_flanker, "the director sends a flanker")
	check(flanked, "someone works round the player's side")

	# 4. The player reloads where they can hear: someone pushes.
	# Some way off the nearest of them (close enough to hear the magazine,
	# far enough that closing in is a move worth making).
	var pushed := false
	var nearest: NPC = null
	for n: NPC in squad:
		if is_instance_valid(n) and n.alive and (nearest == null
				or n.global_position.distance_to(player.global_position) < nearest.global_position.distance_to(player.global_position)):
			nearest = n
	if nearest:
		var away := (player.global_position - nearest.global_position)
		away.y = 0.0
		player.global_position = nearest.global_position + away.normalized() * 14.0
	await _wait(0.5)
	Events.actor_reloading.emit(player)
	for n: NPC in squad:
		if is_instance_valid(n) and n.brain.current_name == &"combat":
			n.brain.current.set(&"_decide", 0.0)
	t = 0.0
	while t < 2.5:
		await _wait(0.25)
		t += 0.25
		for n: NPC in squad:
			if is_instance_valid(n) and _tactic(n) == "push":
				pushed = true
		_log(squad, 100.0 + t)
	check(pushed, "a heard reload draws a push")

	# 5. The player disappears behind the wall: after a while they search.
	player.global_position = Vector3(0, 0, 17)
	var searched := false
	t = 0.0
	while t < 18.0:
		await _wait(0.5)
		t += 0.5
		_log(squad, t)
		for n: NPC in squad:
			if is_instance_valid(n) and n.brain.current_name == &"search":
				searched = true
		if searched:
			break
	check(searched, "losing the player sends them searching (%.1f s)" % t)
	await _clear()


## Bearing of an NPC as seen from the player (radians).
func _bearing(n: NPC) -> float:
	var d := n.global_position - player.global_position
	return atan2(d.x, d.z)
