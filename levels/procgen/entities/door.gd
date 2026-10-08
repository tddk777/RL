class_name Door
extends Node3D
## A door still on its hinges. The player opens and closes it (interact);
## an NPC walking up to a closed or ajar one shoves it open away from
## itself. Either way the hinge squeals and the noise carries (AI hearing).
## Closed, it stops bullets, sight and walking like a wall.
##
## The node sits at the bottom of the hinge: local +X runs along the doorway
## to the latch side, +Z and -Z are the two rooms. The leaf turns about Y:
## positive angles swing it into -Z.

const OPEN_SOUNDS := ["res://assets/audio/doors/open_1.wav", "res://assets/audio/doors/open_2.wav",
	"res://assets/audio/doors/open_3.wav"]
const CLOSE_SOUNDS := ["res://assets/audio/doors/close_1.wav", "res://assets/audio/doors/close_2.wav"]
const OPEN_ANGLE := 95.0
const THICK := 0.05

var width: float = 0.9
var height: float = 2.0
var material: Material
## Starting angle in degrees (0 = shut).
var angle: float = 0.0

var _pivot: Node3D
var _leaf: AnimatableBody3D
var _tween: Tween


func _ready() -> void:
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	_pivot.rotation.y = deg_to_rad(angle)
	_leaf = AnimatableBody3D.new()
	_leaf.name = "Leaf"
	_leaf.collision_layer = Layers.WORLD
	_leaf.collision_mask = 0
	_leaf.set_meta(&"surface", &"wood" if material and material.resource_path.contains("wood") else &"metal")
	_pivot.add_child(_leaf)
	var size := Vector3(width - 0.04, height - 0.03, THICK)
	var centre := Vector3(width * 0.5, height * 0.5 + 0.01, 0.0)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = centre
	_leaf.add_child(cs)
	_build_mesh(size, centre)
	var handle := DoorHandle.new()
	handle.door = self
	var hs := CollisionShape3D.new()
	var hbox := BoxShape3D.new()
	hbox.size = size + Vector3(0.0, 0.0, 0.12)
	hs.shape = hbox
	hs.position = centre
	handle.add_child(hs)
	_leaf.add_child(handle)
	# NPCs coming through: a zone either side of the doorway.
	var zone := Area3D.new()
	zone.name = "Approach"
	zone.collision_layer = 0
	zone.collision_mask = Layers.NPC
	var zs := CollisionShape3D.new()
	var zbox := BoxShape3D.new()
	zbox.size = Vector3(width, 1.6, 2.6)
	zs.shape = zbox
	zs.position = Vector3(width * 0.5, 0.9, 0.0)
	zone.add_child(zs)
	add_child(zone)
	zone.body_entered.connect(_on_approach)


func is_open() -> bool:
	return absf(rad_to_deg(_pivot.rotation.y)) > 60.0


## Swing open away from `by` (or shut, if open and the player asked).
func toggle(by: Node3D) -> void:
	if is_open():
		_swing(0.0, by)
	else:
		_swing(_away_from(by), by)


func open_for(by: Node3D) -> void:
	if not is_open():
		_swing(_away_from(by), by)


func _away_from(by: Node3D) -> float:
	if by == null:
		return OPEN_ANGLE
	var local := global_transform.affine_inverse() * by.global_position
	return OPEN_ANGLE if local.z >= 0.0 else -OPEN_ANGLE


func _swing(to_deg: float, by: Node3D) -> void:
	if _tween and _tween.is_running():
		return
	var closing := absf(to_deg) < 1.0
	var from := rad_to_deg(_pivot.rotation.y)
	var t := clampf(absf(to_deg - from) / OPEN_ANGLE, 0.3, 1.0) * (0.45 if closing else 0.75)
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN if closing else Tween.EASE_OUT)
	_tween.tween_property(_pivot, "rotation:y", deg_to_rad(to_deg), t)
	var list: Array = CLOSE_SOUNDS if closing else OPEN_SOUNDS
	var path: String = list.pick_random()
	var mid := global_position + global_basis.x * (width * 0.5) + Vector3.UP * 1.2
	if ResourceLoader.exists(path):
		if closing:
			get_tree().create_timer(t * 0.9).timeout.connect(func() -> void:
				Audio.play_3d(load(path), mid, &"World", -3.0, 4.0, 0.05))
		else:
			Audio.play_3d(load(path), mid, &"World", -5.0, 3.5, 0.05)
	Events.noise_emitted.emit(mid, 16.0 if closing else 10.0, by)


func _on_approach(body: Node3D) -> void:
	if body is NPC and (body as NPC).alive:
		open_for(body)


func _build_mesh(size: Vector3, centre: Vector3) -> void:
	var k := MeshKit.new()
	var mat := material if material else load("res://assets/materials/painted_steel.tres") as Material
	var steel := load("res://assets/materials/gun_metal.tres") as Material
	k.box(size, centre, mat, 0.004)
	# Handle and its plate on both faces, on the latch side.
	for side: float in [1.0, -1.0]:
		var z := side * (THICK * 0.5 + 0.004)
		k.box(Vector3(0.05, 0.2, 0.008), Vector3(width - 0.11, 1.0, z), steel, 0.002)
		k.box(Vector3(0.12, 0.022, 0.022), Vector3(width - 0.15, 1.04, z + side * 0.03), steel, 0.006)
	# Three hinges on the hinge edge.
	for y: float in [0.25, height * 0.5, height - 0.3]:
		k.box(Vector3(0.03, 0.12, 0.06), Vector3(0.0, y, 0.0), steel, 0.004)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	_leaf.add_child(mi)


## The leaf's interact zone: open / close.
class DoorHandle:
	extends Interactable
	var door: Door

	func get_prompt() -> String:
		return "Close the door" if door.is_open() else "Open the door"

	func interact(by: Node) -> void:
		door.toggle(by as Node3D)
		super(by)
