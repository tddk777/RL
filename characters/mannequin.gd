class_name Mannequin
extends NPCBody
## Rigged, animated body: the Quaternius Universal Animation Library
## mannequin (CC0) with its idle, walk, jog, sprint and death clips. On top of
## the clips (PoseHook): the chest pitches toward the aim and both arms are
## solved onto the weapon's Grip_R / Grip_L markers. Hitboxes and the
## scavenger's gear (hood, gas mask, chest rig, pack) ride on the bones.

const MODEL := preload("res://assets/third_party/quaternius_ual/AnimationLibrary_Godot_Standard.glb")
## Ground speeds (m/s) the clips were authored at; playback scales to match.
const WALK_SPEED := 1.25
const JOG_SPEED := 3.4
const SPRINT_SPEED := 5.5
const CROUCH_SPEED := 1.0
## How far the chest twists toward the aim before the hips have to turn.
const MAX_TWIST := deg_to_rad(70.0)
## Weapon pivot (body space): in front of the right shoulder at low ready,
## raised toward the eye when aiming; pistols are pushed out at arm's length.
const MOUNT := Vector3(0.12, 1.36, -0.08)
const MOUNT_AIM := Vector3(0.12, 1.43, -0.1)
const MOUNT_PISTOL := Vector3(0.1, 1.3, -0.22)
const MOUNT_PISTOL_AIM := Vector3(0.05, 1.44, -0.4)

@export var jacket: Material = preload("res://assets/materials/fabric_dark.tres")
@export var joints: Material = preload("res://assets/materials/fabric_dark.tres")
@export var leather: Material = preload("res://assets/materials/leather.tres")
@export var rubber: Material = preload("res://assets/materials/rubber.tres")
@export var lens: Material = preload("res://assets/materials/mask_glass.tres")
@export var gear: Material = preload("res://assets/materials/fabric_canvas.tres")

var skeleton: Skeleton3D
var weapon_mount: Node3D

var _model: Node3D
var _anim: AnimationPlayer
var _hook: PoseHook
var _weapon: Weapon
var _clip: StringName = &""
var _speed: float = 0.0
var _aim_pitch: float = 0.0
var _aim_yaw: float = 0.0
var _twist: float = 0.0
var _crouched: bool = false
var _crouch: float = 0.0
var _backward: bool = false
var _flinch: float = 0.0
var _aim_blend: float = 0.0
var _mount_pitch: float = 0.0
var _chest_pitch: float = 0.0
var _raise: float = 0.0
var _arm_weight: float = 1.0
var _dead: bool = false
var _bones := {}
var _upper_len: float = 0.27
var _lower_len: float = 0.27
var _hips_rest_y: float = 0.92
var _attachments := {}


func _ready() -> void:
	if skeleton == null:
		_build()


# --- API ------------------------------------------------------------------------

func setup(health: HealthComponent) -> Array[Hitbox]:
	if skeleton == null:
		_build()
	var boxes: Array[Hitbox] = []
	boxes.append(_hitbox(&"DEF-head", &"head", 4.0, health, Humanoid._sphere(0.12), Vector3(0, 0.1, 0.01)))
	boxes.append(_hitbox(&"DEF-spine.002", &"torso", 1.0, health, Humanoid._box(Vector3(0.38, 0.42, 0.28)), Vector3(0, 0.1, 0)))
	boxes.append(_hitbox(&"DEF-hips", &"pelvis", 0.9, health, Humanoid._box(Vector3(0.34, 0.2, 0.24)), Vector3(0, 0.05, 0)))
	for side in ["L", "R"]:
		boxes.append(_hitbox(StringName("DEF-thigh." + side), &"leg", 0.65, health, Humanoid._capsule(0.08, 0.36), Vector3(0, 0.2, 0)))
		boxes.append(_hitbox(StringName("DEF-shin." + side), &"leg", 0.55, health, Humanoid._capsule(0.065, 0.36), Vector3(0, 0.21, 0)))
	return boxes


func hold_weapon(weapon: Weapon) -> void:
	_weapon = weapon
	weapon_mount.add_child(weapon)


func set_motion(speed: float, _run: bool) -> void:
	_speed = speed


func set_aim(target: Vector3, aiming: bool) -> void:
	var local := global_transform.affine_inverse() * target
	var from := global_transform.affine_inverse() * eye.global_position
	var d := local - from
	_aim_pitch = atan2(d.y, Vector2(d.x, d.z).length())
	# The body faces -Z; the chest and gun twist toward the target.
	_aim_yaw = clampf(atan2(-d.x, -d.z), -MAX_TWIST, MAX_TWIST) if aiming else 0.0
	_aim_blend = 1.0 if aiming else 0.0


func set_crouch(crouched: bool) -> void:
	_crouched = crouched


func set_backward(backward: bool) -> void:
	_backward = backward


func flinch(head: bool) -> void:
	if _dead or _flinch > 0.0:
		return
	_flinch = 0.42
	_clip = &""
	_anim.speed_scale = 1.0
	_anim.play(&"Hit_Head" if head else &"Hit_Chest", 0.06)


func die(_direction: Vector3) -> void:
	_dead = true
	_aim_blend = 0.0
	_anim.speed_scale = 1.0
	_play(&"Death01", 0.12)
	create_tween().tween_property(self, "_arm_weight", 0.0, 0.3)
	if _weapon:
		# The gun goes down with the right hand.
		_weapon.reparent(_attach(&"DEF-hand.R"), true)


func pose_dead(pose: int, variant: int = 0) -> void:
	if skeleton == null:
		_build()
	_dead = true
	_arm_weight = 0.0
	var clip := &"Fixing_Kneeling" if pose == 2 else &"Death01"
	_anim.play(clip)
	_anim.seek(2.0 if pose == 2 else _anim.get_animation(clip).length, true)
	_anim.active = false
	# Centre the lying body on the node (the clip falls backward from the feet).
	_model.position.z = -0.6 if pose != 2 else 0.1
	_model.rotation.y = PI + (0.0 if pose != 1 else deg_to_rad(float(variant % 30) - 15.0))
	set_process(false)


# --- Animation ------------------------------------------------------------------

func _process(delta: float) -> void:
	if _dead:
		return
	_crouch = move_toward(_crouch, 1.0 if _crouched else 0.0, delta * 4.0)
	if _flinch > 0.0:
		_flinch -= delta
	else:
		var want := &"Crouch_Idle" if _crouched else &"Idle"
		var rate := 1.0
		if _speed > 0.2:
			if _crouched:
				want = &"Crouch_Fwd"
				rate = _speed / CROUCH_SPEED
			elif _speed < 2.4:
				want = &"Walk"
				rate = _speed / WALK_SPEED
			elif _speed < 4.8:
				want = &"Jog_Fwd"
				rate = _speed / JOG_SPEED
			else:
				want = &"Sprint"
				rate = _speed / SPRINT_SPEED
		_play(want, 0.25)
		# Backing off: the same clip played in reverse.
		_anim.speed_scale = clampf(rate, 0.6, 1.5) * (-1.0 if _backward and _speed > 0.2 else 1.0)
	# Weapon: low ready unless aiming; aiming follows the target pitch.
	var t := clampf(10.0 * delta, 0.0, 1.0)
	_mount_pitch = lerp_angle(_mount_pitch, lerpf(deg_to_rad(-32.0), _aim_pitch, _aim_blend), t)
	_chest_pitch = lerp_angle(_chest_pitch, _aim_pitch * _aim_blend, t)
	_twist = lerp_angle(_twist, _aim_yaw, t)
	_raise = lerpf(_raise, _aim_blend, t)
	var pistol := _weapon != null and _weapon.data.length < 0.5
	var mount := (MOUNT_PISTOL.lerp(MOUNT_PISTOL_AIM, _raise)) if pistol else MOUNT.lerp(MOUNT_AIM, _raise)
	var bob := skeleton.get_bone_global_pose(_bones[&"DEF-hips"]).origin.y - _hips_rest_y
	# Crouched, the shoulders come down with the hips.
	weapon_mount.position = Basis(Vector3.UP, _twist) * mount + Vector3(0, bob * lerpf(0.6, 1.0, _crouch), 0)
	weapon_mount.rotation = Vector3(_mount_pitch, _twist, 0.0)


func _play(clip: StringName, blend: float) -> void:
	if clip == _clip:
		return
	_clip = clip
	_anim.play(clip, blend)


## Procedural layer after the clip (skeleton space).
func _pose(skel: Skeleton3D, _delta: float) -> void:
	var to_skel := skel.global_transform.affine_inverse()
	var right := (to_skel.basis * global_basis.x).normalized()
	var up_axis := (to_skel.basis * global_basis.y).normalized()
	# Chest and head follow the aim (the spine takes 60 %, the neck the rest).
	if not _dead:
		for bone_name: StringName in [&"DEF-spine.002", &"DEF-spine.003", &"DEF-neck"]:
			var b: int = _bones[bone_name]
			var g := skel.get_bone_global_pose(b)
			var share := 0.4 if bone_name == &"DEF-neck" else 0.3
			g.basis = Basis(up_axis, _twist * share) * Basis(right, _chest_pitch * share) * g.basis
			skel.set_bone_global_pose(b, g)
	if _weapon == null or _weapon.model == null or _arm_weight <= 0.001:
		return
	var m := _weapon.model
	var gun := (to_skel.basis * m.global_basis).orthonormalized()
	var xg := gun.x
	var yg := gun.y
	var zg := gun.z
	var down := to_skel.basis * -global_basis.y
	var side := to_skel.basis * global_basis.x
	var back := to_skel.basis * global_basis.z
	if m.grip_r:
		var fingers := (-zg * 0.75 - yg * 0.65).normalized()
		_solve_arm(skel, "R", to_skel * m.grip_r.global_position, _hand_basis(xg, fingers),
			down * 0.6 + side * 0.45 + back * 0.25)
	if m.grip_l:
		var target := m.grip_l.global_position
		if _weapon.busy_kind() == &"reload" and m.magazine and m.magazine.visible:
			target = m.magazine.global_position
		var basis: Basis
		if _weapon.data.length < 0.5:  # pistol: cup the right hand
			basis = _hand_basis(xg, (-zg * 0.75 - yg * 0.65).normalized())
		else:  # rifle: palm up under the handguard, fingers round it
			basis = _hand_basis(yg, (-zg + xg * 0.7).normalized())
		_solve_arm(skel, "L", to_skel * target, basis, down * 0.6 - side * 0.5 + back * 0.1)


## Hand bone basis from the palm axis (bone X) and the finger direction (bone Y).
static func _hand_basis(x_axis: Vector3, fingers: Vector3) -> Basis:
	var x := (x_axis - fingers * x_axis.dot(fingers)).normalized()
	return Basis(x, fingers, x.cross(fingers))


func _solve_arm(skel: Skeleton3D, side: String, wrist: Vector3, hand: Basis, pole_dir: Vector3) -> void:
	var up: int = _bones[StringName("DEF-upper_arm." + side)]
	var fore: int = _bones[StringName("DEF-forearm." + side)]
	var hb: int = _bones[StringName("DEF-hand." + side)]
	var w := _arm_weight
	var gu := skel.get_bone_global_pose(up)
	var shoulder := gu.origin
	var elbow := IK.two_bone(shoulder, wrist, shoulder + pole_dir, _upper_len, _lower_len)
	skel.set_bone_global_pose(up, gu.interpolate_with(Transform3D(_aim_y(gu.basis, elbow - shoulder), shoulder), w))
	var gf := skel.get_bone_global_pose(fore)
	var fb := _aim_y(gf.basis, wrist - gf.origin)
	# Share the hand's roll with the forearm so the wrist doesn't wring.
	var y := fb.y.normalized()
	var hz := hand.z - y * hand.z.dot(y)
	if hz.length() > 0.001:
		fb = Basis(y, fb.z.signed_angle_to(hz, y) * 0.5) * fb
	skel.set_bone_global_pose(fore, gf.interpolate_with(Transform3D(fb, gf.origin), w))
	var gh := skel.get_bone_global_pose(hb)
	skel.set_bone_global_pose(hb, gh.interpolate_with(Transform3D(hand, gh.origin), w))


static func _aim_y(b: Basis, dir: Vector3) -> Basis:
	if dir.length() < 0.0001:
		return b
	return Basis(Quaternion(b.y.normalized(), dir.normalized())) * b


# --- Construction ----------------------------------------------------------------

func _build() -> void:
	_model = MODEL.instantiate() as Node3D
	_model.name = "Model"
	_model.rotation.y = PI  # the mannequin faces +Z; bodies face -Z
	add_child(_model)
	skeleton = _model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_anim = _model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for i in skeleton.get_bone_count():
		_bones[StringName(skeleton.get_bone_name(i))] = i
	_upper_len = skeleton.get_bone_global_rest(_bones[&"DEF-forearm.R"]).origin.distance_to(
		skeleton.get_bone_global_rest(_bones[&"DEF-upper_arm.R"]).origin)
	_lower_len = skeleton.get_bone_global_rest(_bones[&"DEF-hand.R"]).origin.distance_to(
		skeleton.get_bone_global_rest(_bones[&"DEF-forearm.R"]).origin)
	_hips_rest_y = skeleton.get_bone_global_rest(_bones[&"DEF-hips"]).origin.y
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var joint := mesh.surface_get_material(s) != null and mesh.surface_get_material(s).resource_name.contains("Joint")
			(mi as MeshInstance3D).set_surface_override_material(s, joints if joint else jacket)
	_hook = PoseHook.new()
	_hook.name = "PoseHook"
	_hook.apply = _pose
	skeleton.add_child(_hook)
	weapon_mount = Node3D.new()
	weapon_mount.name = "WeaponMount"
	weapon_mount.position = MOUNT
	add_child(weapon_mount)
	eye = Node3D.new()
	eye.name = "Eye"
	eye.position = Vector3(0, 0.1, 0.09)  # head bone space: +Z is the face
	_attach(&"DEF-head").add_child(eye)
	_gear()
	_play(&"Idle", 0.0)
	_anim.seek(randf() * _anim.get_animation(&"Idle").length, true)


func _attach(bone: StringName) -> BoneAttachment3D:
	if _attachments.has(bone):
		return _attachments[bone]
	var a := BoneAttachment3D.new()
	a.name = "At_" + String(bone).replace(".", "_")
	a.bone_name = bone
	skeleton.add_child(a)
	_attachments[bone] = a
	return a


func _hitbox(bone: StringName, zone: StringName, mult: float, health: HealthComponent, shape: Shape3D, offset: Vector3) -> Hitbox:
	var box := Hitbox.new()
	box.name = "Hitbox_" + zone
	box.zone = zone
	box.damage_multiplier = mult
	box.health = health
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = offset
	box.add_child(cs)
	_attach(bone).add_child(box)
	return box


## Hood, gas mask, chest rig and pack (built once, shared by every mannequin).
static var _gear_cache: Dictionary = {}


func _gear() -> void:
	var key := "%s|%s" % [jacket.resource_path, gear.resource_path]
	if not _gear_cache.has(key):
		var head := MeshKit.new()
		head.sphere(0.128, Vector3(0, 0.12, 0.015), jacket, 10, 16, Vector3(1.0, 1.1, 1.1))  # hood
		head.sphere(0.1, Vector3(0, 0.09, -0.06), rubber, 10, 16, Vector3(0.95, 1.05, 0.9))  # face piece
		for x in [-0.042, 0.042]:
			head.at(Vector3(x, 0.12, -0.135), Vector3(8, 0, 0)).cylinder(0.024, 0.0, -0.016, rubber, 14, 0.004)
			head.at(Vector3(x, 0.12, -0.15), Vector3(8, 0, 0)).cylinder(0.019, 0.0, -0.004, lens, 14)
		head.at(Vector3(0, 0.035, -0.145), Vector3(25, 0, 0)).cylinder(0.028, 0.0, -0.03, rubber, 14, 0.004)  # valve
		head.at(Vector3(0.05, 0.03, -0.145), Vector3(20, -35, 0)).cylinder(0.038, -0.02, -0.085, gear, 16, 0.006)  # filter
		head.reset()
		var chest := MeshKit.new()
		chest.box(Vector3(0.3, 0.24, 0.04), Vector3(0, -0.07, -0.145), gear, 0.015)
		for x in [-0.09, 0.0, 0.09]:
			chest.box(Vector3(0.08, 0.13, 0.045), Vector3(x, -0.1, -0.175), gear, 0.012)
		chest.box(Vector3(0.28, 0.32, 0.13), Vector3(0, -0.02, 0.22), gear, 0.035)  # pack
		for x in [-0.1, 0.1]:
			chest.box(Vector3(0.045, 0.05, 0.3), Vector3(x, 0.13, 0.02), leather, 0.01)  # straps over the shoulders
		_gear_cache[key] = [head.commit(), chest.commit()]
	var meshes: Array = _gear_cache[key]
	var bones: Array[StringName] = [&"DEF-head", &"DEF-spine.003"]
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[i]
		mi.rotation.y = PI  # authored facing -Z like the procedural body
		_attach(bones[i]).add_child(mi)
