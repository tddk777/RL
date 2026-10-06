class_name BreakerLever
extends Interactable
## Wall-mounted breaker. Throwing it restores power to a locked exit.

signal pulled

const SOUND := "res://assets/audio/world/breaker.wav"

var record: Dictionary = {}
var _arm: Node3D


func _ready() -> void:
	super()
	prompt = "Throw the breaker"
	_build()
	if record.get("pulled", false):
		enabled = false
		_arm.rotation_degrees.x = 70.0


func interact(by: Node) -> void:
	if not enabled:
		return
	enabled = false
	record["pulled"] = true
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_arm, "rotation_degrees:x", 70.0, 0.35)
	if ResourceLoader.exists(SOUND):
		Audio.play_3d(load(SOUND), global_position, &"World", 0.0, 5.0)
	Events.noise_emitted.emit(global_position, 18.0, by)
	super(by)
	pulled.emit()


func can_interact(by: Node) -> bool:
	return enabled and super(by)


func _build() -> void:
	var k := MeshKit.new()
	var panel: Material = load("res://assets/materials/painted_steel.tres")
	var dark: Material = load("res://assets/materials/gun_metal.tres")
	var yellow: Material = load("res://assets/materials/painted_steel_yellow.tres")
	k.box(Vector3(0.5, 0.7, 0.16), Vector3(0, 0, 0.08), panel, 0.015)
	k.box(Vector3(0.16, 0.12, 0.03), Vector3(0, 0.26, 0.17), yellow, 0.004)  # warning plate
	k.tube_between(Vector3(0, 0.35, 0.08), Vector3(0, 2.0, 0.08), 0.03, dark)  # conduit to the ceiling
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	add_child(mi)
	_arm = Node3D.new()
	_arm.position = Vector3(0.0, -0.05, 0.17)
	_arm.rotation_degrees.x = -50.0
	add_child(_arm)
	var ak := MeshKit.new()
	ak.box(Vector3(0.06, 0.06, 0.04), Vector3.ZERO, dark, 0.01)
	ak.tube_between(Vector3.ZERO, Vector3(0, 0.26, 0), 0.016, dark)
	ak.at(Vector3(0, 0.27, 0), Vector3(0, 90, 0)).cylinder(0.022, -0.07, 0.07, load("res://assets/materials/prop_rubber.tres"), 10)
	var arm_mesh := MeshInstance3D.new()
	arm_mesh.mesh = ak.commit()
	_arm.add_child(arm_mesh)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 0.8, 0.5)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, 0, 0.25)
	add_child(cs)
