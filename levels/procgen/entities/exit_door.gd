class_name ExitDoor
extends LevelExit
## A way out of a procedural level, mounted on a wall. Kinds:
##   open    red service door with a beacon above it
##   hidden  plain grey maintenance hatch, no light, easy to miss
##   locked  service door that needs a breaker thrown somewhere nearby

const SOUND_LOCKED := "res://assets/audio/world/door_locked.wav"
const SOUND_UNLOCK := "res://assets/audio/world/door_unlock.wav"

var kind: StringName = &"open"
var unlocked: bool = true
var _indicator: MeshInstance3D
var _indicator_light: OmniLight3D


func setup(record: Dictionary) -> void:
	kind = record.get("kind", &"open")
	unlocked = record.get("unlocked", true)


func _ready() -> void:
	super()
	_build()
	_update_prompt()


func get_prompt() -> String:
	return prompt


func interact(by: Node) -> void:
	if not unlocked:
		if ResourceLoader.exists(SOUND_LOCKED):
			Audio.play_3d(load(SOUND_LOCKED), global_position + Vector3.UP, &"World", -2.0, 3.0)
		return
	super(by)


func unlock() -> void:
	unlocked = true
	if ResourceLoader.exists(SOUND_UNLOCK):
		Audio.play_3d(load(SOUND_UNLOCK), global_position + Vector3.UP, &"World", 0.0, 4.0)
	if _indicator:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 1.0, 0.3)
		mat.emission_energy_multiplier = 4.0
		_indicator.material_override = mat
	if _indicator_light:
		_indicator_light.light_color = Color(0.3, 1.0, 0.35)
	_update_prompt()


func _update_prompt() -> void:
	match kind:
		&"hidden":
			prompt = "Crawl through the maintenance hatch"
		_:
			prompt = "Take the service stairs down" if unlocked else "Locked. No power to the door."


func _build() -> void:
	var hidden := kind == &"hidden"
	var w := 0.95 if hidden else 1.15
	var h := 1.5 if hidden else 2.2
	var bottom := 0.35 if hidden else 0.0
	var k := MeshKit.new()
	var frame: Material = load("res://assets/materials/rusted_metal.tres")
	var leaf: Material = load("res://assets/materials/%s.tres" % ("painted_steel" if hidden else "painted_steel_red"))
	var dark: Material = load("res://assets/materials/gun_metal.tres")
	k.box(Vector3(w, h, 0.05), Vector3(0, bottom + h * 0.5, 0.03), leaf, 0.01)
	for x in [-1.0, 1.0]:
		k.box(Vector3(0.08, h + 0.08, 0.1), Vector3(x * (w * 0.5 + 0.04), bottom + h * 0.5, 0.05), frame, 0.01)
	k.box(Vector3(w + 0.16, 0.08, 0.1), Vector3(0, bottom + h + 0.04, 0.05), frame, 0.01)
	if hidden:
		for i in 4:
			k.box(Vector3(w - 0.25, 0.02, 0.012), Vector3(0, bottom + 0.3 + i * 0.25, 0.06), dark, 0.0)  # vent slats
	else:
		k.box(Vector3(0.05, 0.22, 0.05), Vector3(w * 0.5 - 0.12, 1.05, 0.08), dark, 0.01)  # handle
		k.box(Vector3(w * 0.8, 0.04, 0.04), Vector3(0, 1.0, 0.07), dark, 0.01)  # push bar
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	add_child(mi)
	var shape := BoxShape3D.new()
	shape.size = Vector3(w + 0.2, h, 0.8)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, bottom + h * 0.5, 0.4)
	add_child(cs)
	if hidden:
		return
	var sign := Label3D.new()
	sign.text = "STAIRWELL"
	sign.font_size = 42
	sign.pixel_size = 0.004
	sign.modulate = Color(0.75, 0.72, 0.65)
	sign.outline_size = 0
	sign.position = Vector3(0, h + 0.3, 0.04)
	add_child(sign)
	if kind == &"locked":
		_indicator = MeshInstance3D.new()
		var lamp := SphereMesh.new()
		lamp.radius = 0.04
		lamp.height = 0.06
		_indicator.mesh = lamp
		_indicator.material_override = load("res://assets/materials/lamp_emissive_red.tres")
		_indicator.position = Vector3(w * 0.5 + 0.25, 1.4, 0.06)
		add_child(_indicator)
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.14, 0.22, 0.06)
		box.mesh = bm
		box.material_override = dark
		box.position = Vector3(w * 0.5 + 0.25, 1.35, 0.03)
		add_child(box)
		_indicator_light = OmniLight3D.new()
		_indicator_light.light_color = Color(1.0, 0.15, 0.1)
		_indicator_light.light_energy = 0.5
		_indicator_light.omni_range = 2.5
		_indicator_light.position = Vector3(w * 0.5 + 0.25, 1.4, 0.2)
		add_child(_indicator_light)
		if unlocked:
			unlocked = false
			unlock.call_deferred()
	else:
		var beacon := OmniLight3D.new()
		beacon.light_color = Color(1.0, 0.12, 0.08)
		beacon.light_energy = 1.1
		beacon.omni_range = 5.0
		beacon.position = Vector3(0, h + 0.6, 0.3)
		add_child(beacon)
		var flicker := FlickerLight.new()
		flicker.light = beacon
		flicker.pulse = true
		beacon.add_child(flicker)
		var bulb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.07
		sm.height = 0.08
		bulb.mesh = sm
		bulb.material_override = load("res://assets/materials/lamp_emissive_red.tres")
		bulb.position = Vector3(0, h + 0.6, 0.06)
		add_child(bulb)
