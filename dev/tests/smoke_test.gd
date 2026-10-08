extends Node
## End-to-end smoke test. Runs the real game flow and checks the core systems:
## menu -> procedural level load -> weapons (fire, reload, modes, bolt action,
## scope) -> ballistics damage -> AI perception/combat -> level exit.
## Saves screenshots to the folder given after `--` (optional).
##
##   godot --path . res://dev/tests/smoke_test.tscn -- <screenshot_dir>

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


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func shot(file: String) -> void:
	if _shots == "":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img:
		img.save_png(_shots.path_join(file))


func place_player(pos: Vector3, yaw: float, pitch_deg: float = 0.0) -> void:
	var p := Game.player
	p.global_position = pos
	p.velocity = Vector3.ZERO
	p.rotation.y = yaw
	p.set(&"_pitch", deg_to_rad(pitch_deg))
	p.set(&"_recoil_pool", 0.0)


## Pulls a real input action for a duration (goes through Player input handling).
func hold(action: StringName, seconds: float) -> void:
	Input.action_press(action)
	await wait(seconds)
	await frames(3)  # at very low frame rates the shot lands a frame later
	Input.action_release(action)
	await frames(3)


func look_at_point(target: Vector3) -> void:
	var p := Game.player
	var eye := p.head.global_position
	var d := target - eye
	p.rotation.y = atan2(-d.x, -d.z)
	p.set(&"_pitch", atan2(d.y, Vector2(d.x, d.z).length()))


func yaw_of(dir: int) -> float:
	var v := LevelLayout.dir_vector(dir)
	return atan2(-v.x, -v.z)


## Straight runs of three ground-floor cells open (or doored) to each other:
## candidate firing lanes. find_lane() checks which are actually clear.
func find_lanes(L: LevelLayout) -> Array:
	var out: Array = []
	for z in L.size.y:
		for x in L.size.x:
			for d in 4:
				var ok := true
				var cells: Array[Vector3i] = []
				for i in 3:
					var v := LevelLayout.dir_vector(d)
					var c := Vector3i(x + int(v.x) * i, z + int(v.z) * i, 0)
					if not L.inside(c.x, c.y, 0) or L.kind_at(c.x, c.y, 0) != LevelLayout.Kind.FLOOR \
							or L.has_flag(c.x, c.y, 0, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) \
							or L.distance[L.idx(c.x, c.y, 0)] < 0 or L.kind_at(c.x, c.y, 1) == LevelLayout.Kind.HOLE \
							or (i < 2 and L.has_wall(c.x, c.y, 0, d) and not L.has_door(c.x, c.y, 0, d)):
						ok = false
						break
					cells.append(c)
				if ok:
					out.append([cells, d])
	return out


## The first lane with a clear line of sight and a navigation path end to end.
func find_lane(L: LevelLayout) -> Array:
	var space := Game.level.get_world_3d().direct_space_state
	var map := Game.level.get_world_3d().navigation_map
	for lane in find_lanes(L):
		var cells: Array[Vector3i] = lane[0]
		var fwd := LevelLayout.dir_vector(lane[1])
		var a := L.cell_center(cells[0].x, cells[0].y, 0) - fwd * 2.5
		var b := L.cell_center(cells[2].x, cells[2].y, 0)
		var clear := true
		for h: float in [0.5, 1.2, 1.6]:
			for off: float in [-0.4, 0.0, 0.4]:
				var side := fwd.cross(Vector3.UP) * off
				var q := PhysicsRayQueryParameters3D.create(a + side + Vector3.UP * h, b + side + Vector3.UP * h)
				if not space.intersect_ray(q).is_empty():
					clear = false
		var path := NavigationServer3D.map_get_path(map, a, b, true)
		if clear and path.size() >= 2 and path[path.size() - 1].distance_to(b) < 0.8 and NavigationServer3D.map_get_closest_point(map, a).distance_to(a) < 0.6:
			return lane
	return []


func _run() -> void:
	# --- Menu ---
	Game.show_main_menu()
	await wait(2.0)
	check(UI.screen_count() == 1, "main menu is shown")
	await shot("01_main_menu.png")

	# --- Level load ---
	Game.start_run()
	var t := 0.0
	while Game.state != Game.State.PLAYING and t < 120.0:
		await wait(0.25)
		t += 0.25
	check(Game.state == Game.State.PLAYING, "level 1 generates and play starts (%.1fs)" % t)
	check(is_instance_valid(Game.player), "player spawned")
	var level := Game.level as ProceduralLevel
	check(level != null, "level root is a ProceduralLevel")
	if level == null:
		get_tree().quit(1)
		return
	var L := level.layout
	t = 0.0
	while (UI.get_node("Fade").color.a > 0.01 or UI.get_node("TitleCard").modulate.a > 0.01) and t < 60.0:
		await wait(0.25)
		t += 0.25
	check(UI.get_node("Fade").color.a <= 0.01 and UI.get_node("TitleCard").modulate.a <= 0.01, "fade and title card clear (%.1fs)" % t)
	check(Registry.all(&"weapons").size() >= 9 and Registry.levels().size() == 1, "registry found content")
	var player := Game.player
	check(player.weapons.size() == 1 and player.current_weapon.data.id == &"m1911", "player starts with the M1911")
	await shot("02_spawn_view.png")

	# The generated scavengers would join in; stand them down and use one rival we control.
	for e in L.enemies:
		e["active"] = true
	for n in get_tree().get_nodes_in_group(&"npc"):
		n.queue_free()
	await frames(2)
	player.health.max_health = 100000.0  # survive the test
	player.health.current = 100000.0

	# --- Firing lane: a straight run of clear floor ---
	var lane := find_lane(L)
	check(not lane.is_empty(), "found a straight lane to test in")
	if lane.is_empty():
		get_tree().quit(1)
		return
	var cells: Array[Vector3i] = lane[0]
	var dir: int = lane[1]
	var fwd := LevelLayout.dir_vector(dir)
	var a := L.cell_center(cells[0].x, cells[0].y, 0) - fwd * 2.5
	var b := L.cell_center(cells[2].x, cells[2].y, 0)
	place_player(a + Vector3.UP * 0.1, yaw_of(dir), -2.0)
	await wait(1.0)
	place_player(a + Vector3.UP * 0.1, yaw_of(dir), -2.0)
	await wait(0.5)
	check(player.is_on_floor(), "player stands in the test lane")

	# --- M1911: semi, reload ---
	var pistol := player.current_weapon
	check(pistol.loaded_rounds() == 8 and player.count_ammo(&".45ACP") == 7, "M1911 has 7+1 and a spare magazine")
	await hold(&"fire", 0.05)
	await wait(0.3)
	check(pistol.loaded_rounds() == 7, "semi fires exactly one round")
	await wait(0.5)
	var decals := Game.world.find_children("*", "Decal", true, false).size()
	check(decals > 0, "bullet impacts left decals (%d)" % decals)
	pistol.reload()
	check(pistol.is_busy(), "reload starts")
	await wait(pistol.data.reload_time + 0.4)
	check(pistol.loaded_rounds() == 8 and player.count_ammo(&".45ACP") == 6, "tactical reload tops up from the spare magazine")
	await shot("03_m1911.png")

	# --- Picked-up rifles (normally found in the level) ---
	for id: StringName in [&"ak47", &"m16", &"mp5", &"m40"]:
		var w := player.add_weapon(Registry.weapon(id))
		player.ammo_reserve[String(w.data.caliber)] = player.count_ammo(w.data.caliber) + 90
	check(player.weapons.size() == 5, "four more weapons added")
	player.equip(1)
	await wait(1.0)
	var ak := player.current_weapon
	check(ak.data.id == &"ak47", "AK equipped")
	var start := ak.loaded_rounds()
	await hold(&"fire", 0.05)
	await wait(0.3)
	check(ak.loaded_rounds() == start - 1, "AK semi fires one round")
	ak.cycle_fire_mode()
	check(ak.current_mode() == WeaponData.FireMode.AUTO, "fire mode switches to auto")
	await hold(&"fire", 0.5)
	check(ak.loaded_rounds() <= start - 4, "auto fires several rounds in 0.5s (%d left)" % ak.loaded_rounds())
	Input.action_press(&"aim")
	await wait(0.6)
	await shot("04_ak_ads.png")
	Input.action_release(&"aim")
	for i in [2, 3]:
		player.equip(i)
		await wait(1.0)
		var w := player.current_weapon
		var before := w.loaded_rounds()
		await hold(&"fire", 0.4)
		check(w.loaded_rounds() < before, "%s fires" % w.data.display_name)
		if w.data.id == &"m16":
			w.cycle_fire_mode()
			before = w.loaded_rounds()
			await wait(0.3)
			await hold(&"fire", 0.6)
			check(before - w.loaded_rounds() == 3, "M16 burst fires exactly 3 (%d)" % (before - w.loaded_rounds()))
	player.equip(4)
	await wait(1.0)
	var m40 := player.current_weapon
	check(m40.attachments.size() == 1, "M40 has its scope mounted")
	await hold(&"fire", 0.05)
	await wait(0.1)
	check(m40.busy_kind() == &"cycle", "bolt cycles after a shot")
	await wait(1.4)
	check(m40.chambered, "bolt chambered the next round")
	Input.action_press(&"aim")
	await wait(1.0)
	check(UI.get_node("Scope").visible, "scope overlay shows when aiming the M40")
	await shot("05_m40_scope.png")
	Input.action_release(&"aim")
	await wait(0.5)
	check(not UI.get_node("Scope").visible, "scope overlay hides after aiming")

	# --- Soviet guns (imported models) and the 1970s-80s set ---
	for id: StringName in [&"makarov", &"tokarev", &"ppsh41", &"sks", &"remington870", &"uzi", &"fal", &"g3", &"aks74u", &"svd",
			&"beretta92", &"python"]:
		var w := player.add_weapon(Registry.weapon(id))
		player.ammo_reserve[String(w.data.caliber)] = player.count_ammo(w.data.caliber) + 60
		player.equip(player.weapons.size() - 1)
		await wait(1.0)
		var before := w.loaded_rounds()
		await hold(&"fire", 0.05)
		await wait(0.4)
		var after := w.loaded_rounds()
		check(after < before and (after == before - 1 or w.data.id == &"ppsh41"), "%s fires (%d -> %d)" % [w.data.display_name, before, after])
		await shot("05_%s_hip.png" % id)
		Input.action_press(&"aim")
		await wait(1.0 if not w.attachments.is_empty() else 0.7)
		if not w.attachments.is_empty():
			check(UI.get_node("Scope").visible, "%s scope overlay shows when aiming" % w.data.display_name)
		await shot("05_%s_ads.png" % id)
		Input.action_release(&"aim")
		await wait(0.3)
		w.reload()
		await wait(w.data.reload_time + (w.data.insert_time * w.data.magazine_size if w.data.feed == WeaponData.Feed.INTERNAL else 0.0) + 0.5)
		check(w.loaded_rounds() > after, "%s reloads (%d -> %d)" % [w.data.display_name, after, w.loaded_rounds()])
	player.equip(1)
	await wait(1.0)

	# --- Rival: ballistics damage ---
	var npc := Registry.enemy(level.profile.enemy_id).scene.instantiate() as NPC
	npc.data = Registry.enemy(level.profile.enemy_id)
	npc.patrol_points.append(b)
	npc.patrol_points.append(b + fwd * 2.0)
	level.add_child(npc)
	npc.global_transform = Transform3D(Basis(Vector3.UP, yaw_of(dir)), b + Vector3.UP * 0.05)
	npc.perception.set_physics_process(false)
	npc.brain.change(&"idle")
	await wait(0.5)
	var hp := npc.health.current
	var muzzle := npc.global_position - fwd * 4.0 + Vector3.UP * 1.4
	Ballistics.fire(muzzle, (npc.global_position + Vector3.UP * 1.2) - muzzle, 715.0, 50.0, ak.ammo, player, [player.get_rid()])
	await wait(0.3)
	check(npc.health.current < hp, "bullet hit the NPC torso (%.0f -> %.0f)" % [hp, npc.health.current])
	check(npc.perception.is_alerted(), "getting shot alerts the NPC")
	npc.health.current = hp
	npc.perception.awareness = 0.0
	npc.brain.change(&"patrol")
	npc.perception.set_physics_process(true)

	var map := player.get_world_3d().navigation_map
	var path := NavigationServer3D.map_get_path(map, b, a, true)
	check(path.size() >= 2 and path[path.size() - 1].distance_to(a) < 1.5, "navmesh path along the lane (%d points)" % path.size())

	# --- AI: hears a shot, spots the player, fights ---
	place_player(a + Vector3.UP * 0.1, yaw_of(dir) + PI, -30.0)
	var player_hp := player.health.current
	await hold(&"fire", 0.05)
	await frames(2)
	check(npc.brain.current_name in [&"investigate", &"combat"], "NPC hears the gunshot (%s)" % npc.brain.current_name)
	look_at_point(npc.eye_position())
	t = 0.0
	while npc.brain.current_name != &"combat" and t < 15.0:
		await wait(0.2)
		t += 0.2
	check(npc.brain.current_name == &"combat", "NPC spots the player and enters combat (%.1fs)" % t)
	# It gets to cover first, then shoots back.
	t = 0.0
	while t < 10.0 and player.health.current >= player_hp and npc.weapon.loaded_rounds() >= npc.weapon.data.magazine_size:
		await wait(0.25)
		t += 0.25
	check(player.health.current < player_hp or npc.weapon.loaded_rounds() < npc.weapon.data.magazine_size,
		"NPC returns fire (%.1f s; player hp %.0f, npc rounds %d)" % [t, player.health.current, npc.weapon.loaded_rounds()])
	await shot("06_under_fire.png")
	for i in 3:
		var eye := player.head.global_position
		Ballistics.fire(eye, npc.eye_position() - eye, 790.0, 105.0, ak.ammo, player, [player.get_rid()])
		await wait(0.15)
	check(not npc.alive, "NPC dies from headshots")
	check(npc.brain.current_name == &"dead", "NPC brain is in dead state")
	player.health.max_health = 100.0
	player.health.current = 100.0
	await wait(1.0)

	# --- Exit ---
	for i in L.exits.size():
		if L.exits[i]["kind"] == &"locked":
			level._on_lever_pulled(i)
	var exit_rec: Dictionary = L.exits[0]
	var ec: Vector3i = exit_rec["cell"]
	var edir: int = exit_rec["dir"]
	var stand := L.cell_center(ec.x, ec.y, ec.z) + LevelLayout.dir_vector(edir) * 2.4
	place_player(stand + Vector3.UP * 0.1, yaw_of(edir), -5.0)
	t = 0.0
	while not level.exit_nodes.has(0) and t < 30.0:
		await wait(0.25)
		t += 0.25
	await wait(1.0)
	place_player(stand + Vector3.UP * 0.1, yaw_of(edir), -5.0)
	await wait(0.6)
	var prompt: String = UI.hud.get_node("Prompt").text
	check(prompt != "", "exit prompt shows ('%s', %s exit)" % [prompt, exit_rec["kind"]])
	await shot("07_exit.png")
	var door := level.exit_nodes.get(0) as ExitDoor
	check(is_instance_valid(door), "exit door spawned with its chunk")
	if is_instance_valid(door):
		door.interact(player)
	await wait(1.0)
	check(Game.state == Game.State.FINISHED and UI.screen_count() == 1, "leaving the last level shows the end screen")
	await shot("08_end_screen.png")

	print("FAILURES: %d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
