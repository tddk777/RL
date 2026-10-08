class_name Ragdoll
extends RefCounted
## Physics body for a skeleton: one capsule per main bone (hips, spine,
## head, upper and lower arms and legs) joined at the bone heads, built from
## the skeleton's rest pose like the editor's "Create Physical Skeleton", so
## any humanoid rig works given its bone names. Off (and colliding with
## nothing) while the character is alive; on death `go_limp()` hands the
## current animated pose to physics and the body falls where it was hit.

## [bone, child bone it reaches to ("" = along its own axis), radius, joint,
## swing / hinge limit (degrees)] for the UAL rig (Quaternius).
const UAL := [
	["DEF-hips", "DEF-spine.002", 0.14, &"root", 0.0],
	["DEF-spine.002", "DEF-neck", 0.15, &"cone", 25.0],
	["DEF-head", "", 0.11, &"cone", 40.0],
	["DEF-upper_arm.L", "DEF-forearm.L", 0.055, &"cone", 70.0],
	["DEF-forearm.L", "DEF-hand.L", 0.045, &"hinge", 120.0],
	["DEF-upper_arm.R", "DEF-forearm.R", 0.055, &"cone", 70.0],
	["DEF-forearm.R", "DEF-hand.R", 0.045, &"hinge", 120.0],
	["DEF-thigh.L", "DEF-shin.L", 0.08, &"cone", 50.0],
	["DEF-shin.L", "DEF-foot.L", 0.06, &"hinge", 120.0],
	["DEF-thigh.R", "DEF-shin.R", 0.08, &"cone", 50.0],
	["DEF-shin.R", "DEF-foot.R", 0.06, &"hinge", 120.0],
]
## Rough mass share of each part (of a ~75 kg body).
const MASS := {&"DEF-hips": 15.0, &"DEF-spine.002": 20.0, &"DEF-head": 5.0}

var simulator: PhysicalBoneSimulator3D
var bones: Dictionary = {}  # StringName -> PhysicalBone3D
var limp: bool = false


static func build(skeleton: Skeleton3D, spec: Array = UAL) -> Ragdoll:
	var r := Ragdoll.new()
	var sim := PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	skeleton.add_child(sim)
	r.simulator = sim
	for part: Array in spec:
		var bone := skeleton.find_bone(part[0])
		if bone < 0:
			continue
		var rest := skeleton.get_bone_global_rest(bone)
		var to: Vector3
		if part[1] == "":
			to = Vector3(0, 0.22, 0)  # head: up its own axis
		else:
			var child := skeleton.find_bone(part[1])
			to = rest.affine_inverse() * skeleton.get_bone_global_rest(child).origin
		var length := maxf(to.length(), 0.05)
		var radius: float = part[2]
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + String(part[0]).replace(".", "_")
		pb.bone_name = part[0]
		# Body halfway down the bone, its -Z toward the child; the joint at
		# the bone's head (where it meets its parent).
		var up := Vector3.UP if not Vector3.UP.cross(to).is_zero_approx() else Vector3.BACK
		var body := Transform3D(Basis.looking_at(to, up), Vector3.ZERO)
		body.origin = body.basis * Vector3(0, 0, -length * 0.5)
		pb.body_offset = body
		pb.joint_offset = Transform3D(Basis.IDENTITY, Vector3(0, 0, length * 0.5))
		match part[3]:
			&"cone":
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
				pb.set(&"joint_constraints/swing_span", part[4])
				pb.set(&"joint_constraints/twist_span", 25.0)
			&"hinge":
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
				pb.set(&"joint_constraints/angular_limit_enabled", true)
				pb.set(&"joint_constraints/angular_limit_upper", 0.0)
				pb.set(&"joint_constraints/angular_limit_lower", -float(part[4]))
			_:
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		pb.mass = MASS.get(StringName(part[0]), 3.0)
		pb.friction = 0.9
		pb.linear_damp = 0.4
		pb.angular_damp = 2.0
		pb.collision_layer = 0
		pb.collision_mask = 0
		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = maxf(length + radius * 0.6, radius * 2.0 + 0.01)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.rotation = Vector3(PI * 0.5, 0, 0)  # capsule height along the body's Z
		pb.add_child(cs)
		sim.add_child(pb)
		r.bones[StringName(part[0])] = pb
	return r


## Physics takes over from the animation: the body keeps its current pose
## and falls, pushed by `impulse` (world space) at `at` if given.
func go_limp(impulse: Vector3 = Vector3.ZERO, at: Vector3 = Vector3.INF) -> void:
	if limp or simulator == null:
		return
	limp = true
	for pb: PhysicalBone3D in bones.values():
		pb.collision_layer = Layers.DEBRIS
		pb.collision_mask = Layers.WORLD
	simulator.physical_bones_start_simulation()
	if impulse == Vector3.ZERO:
		return
	var nearest: PhysicalBone3D = bones.get(&"DEF-spine.002")
	if at != Vector3.INF:
		var best := INF
		for pb: PhysicalBone3D in bones.values():
			var d := pb.global_position.distance_to(at)
			if d < best:
				best = d
				nearest = pb
	if nearest:
		nearest.apply_central_impulse.call_deferred(impulse)
