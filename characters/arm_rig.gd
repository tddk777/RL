class_name ArmRig
extends Node3D
## One procedural arm (sleeved upper arm, forearm, gloved hand) solved with
## two-bone IK from this node's position (the shoulder) to a target. Used for
## both the first-person view arms and NPC bodies.

@export var upper_length: float = 0.30
@export var lower_length: float = 0.27
@export var thickness: float = 1.0
@export var sleeve_material: Material
@export var glove_material: Material
## Mirror for left arms (affects the hand shape only).
@export var left: bool = false

var _upper: Node3D
var _lower: Node3D
var _hand: Node3D


func _ready() -> void:
	_build()


## Places the arm so the hand reaches `target` (global), elbow toward `pole`,
## palm facing along `hand_forward`.
func solve(target: Vector3, pole: Vector3, hand_forward := Vector3.ZERO) -> void:
	var shoulder := global_position
	var elbow := IK.two_bone(shoulder, target, pole, upper_length, lower_length)
	var wrist := elbow + (target - elbow).normalized() * lower_length
	_aim(_upper, shoulder, elbow, pole)
	_aim(_lower, elbow, wrist, pole)
	var forward := hand_forward if hand_forward.length() > 0.001 else (wrist - elbow)
	_aim(_hand, wrist, wrist + forward, pole)


func _aim(node: Node3D, from: Vector3, to: Vector3, pole: Vector3) -> void:
	var dir := to - from
	if dir.length() < 0.0001:
		return
	var up := (pole - from).normalized()
	if absf(up.dot(dir.normalized())) > 0.98:
		up = Vector3.UP
	node.global_transform = Transform3D(Basis.looking_at(dir, up), from)


func _build() -> void:
	var t := thickness
	_upper = _segment("Upper", func(kit: MeshKit) -> void:
		kit.lathe(PackedVector2Array([Vector2(0.0, 0.02), Vector2(0.052 * t, 0.0), Vector2(0.056 * t, -0.08),
			Vector2(0.046 * t, -upper_length + 0.02), Vector2(0.0, -upper_length - 0.03)]), sleeve_material, 12))
	_lower = _segment("Lower", func(kit: MeshKit) -> void:
		kit.lathe(PackedVector2Array([Vector2(0.0, 0.03), Vector2(0.046 * t, 0.0), Vector2(0.043 * t, -0.12),
			Vector2(0.036 * t, -lower_length + 0.035), Vector2(0.040 * t, -lower_length + 0.02),
			Vector2(0.040 * t, -lower_length + 0.005), Vector2(0.0, -lower_length)]), sleeve_material, 12))
	_hand = _segment("Hand", func(kit: MeshKit) -> void:
		var side := -1.0 if left else 1.0
		kit.box(Vector3(0.082, 0.032, 0.09), Vector3(0, 0, -0.04), glove_material, 0.012)  # palm
		kit.box(Vector3(0.08, 0.026, 0.055), Vector3(0, -0.012, -0.095), glove_material, 0.011)  # curled fingers
		kit.box(Vector3(0.024, 0.024, 0.06), Vector3(side * 0.045, 0.004, -0.06), glove_material, 0.009)  # thumb
		kit.cylinder(0.034 * t, 0.012, -0.012, glove_material, 10, 0.006))  # cuff


static var _mesh_cache: Dictionary = {}


func _segment(segment_name: String, build: Callable) -> Node3D:
	var node := Node3D.new()
	node.name = segment_name
	node.top_level = true
	add_child(node)
	var key := "%s|%s|%s|%s|%s|%s|%s" % [segment_name, upper_length, lower_length, thickness, left,
		sleeve_material.resource_path if sleeve_material else "", glove_material.resource_path if glove_material else ""]
	if not _mesh_cache.has(key):
		var kit := MeshKit.new()
		build.call(kit)
		_mesh_cache[key] = kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh_cache[key]
	node.add_child(mi)
	return node


func set_shadow_casting(mode: GeometryInstance3D.ShadowCastingSetting) -> void:
	for seg in [_upper, _lower, _hand]:
		for child in seg.get_children():
			if child is GeometryInstance3D:
				(child as GeometryInstance3D).cast_shadow = mode
