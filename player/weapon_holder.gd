class_name WeaponHolder
extends Node3D
## First-person weapon presentation under the camera: hip/ADS positioning,
## sway, bob, sprint pose, recoil kick, wall push-back, weapon switching, and
## the IK view arms. Gameplay state comes from the owning Player.

const RIGHT_SHOULDER := Vector3(0.19, -0.25, 0.06)
const LEFT_SHOULDER := Vector3(-0.13, -0.26, -0.10)
const SWITCH_TIME := 0.22

## Mouse movement since last frame (set by Player) for sway.
var look_delta := Vector2.ZERO
## 0 = hip, 1 = fully aimed.
var ads_blend: float = 0.0
var current: Weapon

var _player: Player
var _sway := Vector2.ZERO
var _bob_time: float = 0.0
var _idle_time: float = 0.0
var _sprint: float = 0.0
var _kick_pos: float = 0.0
var _kick_rot: float = 0.0
var _block: float = 0.0
var _lowered: float = 1.0
var _switching: bool = false
var _dead: bool = false
var _arm_r: ArmRig
var _arm_l: ArmRig
var _right_shoulder: Node3D
var _left_shoulder: Node3D


func _ready() -> void:
	_player = owner as Player
	_right_shoulder = _make_shoulder("RightShoulder", RIGHT_SHOULDER)
	_left_shoulder = _make_shoulder("LeftShoulder", LEFT_SHOULDER)
	var sleeve: Material = load("res://assets/materials/fabric_dark.tres")
	var glove: Material = load("res://assets/materials/leather.tres")
	_arm_r = _make_arm(_right_shoulder, sleeve, glove, false)
	_arm_l = _make_arm(_left_shoulder, sleeve, glove, true)


func add_weapon(weapon: Weapon) -> void:
	add_child(weapon)
	weapon.visible = false
	_no_shadows(weapon)


func equip(weapon: Weapon) -> void:
	if weapon == current:
		return
	_switching = true
	if current:
		var lower := create_tween()
		lower.tween_property(self, "_lowered", 1.0, SWITCH_TIME * (1.0 - _lowered))
		await lower.finished
		current.visible = false
	current = weapon
	current.visible = true
	_no_shadows(current)
	ads_blend = 0.0
	var raise := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	raise.tween_property(self, "_lowered", 0.0, maxf(current.data.equip_time, 0.1))
	await raise.finished
	_switching = false


func is_switching() -> bool:
	return _switching


## True while the weapon is pushed back by a wall (firing is blocked).
func is_blocked() -> bool:
	return _block > 0.55


func kick(back: float, rotation_deg: float) -> void:
	_kick_pos += back
	_kick_rot += rotation_deg


func drop_out_of_view() -> void:
	_dead = true
	UI.set_scope_overlay(null)


func _process(delta: float) -> void:
	if current == null or _player == null:
		return
	var data := current.data
	var aiming := _player.is_aiming and not _switching and not _dead and not current.busy_kind() in [&"reload", &"insert"]
	ads_blend = move_toward(ads_blend, 1.0 if aiming else 0.0, delta / maxf(current.ads_time(), 0.05))
	var aim := smoothstep(0.0, 1.0, ads_blend)

	# Base position: hip offset blended to the sight line.
	var ads_pos := Vector3(0.0, 0.0, -data.ads_eye_distance) - current.model.ads_local_position()
	var pos := data.hip_offset.lerp(ads_pos, aim)
	var rot := Vector3.ZERO

	# Sway: the weapon lags behind mouse movement.
	var sway_target := Vector2(-look_delta.x, -look_delta.y) * 0.0011 * data.sway * (1.0 - 0.75 * aim)
	_sway = _sway.lerp(sway_target.clamp(Vector2(-0.08, -0.08), Vector2(0.08, 0.08)), clampf(9.0 * delta, 0.0, 1.0))
	rot.y += _sway.x
	rot.x += _sway.y
	pos.x += _sway.x * 0.06 * (1.0 - aim)

	# Walk bob and idle breathing.
	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	_idle_time += delta
	if _player.is_on_floor() and speed > 0.3:
		_bob_time += delta * (6.5 if _player.is_sprinting else 4.2 + speed * 0.4)
	var bob_amp := clampf(speed / 3.2, 0.0, 1.6) * 0.007 * (1.0 - 0.85 * aim)
	pos += Vector3(sin(_bob_time) * bob_amp, -absf(cos(_bob_time)) * bob_amp, 0.0)
	var breathe := 0.0012 * (1.0 - 0.6 * aim)
	pos += Vector3(sin(_idle_time * 0.9) * breathe, sin(_idle_time * 1.3) * breathe, 0.0)

	# Sprint pose.
	_sprint = move_toward(_sprint, 1.0 if _player.is_sprinting else 0.0, delta * 5.0)
	pos += Vector3(-0.04, -0.05, 0.04) * _sprint
	rot += Vector3(deg_to_rad(-18.0), deg_to_rad(30.0), deg_to_rad(12.0)) * _sprint

	# Recoil kick springs back.
	_kick_pos = lerpf(_kick_pos, 0.0, clampf(14.0 * delta, 0.0, 1.0))
	_kick_rot = lerpf(_kick_rot, 0.0, clampf(12.0 * delta, 0.0, 1.0))
	pos.z += _kick_pos
	rot.x += deg_to_rad(_kick_rot)

	# Reload / cycle tilt.
	var busy := 1.0 if current.busy_kind() in [&"reload", &"insert"] else 0.0
	rot.z += deg_to_rad(18.0) * busy
	rot.x += deg_to_rad(8.0) * busy

	# Wall push-back: lower and pull the weapon in when the muzzle would clip.
	_block = lerpf(_block, _wall_block(data.length), clampf(10.0 * delta, 0.0, 1.0))
	pos += Vector3(-0.03, -0.05, 0.16) * _block
	rot.x += deg_to_rad(-40.0) * _block

	# Switching and death lower the weapon out of view.
	var lowered := 1.0 if _dead else _lowered
	pos.y -= 0.35 * lowered
	rot.x += deg_to_rad(-45.0) * lowered

	current.position = pos
	current.rotation = rot

	var overlay := current.ads_overlay()
	var scoped := overlay != null and ads_blend > 0.97 and not _dead
	UI.set_scope_overlay(overlay if scoped else null)
	current.visible = not scoped
	_arm_r.visible = not scoped
	_arm_l.visible = not scoped
	_update_arms()


func _update_arms() -> void:
	var model := current.model
	var cam_basis := get_parent_node_3d().global_basis
	var forward := -model.global_basis.z
	var right_target := model.grip_r.global_position if model.grip_r else model.global_position
	var left_target := model.grip_l.global_position if model.grip_l else model.global_position
	var kind := current.busy_kind()
	if kind == &"reload" and model.magazine and model.magazine.visible:
		left_target = model.magazine.global_position + model.magazine.global_basis.y * -0.08
	elif kind in [&"cycle", &"insert"] and model.bolt:
		right_target = model.bolt.get_child(0).global_position if model.bolt.get_child_count() > 0 else right_target
	var right_pole := _right_shoulder.global_position + cam_basis * Vector3(0.35, -0.6, 0.1)
	var left_pole := _left_shoulder.global_position + cam_basis * Vector3(-0.45, -0.6, 0.0)
	_arm_r.solve(right_target, right_pole, forward)
	_arm_l.solve(left_target, left_pole, forward)


func _wall_block(length: float) -> float:
	var cam := get_parent_node_3d()
	var from := cam.global_position
	var to := from - cam.global_basis.z * (length + 0.1)
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return clampf(1.0 - from.distance_to(hit.position) / (length + 0.1), 0.0, 1.0) * 1.6


func _make_shoulder(node_name: String, offset: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	node.position = offset
	add_child(node)
	return node


func _make_arm(shoulder: Node3D, sleeve: Material, glove: Material, left: bool) -> ArmRig:
	var arm := ArmRig.new()
	arm.name = "Arm"
	arm.upper_length = 0.31
	arm.lower_length = 0.33
	arm.sleeve_material = sleeve
	arm.glove_material = glove
	arm.left = left
	shoulder.add_child(arm)
	arm.set_shadow_casting(GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	return arm


static func _no_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_no_shadows(child)
