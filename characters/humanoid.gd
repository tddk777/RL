class_name Humanoid
extends NPCBody
## Procedural human body: builds its meshes, a simple joint rig, IK arms and
## per-zone hitboxes at runtime, and animates walking, aiming and death.
## The fallback body (no imported assets); `Mannequin` is the rigged one.

@export var jacket: Material = preload("res://assets/materials/fabric_dark.tres")
@export var trousers: Material = preload("res://assets/materials/fabric_canvas.tres")
@export var leather: Material = preload("res://assets/materials/leather.tres")
@export var rubber: Material = preload("res://assets/materials/rubber.tres")
@export var lens: Material = preload("res://assets/materials/mask_glass.tres")
@export var gear: Material = preload("res://assets/materials/fabric_canvas.tres")

const HIP_HEIGHT := 0.94
const THIGH := 0.45
const SHIN := 0.45

var hips: Node3D
var spine: Node3D
var head: Node3D
var weapon_mount: Node3D

var _thigh := {}
var _knee := {}
var _arm_r: ArmRig
var _arm_l: ArmRig
var _weapon: Weapon
var _phase: float = 0.0
var _speed: float = 0.0
var _aim_pitch: float = 0.0
var _aim_blend: float = 0.0
var _dead: bool = false
## Hand targets in this node's local space [right, left] when not holding a weapon.
var _hand_targets: Array = [Vector3(0.24, 0.9, -0.05), Vector3(-0.24, 0.9, -0.05)]


func _ready() -> void:
	if hips == null:
		_build()


# --- API ------------------------------------------------------------------------

## Creates the hitboxes, all feeding `health`. Returns them (for bullet exclusion).
func setup(health: HealthComponent) -> Array[Hitbox]:
	var boxes: Array[Hitbox] = []
	boxes.append(_hitbox(head, &"head", 4.0, health, _sphere(0.13), Vector3(0, 0.1, 0)))
	boxes.append(_hitbox(spine, &"torso", 1.0, health, _box(Vector3(0.44, 0.5, 0.3)), Vector3(0, 0.27, 0)))
	boxes.append(_hitbox(hips, &"pelvis", 0.9, health, _box(Vector3(0.38, 0.2, 0.26)), Vector3(0, -0.02, 0)))
	for side in [&"l", &"r"]:
		boxes.append(_hitbox(_thigh[side], &"leg", 0.65, health, _capsule(0.085, THIGH), Vector3(0, -THIGH * 0.5, 0)))
		boxes.append(_hitbox(_knee[side], &"leg", 0.55, health, _capsule(0.07, SHIN), Vector3(0, -SHIN * 0.5, 0)))
	return boxes


func hold_weapon(weapon: Weapon) -> void:
	_weapon = weapon
	weapon_mount.add_child(weapon)


func set_motion(speed: float, _run: bool) -> void:
	_speed = speed


## Points the upper body and weapon at a global position.
func set_aim(target: Vector3, aiming: bool) -> void:
	var local := global_transform.affine_inverse() * target
	var from := global_transform.affine_inverse() * eye.global_position
	var d := local - from
	_aim_pitch = atan2(d.y, Vector2(d.x, d.z).length())
	_aim_blend = 1.0 if aiming else 0.0


func die(direction: Vector3) -> void:
	_dead = true
	var local_dir := global_basis.inverse() * direction
	var fall_back := 1.0 if local_dir.z < 0.0 else -1.0  # shot from the front falls backward
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "rotation:x", deg_to_rad(84.0) * fall_back, 0.7)
	tween.parallel().tween_property(self, "position:y", 0.14, 0.7)
	tween.parallel().tween_property(self, "rotation:z", deg_to_rad(randf_range(-15, 15)), 0.7)
	for side in [&"l", &"r"]:
		tween.parallel().tween_property(_thigh[side], "rotation:x", deg_to_rad(randf_range(-10, 25)), 0.5)
		tween.parallel().tween_property(_knee[side], "rotation:x", deg_to_rad(randf_range(5, 40)), 0.5)


# --- Animation ------------------------------------------------------------------

func _process(delta: float) -> void:
	if _dead:
		_update_arms()
		return
	var moving := clampf(_speed / 1.6, 0.0, 2.6)
	_phase += delta * (2.0 + _speed * 2.2) * (1.0 if moving > 0.05 else 0.0)
	var swing := 0.42 * minf(moving, 1.4)
	for side in [&"l", &"r"]:
		var offset := 0.0 if side == &"l" else PI
		var s := sin(_phase + offset)
		(_thigh[side] as Node3D).rotation.x = lerpf((_thigh[side] as Node3D).rotation.x, s * swing, clampf(12.0 * delta, 0, 1))
		var bend := maxf(0.0, sin(_phase + offset + 1.2)) * swing * 1.5
		(_knee[side] as Node3D).rotation.x = lerpf((_knee[side] as Node3D).rotation.x, -bend, clampf(12.0 * delta, 0, 1))
	hips.position.y = HIP_HEIGHT - absf(sin(_phase)) * 0.03 * minf(moving, 1.5)
	spine.rotation.x = lerpf(spine.rotation.x, -0.06 * minf(moving, 2.0), clampf(6.0 * delta, 0, 1))
	# Weapon: low ready unless aiming; aiming follows target pitch.
	var weapon_pitch := lerpf(deg_to_rad(-32.0), _aim_pitch, _aim_blend)
	weapon_mount.rotation.x = lerp_angle(weapon_mount.rotation.x, weapon_pitch - spine.rotation.x, clampf(10.0 * delta, 0, 1))
	head.rotation.x = lerp_angle(head.rotation.x, _aim_pitch * 0.6 * _aim_blend, clampf(8.0 * delta, 0, 1))
	_update_arms()


## Instant dead pose for bodies placed in the level (no animation).
## pose: 0 fallen, 1 laid out arms spread, 2 kneeling.
func pose_dead(pose: int, variant: int = 0) -> void:
	if hips == null:
		_build()
	_dead = true
	var r := RandomNumberGenerator.new()
	r.seed = variant
	match pose:
		1:
			rotation.x = deg_to_rad(88.0)
			position.y = 0.14
			_hand_targets = [Vector3(0.75, 1.3, 0.0), Vector3(-0.75, 1.3, 0.0)]
		2:
			hips.position.y = 0.52
			for side in [&"l", &"r"]:
				(_thigh[side] as Node3D).rotation.x = deg_to_rad(-6.0)
				(_knee[side] as Node3D).rotation.x = deg_to_rad(-86.0)
			spine.rotation.x = deg_to_rad(-28.0)
			head.rotation.x = deg_to_rad(-35.0)
			_hand_targets = [Vector3(0.2, 0.45, -0.35), Vector3(-0.2, 0.45, -0.35)]
		_:
			rotation.x = deg_to_rad(84.0) * (1.0 if r.randf() < 0.5 else -1.0)
			rotation.z = deg_to_rad(r.randf_range(-20.0, 20.0))
			position.y = 0.14
			for side in [&"l", &"r"]:
				(_thigh[side] as Node3D).rotation.x = deg_to_rad(r.randf_range(-10.0, 30.0))
				(_knee[side] as Node3D).rotation.x = deg_to_rad(r.randf_range(-45.0, -5.0))
			_hand_targets = [Vector3(r.randf_range(0.3, 0.6), r.randf_range(0.7, 1.4), r.randf_range(-0.3, 0.2)),
				Vector3(r.randf_range(-0.6, -0.3), r.randf_range(0.7, 1.4), r.randf_range(-0.3, 0.2))]
	set_process(false)
	_update_arms.call_deferred()


func _update_arms() -> void:
	if _weapon == null or _weapon.model == null:
		var b := global_basis
		_arm_r.solve(global_transform * (_hand_targets[0] as Vector3), _arm_r.global_position + b * Vector3(0.4, -0.3, 0.3))
		_arm_l.solve(global_transform * (_hand_targets[1] as Vector3), _arm_l.global_position + b * Vector3(-0.4, -0.3, 0.3))
		return
	var model := _weapon.model
	var basis := global_basis
	if model.grip_r:
		_arm_r.solve(model.grip_r.global_position, _arm_r.global_position + basis * Vector3(0.4, -0.6, 0.3), -model.global_basis.z)
	if model.grip_l:
		var left_target := model.grip_l.global_position
		if _weapon.busy_kind() == &"reload" and model.magazine and model.magazine.visible:
			left_target = model.magazine.global_position
		_arm_l.solve(left_target, _arm_l.global_position + basis * Vector3(-0.5, -0.6, 0.1), -model.global_basis.z)


# --- Construction ----------------------------------------------------------------

func _build() -> void:
	hips = _pivot("Hips", self, Vector3(0, HIP_HEIGHT, 0))
	spine = _pivot("Spine", hips, Vector3(0, 0.06, 0))
	head = _pivot("Head", spine, Vector3(0, 0.56, 0.0))
	eye = _pivot("Eye", head, Vector3(0, 0.1, -0.08))
	weapon_mount = _pivot("WeaponMount", spine, Vector3(0.12, 0.42, -0.04))

	# Pelvis and belt
	_mesh(hips, func(k: MeshKit) -> void:
		k.box(Vector3(0.36, 0.2, 0.24), Vector3(0, -0.02, 0), trousers, 0.06)
		k.box(Vector3(0.38, 0.05, 0.26), Vector3(0, 0.07, 0), leather, 0.015)
		k.box(Vector3(0.1, 0.12, 0.08), Vector3(-0.17, -0.02, 0.06), gear, 0.02)  # dump pouch
		# Parka skirt hanging to mid-thigh
		k.at(Vector3(0, 0.1, 0.0), Vector3(90, 0, 0), Vector3(1.0, 1.0, 0.8)).lathe(PackedVector2Array([Vector2(0.19, 0.0),
			Vector2(0.215, 0.12), Vector2(0.235, 0.3), Vector2(0.225, 0.34)]), jacket, 16, false, false)
		k.reset())

	# Torso: parka, chest rig with magazine pouches, small pack
	_mesh(spine, func(k: MeshKit) -> void:
		k.at(Vector3(0, 0.26, 0), Vector3(-90, 0, 0), Vector3(1.08, 1.06, 0.72))
		k.lathe(PackedVector2Array([Vector2(0.0, -0.29), Vector2(0.17, -0.27), Vector2(0.215, -0.12), Vector2(0.225, 0.08),
			Vector2(0.20, 0.22), Vector2(0.10, 0.29), Vector2(0.0, 0.3)]), jacket, 16)
		k.reset()
		k.box(Vector3(0.34, 0.26, 0.05), Vector3(0, 0.25, -0.14), gear, 0.02)
		for x in [-0.1, 0.0, 0.1]:
			k.box(Vector3(0.085, 0.14, 0.05), Vector3(x, 0.22, -0.17), gear, 0.015)
		k.box(Vector3(0.3, 0.34, 0.14), Vector3(0, 0.30, 0.2), gear, 0.04)
		k.box(Vector3(0.05, 0.42, 0.02), Vector3(0.12, 0.33, 0.13), leather, 0.008)
		k.box(Vector3(0.05, 0.42, 0.02), Vector3(-0.12, 0.33, 0.13), leather, 0.008)
		# Collar / hood base
		k.at(Vector3(0, 0.5, 0.01), Vector3(-90, 0, 0)).lathe(PackedVector2Array([Vector2(0.09, -0.05), Vector2(0.13, -0.02),
			Vector2(0.12, 0.05)]), jacket, 14, false, false)
		k.reset())

	# Head: hood, gas mask with lenses and canister
	_mesh(head, func(k: MeshKit) -> void:
		k.sphere(0.135, Vector3(0, 0.11, 0.02), jacket, 10, 16, Vector3(1.0, 1.12, 1.1))  # hood
		k.sphere(0.11, Vector3(0, 0.09, -0.05), rubber, 10, 16, Vector3(0.95, 1.05, 0.9))  # face piece
		for x in [-0.045, 0.045]:
			k.at(Vector3(x, 0.125, -0.135), Vector3(8, 0, 0)).cylinder(0.026, 0.0, -0.016, rubber, 14, 0.004)
			k.at(Vector3(x, 0.125, -0.15), Vector3(8, 0, 0)).cylinder(0.021, 0.0, -0.004, lens, 14)
		k.at(Vector3(0, 0.035, -0.145), Vector3(25, 0, 0)).cylinder(0.03, 0.0, -0.03, rubber, 14, 0.004)  # valve
		k.at(Vector3(0.05, 0.025, -0.15), Vector3(20, -35, 0)).cylinder(0.04, -0.02, -0.09, gear, 16, 0.006)  # filter
		k.reset())

	# Arms
	var shoulder_r := _pivot("ShoulderR", spine, Vector3(0.2, 0.44, 0.0))
	var shoulder_l := _pivot("ShoulderL", spine, Vector3(-0.2, 0.44, 0.0))
	_arm_r = _arm(shoulder_r, false)
	_arm_l = _arm(shoulder_l, true)

	# Legs
	for side in [&"l", &"r"]:
		var x := -0.1 if side == &"l" else 0.1
		var thigh := _pivot("Thigh_" + side, hips, Vector3(x, -0.04, 0))
		var knee := _pivot("Knee_" + side, thigh, Vector3(0, -THIGH, 0))
		_thigh[side] = thigh
		_knee[side] = knee
		_mesh(thigh, func(k: MeshKit) -> void:
			k.at(Vector3.ZERO, Vector3(90, 0, 0)).lathe(PackedVector2Array([Vector2(0.0, -0.02), Vector2(0.112, 0.02),
				Vector2(0.105, 0.2), Vector2(0.084, THIGH), Vector2(0.0, THIGH + 0.03)]), trousers, 12)
			k.reset()
			k.box(Vector3(0.05, 0.13, 0.11), Vector3(x * 0.95, -0.22, 0.0), trousers, 0.02))  # cargo pocket
		_mesh(knee, func(k: MeshKit) -> void:
			k.at(Vector3.ZERO, Vector3(90, 0, 0)).lathe(PackedVector2Array([Vector2(0.0, -0.02), Vector2(0.086, 0.0),
				Vector2(0.078, 0.2), Vector2(0.07, SHIN - 0.12), Vector2(0.0, SHIN - 0.1)]), trousers, 12)
			k.reset()
			k.box(Vector3(0.12, 0.13, 0.05), Vector3(0, -0.02, -0.075), gear, 0.02)  # knee pad
			k.reset()
			# Boot
			k.box(Vector3(0.11, 0.16, 0.13), Vector3(0, -SHIN + 0.1, 0.0), leather, 0.03)
			k.box(Vector3(0.11, 0.07, 0.27), Vector3(0, -SHIN + 0.035, -0.06), leather, 0.03)
			k.box(Vector3(0.115, 0.025, 0.28), Vector3(0, -SHIN + 0.0, -0.06), rubber, 0.008))


func _pivot(node_name: String, parent: Node3D, offset: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	node.position = offset
	parent.add_child(node)
	return node


## Body meshes are identical for every humanoid with the same materials, so
## they're built once and shared.
static var _mesh_cache: Dictionary = {}


func _mesh(parent: Node3D, build: Callable) -> void:
	var key := "%s|%s|%s" % [parent.name, jacket.resource_path, trousers.resource_path]
	if not _mesh_cache.has(key):
		var kit := MeshKit.new()
		build.call(kit)
		_mesh_cache[key] = kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh_cache[key]
	parent.add_child(mi)


func _arm(shoulder: Node3D, left: bool) -> ArmRig:
	var arm := ArmRig.new()
	arm.upper_length = 0.3
	arm.lower_length = 0.32
	arm.thickness = 1.15
	arm.sleeve_material = jacket
	arm.glove_material = leather
	arm.left = left
	shoulder.add_child(arm)
	return arm


func _hitbox(parent: Node3D, zone: StringName, mult: float, health: HealthComponent, shape: Shape3D, offset: Vector3) -> Hitbox:
	var box := Hitbox.new()
	box.name = "Hitbox_" + zone
	box.zone = zone
	box.damage_multiplier = mult
	box.health = health
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = offset
	box.add_child(cs)
	parent.add_child(box)
	return box


static func _sphere(r: float) -> SphereShape3D:
	var s := SphereShape3D.new()
	s.radius = r
	return s


static func _box(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


static func _capsule(r: float, h: float) -> CapsuleShape3D:
	var s := CapsuleShape3D.new()
	s.radius = r
	s.height = h + r * 2.0
	return s
