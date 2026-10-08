extends Node3D
## Player movement in a bare test arena: running and running out of breath,
## vaulting a low wall, mantling onto a ledge, going prone, leaning (and
## stopping at a wall), and the aim wandering more when winded.
##   godot --headless res://dev/tests/movement_test.tscn

var failures := 0
var player: Player


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func _ready() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60))  # floor
	_box(Vector3(0, 0.45, -6.0), Vector3(4, 0.9, 0.3))  # low wall to vault (z = -6)
	_box(Vector3(10, 0.75, -7.0), Vector3(4, 1.5, 2.0))  # ledge to mantle onto
	_box(Vector3(-9.5, 1.5, 0), Vector3(0.3, 3, 4))  # wall on the right of the lean spot
	player = (load("res://player/player.tscn") as PackedScene).instantiate() as Player
	add_child(player)
	await get_tree().physics_frame
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
	add_child(body)


func _place(p: Vector3, yaw: float = 0.0) -> void:
	player.global_position = p
	player.rotation = Vector3(0, yaw, 0)
	player.velocity = Vector3.ZERO
	await _wait(0.3)


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()


func _hold(actions: Array, seconds: float) -> void:
	for a: StringName in actions:
		Input.action_press(a)
	await _wait(seconds)
	for a: StringName in actions:
		Input.action_release(a)


func _tap(action: StringName) -> void:
	Input.action_press(action)
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release(action)


func _run() -> void:
	# Running: builds up, no faster than sprint_speed, spends stamina.
	await _place(Vector3(20, 0, 20))
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	await _wait(0.3)
	var early := Vector2(player.velocity.x, player.velocity.z).length()
	await _wait(2.7)
	var top := Vector2(player.velocity.x, player.velocity.z).length()
	check(early < top and top <= player.sprint_speed + 0.05 and top > player.walk_speed,
		"running builds up to a laden run (%.1f m/s after 0.3 s, %.1f after 3 s, cap %.1f)" % [early, top, player.sprint_speed])
	check(player.stamina < 0.8, "running spends stamina (%.2f left after 3 s)" % player.stamina)
	# The aim wanders more when winded.
	await _wait(9.0)
	Input.action_release(&"sprint")
	Input.action_release(&"move_forward")
	check(player.exhausted and not player.is_sprinting, "out of breath stops the run (stamina %.2f)" % player.stamina)
	var winded := await _sway_range(1.5)
	player.stamina = 1.0
	player.exhausted = false
	player._since_run = 10.0
	await _wait(1.0)
	var rested := await _sway_range(1.5)
	check(winded > rested * 2.0, "aim wanders far more winded (%.2f deg vs %.2f rested)" % [winded, rested])

	# Vault: over the 0.9 m wall at z = -6.
	await _place(Vector3(0, 0, -5.0))
	Input.action_press(&"move_forward")
	await get_tree().physics_frame
	await _tap(&"jump")
	await _wait(1.6)
	Input.action_release(&"move_forward")
	check(player.global_position.z < -6.4 and player.global_position.y < 0.3,
		"vaults the low wall (now at z %.2f, y %.2f)" % [player.global_position.z, player.global_position.y])

	# Mantle: onto the 1.5 m ledge (top y 1.5, front face z = -6).
	player.stamina = 1.0
	await _place(Vector3(10, 0, -5.5))
	Input.action_press(&"move_forward")
	await get_tree().physics_frame
	await _tap(&"jump")
	await _wait(1.8)
	Input.action_release(&"move_forward")
	check(player.global_position.y > 1.3, "mantles onto the 1.5 m ledge (y %.2f)" % player.global_position.y)

	# Prone and back up.
	await _place(Vector3(-20, 0, 20))
	await _tap(&"prone")
	await _wait(1.3)
	check(player.is_prone and player.head.position.y < 0.6, "goes prone (eye at %.2f m)" % player.head.position.y)
	await _tap(&"prone")
	await _wait(1.3)
	check(not player.is_prone and player.head.position.y > 1.5, "stands back up (eye at %.2f m)" % player.head.position.y)

	# Lean: out in the open, and beside a wall that stops the head.
	await _place(Vector3(-20, 0, 20))
	await _hold([&"lean_right"], 0.8)
	var free_reach := player.head.position.x
	await _place(Vector3(-10.0, 0, 0))
	Input.action_press(&"lean_right")
	await _wait(0.8)
	var walled := player.head.position.x
	Input.action_release(&"lean_right")
	check(free_reach > 0.25 and walled < free_reach - 0.1, "leans out (%.2f m) but not into a wall (%.2f m)" % [free_reach, walled])


## Peak-to-peak wander of the aim (degrees) over `seconds`.
func _sway_range(seconds: float) -> float:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var r := Vector2(player._aim.rotation.y, player._aim.rotation.x)
		lo = Vector2(minf(lo.x, r.x), minf(lo.y, r.y))
		hi = Vector2(maxf(hi.x, r.x), maxf(hi.y, r.y))
	return rad_to_deg((hi - lo).length())
