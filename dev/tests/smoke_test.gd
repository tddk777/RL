extends Node
## End-to-end smoke test. Runs the real game flow and checks the core systems:
## menu -> level load -> weapons (fire, reload, modes, bolt action, scope) ->
## ballistics damage -> AI perception/combat -> interaction -> level exit.
## Saves screenshots to the folder given after `--` (optional).
##
##   godot --path . res://dev/tests/smoke_test.tscn -- <screenshot_dir>

var _failures := 0
var _shots := ""


func _ready() -> void:
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


func place_player(pos: Vector3, yaw_deg: float, pitch_deg: float = 0.0) -> void:
	var p := Game.player
	p.global_position = pos
	p.velocity = Vector3.ZERO
	p.rotation.y = deg_to_rad(yaw_deg)
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


func _run() -> void:
	# --- Menu ---
	Game.show_main_menu()
	await wait(2.0)
	check(UI.screen_count() == 1, "main menu is shown")
	await shot("01_main_menu.png")

	# --- Level load ---
	Game.start_run()
	var t := 0.0
	while Game.state != Game.State.PLAYING and t < 30.0:
		await wait(0.25)
		t += 0.25
	check(Game.state == Game.State.PLAYING, "level 1 loads and play starts (%.1fs)" % t)
	check(is_instance_valid(Game.player), "player spawned")
	check(Game.level is Level, "level root is a Level")
	t = 0.0
	while (UI.get_node("Fade").color.a > 0.01 or UI.get_node("TitleCard").modulate.a > 0.01) and t < 60.0:
		await wait(0.25)
		t += 0.25
	check(UI.get_node("Fade").color.a <= 0.01 and UI.get_node("TitleCard").modulate.a <= 0.01, "fade and title card clear (%.1fs)" % t)
	var npcs := get_tree().get_nodes_in_group(&"npc")
	check(npcs.size() == 1, "one rival NPC spawned (%d)" % npcs.size())
	var player := Game.player
	check(player.weapons.size() == 4, "player carries 4 weapons")
	check(Registry.all(&"weapons").size() == 4 and Registry.levels().size() == 1, "registry found content")
	await shot("02_spawn_view.png")

	# Keep the NPC out of the way while testing weapons.
	var npc: NPC = npcs[0]
	npc.set_physics_process(false)
	npc.global_position = Vector3(23.0, 5.05, 14.5)

	# --- AK: semi, auto, reload ---
	place_player(Vector3(5.0, 0.05, 8.0), 180.0, -2.0)
	await wait(0.8)
	var ak := player.current_weapon
	check(ak.data.id == &"ak47", "AK equipped first")
	var start := ak.loaded_rounds()
	check(start == 31, "AK starts with 30 + 1 chambered (%d)" % start)
	await hold(&"fire", 0.05)
	await wait(0.3)
	check(ak.loaded_rounds() == start - 1, "semi fires exactly one round")
	await shot("03_ak_hip.png")
	ak.cycle_fire_mode()
	check(ak.current_mode() == WeaponData.FireMode.AUTO, "fire mode switches to auto")
	await hold(&"fire", 0.5)
	var after_auto := ak.loaded_rounds()
	check(after_auto <= start - 4, "auto fires several rounds in 0.5s (%d left)" % after_auto)
	await wait(0.5)
	var decals := Game.world.find_children("*", "Decal", true, false).size()
	check(decals > 0, "bullet impacts left decals (%d)" % decals)
	Input.action_press(&"aim")
	await wait(0.6)
	await shot("04_ak_ads.png")
	Input.action_release(&"aim")
	var reserve_before := ak.reserve_rounds()
	ak.reload()
	check(ak.is_busy(), "reload starts")
	await wait(ak.data.reload_time + 0.4)
	check(ak.loaded_rounds() == 31 and ak.reserve_rounds() < reserve_before, "tactical reload refills to 31 from reserve")

	# --- Other weapons ---
	for i in [1, 2]:
		player.equip(i)
		await wait(1.0)
		var w := player.current_weapon
		Input.action_press(&"aim")
		await wait(0.7)
		await shot("05_%s_ads.png" % w.data.id)
		Input.action_release(&"aim")
		var before := w.loaded_rounds()
		await hold(&"fire", 0.4)
		check(w.loaded_rounds() < before, "%s fires" % w.data.display_name)
		if w.data.id == &"m16":
			w.cycle_fire_mode()
			before = w.loaded_rounds()
			await wait(0.3)
			await hold(&"fire", 0.6)
			check(before - w.loaded_rounds() == 3, "M16 burst fires exactly 3 (%d)" % (before - w.loaded_rounds()))
		await shot("06_%s_hip.png" % w.data.id)
	player.equip(3)
	await wait(1.0)
	var m40 := player.current_weapon
	check(m40.attachments.size() == 1, "M40 has its scope mounted")
	check(m40.data.feed == WeaponData.Feed.INTERNAL and m40.loaded_rounds() == 6, "M40 holds 5 + 1")
	await hold(&"fire", 0.05)
	await wait(0.1)
	check(m40.busy_kind() == &"cycle", "bolt cycles after a shot")
	await wait(1.4)
	check(m40.chambered and m40.loaded_rounds() == 5, "bolt chambered the next round")
	Input.action_press(&"aim")
	await wait(1.0)
	check(UI.get_node("Scope").visible, "scope overlay shows when aiming the M40")
	await shot("07_m40_scope.png")
	Input.action_release(&"aim")
	await wait(0.5)
	check(not UI.get_node("Scope").visible, "scope overlay hides after aiming")
	m40.reload()
	await wait(0.4 + m40.data.insert_time * 1.5)
	await hold(&"fire", 0.05)  # interrupts single-round loading
	check(not m40.is_busy() or m40.busy_kind() == &"cycle", "firing interrupts round-by-round loading")
	player.equip(0)
	await wait(1.0)

	# --- Damage via ballistics ---
	npc.set_physics_process(true)
	npc.global_position = Vector3(2.0, 0.05, -2.0)
	npc.perception.set_physics_process(false)
	npc.brain.change(&"idle")
	await wait(0.3)
	var hp := npc.health.current
	var muzzle := Vector3(2.0, 1.4, 6.0)
	Ballistics.fire(muzzle, (npc.global_position + Vector3.UP * 1.2) - muzzle, 715.0, 50.0, ak.ammo, player, [player.get_rid()])
	await wait(0.3)
	check(npc.health.current < hp, "bullet hit the NPC torso (%.0f -> %.0f)" % [hp, npc.health.current])
	check(npc.perception.is_alerted(), "getting shot alerts the NPC")
	npc.health.current = hp
	npc.perception.awareness = 0.0
	npc.perception.set_physics_process(true)

	# --- AI: sees the player and fights ---
	var path := NavigationServer3D.map_get_path(npc.get_world_3d().navigation_map, npc.global_position, Vector3(-11.0, 5.0, 0.0), true)
	check(path.size() > 2 and path[path.size() - 1].distance_to(Vector3(-11.0, 5.0, 0.0)) < 1.0,
		"navmesh path from the ground floor up to the bridge (%d points)" % path.size())
	npc.global_position = Vector3(10.0, 5.05, -14.5)
	npc.brain.change(&"patrol")
	place_player(Vector3(10.0, 0.05, -4.0), 0.0)
	look_at_point(npc.eye_position())
	await wait(0.4)
	await shot("08_rival_on_catwalk.png")
	player.health.max_health = 100000.0  # survive the test fight
	player.health.current = 100000.0
	var player_hp := player.health.current
	# A gunshot draws the rival: it should hear it, turn, spot the player and fight.
	place_player(Vector3(10.0, 0.05, -4.0), 180.0, -30.0)
	await hold(&"fire", 0.05)
	await frames(2)
	check(npc.brain.current_name in [&"investigate", &"combat"], "NPC hears the gunshot (%s)" % npc.brain.current_name)
	look_at_point(npc.eye_position())
	t = 0.0
	while npc.brain.current_name != &"combat" and t < 15.0:
		await wait(0.2)
		t += 0.2
	check(npc.brain.current_name == &"combat", "NPC spots the player and enters combat (%.1fs)" % t)
	await wait(4.0)
	check(player.health.current < player_hp or Ballistics.active_count() > 0 or npc.weapon.loaded_rounds() < 31,
		"NPC returns fire (player hp %.0f, npc rounds %d)" % [player.health.current, npc.weapon.loaded_rounds()])
	await shot("09_under_fire.png")
	player.health.max_health = 100.0
	player.health.current = 100.0

	# --- Kill the NPC ---
	for i in 3:
		var eye := player.head.global_position
		Ballistics.fire(eye, npc.eye_position() - eye, 790.0, 105.0, ak.ammo, player, [player.get_rid()])
		await wait(0.15)
	check(not npc.alive, "NPC dies from headshots")
	check(npc.brain.current_name == &"dead", "NPC brain is in dead state")
	await wait(1.0)

	# --- Look around the level ---
	for view in [
		["10_hall_from_catwalk.png", Vector3(20.0, 5.05, -12.0), 60.0, -14.0],
		["11_hall_ground.png", Vector3(-10.0, 0.05, 6.0), -110.0, 8.0],
		["12_office_floor2.png", Vector3(-16.5, 5.05, 12.0), 0.0, -4.0],
		["13_bridge.png", Vector3(16.0, 5.05, 0.0), 90.0, -2.0],
		["14_camp.png", Vector3(15.0, 0.05, -6.0), 40.0, -10.0],
	]:
		place_player(view[1], view[2], view[3])
		await wait(1.2)
		await shot(view[0])

	# --- Exit ---
	place_player(Vector3(-22.6, 10.05, -15.0), 90.0, -5.0)
	await wait(0.6)
	var prompt: String = UI.hud.get_node("Prompt").text
	check(prompt.contains("service stairs"), "exit prompt shows ('%s')" % prompt)
	await shot("15_exit.png")
	var exit := Game.level.find_child("Exit", true, false) as LevelExit
	exit.interact(player)
	await wait(1.0)
	check(Game.state == Game.State.FINISHED and UI.screen_count() == 1, "leaving the last level shows the end screen")
	await shot("16_end_screen.png")

	print("FAILURES: %d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
