class_name Corpse
extends Node3D
## A dead body (the rigged Mannequin) lying where it fell, with a collision box
## so bullets and feet hit it.

enum Pose { FALLEN, SPREAD, KNEELING }

@export var pose: Pose = Pose.FALLEN
var body: NPCBody


func _ready() -> void:
	body = Mannequin.new()
	add_child(body)
	body.pose_dead(pose, hash(global_position))
	var col := StaticBody3D.new()
	col.collision_layer = Layers.WORLD
	col.collision_mask = 0
	col.set_meta(&"surface", &"flesh")
	var shape := BoxShape3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	if pose == Pose.KNEELING:
		shape.size = Vector3(0.5, 1.0, 0.7)
		cs.position = Vector3(0, 0.5, 0)
	else:
		shape.size = Vector3(0.6, 0.3, 1.8)
		cs.position = Vector3(0, 0.15, 0)
	col.add_child(cs)
	add_child(col)
	# Onto the floor (placed from the navmesh, which floats above it).
	var own: Array[RID] = [col.get_rid()]
	Ground.settle.call_deferred(self, 0.4, 1.6, own)
	# A fallen body drapes over whatever it lies on (steps, a kerb); the
	# staged poses (spread out, kneeling against a wall) stay as they are.
	if pose == Pose.FALLEN and body is Mannequin:
		col.queue_free()
		(body as Mannequin).go_limp.call_deferred()
