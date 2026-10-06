class_name OddContainer
extends Interactable
## A padlocked wire-mesh cage. Inside, on a steel stand, sits a small sphere
## that takes in all light: no highlights, no shading, just absence. It hums.

var _object: MeshInstance3D


func _ready() -> void:
	super()
	prompt = "It's padlocked."
	var k := MeshKit.new()
	var grate: Material = load("res://assets/materials/steel_grate.tres")
	var frame: Material = load("res://assets/materials/rusted_metal.tres")
	var steel: Material = load("res://assets/materials/gun_metal.tres")
	var w := 0.9
	var h := 1.4
	var dpt := 0.7
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			k.box(Vector3(0.04, h, 0.04), Vector3(x * w * 0.5, h * 0.5, z * dpt * 0.5), frame, 0.005)
	for y in [0.02, h]:
		k.box(Vector3(w, 0.04, dpt), Vector3(0, y, 0), frame, 0.005)
	k.box(Vector3(w, h, 0.01), Vector3(0, h * 0.5, -dpt * 0.5), grate)
	k.box(Vector3(w, h, 0.01), Vector3(0, h * 0.5, dpt * 0.5), grate)
	k.box(Vector3(0.01, h, dpt), Vector3(-w * 0.5, h * 0.5, 0), grate)
	k.box(Vector3(0.01, h, dpt), Vector3(w * 0.5, h * 0.5, 0), grate)
	k.box(Vector3(0.07, 0.09, 0.03), Vector3(w * 0.3, 0.75, dpt * 0.5 + 0.03), steel, 0.01)  # padlock
	k.tube_between(Vector3(0, 0.04, 0), Vector3(0, 0.62, 0), 0.03, steel)  # stand
	k.box(Vector3(0.18, 0.02, 0.18), Vector3(0, 0.63, 0), steel, 0.004)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	add_child(mi)
	_object = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.085
	sphere.height = 0.17
	_object.mesh = sphere
	var void_mat := StandardMaterial3D.new()
	void_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	void_mat.albedo_color = Color(0, 0, 0)
	void_mat.disable_receive_shadows = true
	_object.material_override = void_mat
	_object.position = Vector3(0, 0.74, 0)
	_object.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_object)
	var hum := AudioStreamPlayer3D.new()
	hum.stream = load("res://assets/audio/ambience/fluorescent_buzz_loop.wav")
	hum.pitch_scale = 0.42
	hum.volume_db = -16.0
	hum.unit_size = 1.2
	hum.max_distance = 7.0
	hum.bus = &"World"
	hum.autoplay = true
	hum.position = _object.position
	add_child(hum)
	var shape := BoxShape3D.new()
	shape.size = Vector3(w, h, dpt)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, h * 0.5, 0)
	add_child(cs)
	var body := StaticBody3D.new()
	body.set_meta(&"surface", &"metal")
	var bcs := CollisionShape3D.new()
	bcs.shape = shape
	bcs.position = Vector3(0, h * 0.5, 0)
	body.add_child(bcs)
	add_child(body)


func _process(delta: float) -> void:
	# Barely perceptible drift, as if it isn't quite resting on the stand.
	_object.position.y = 0.74 + sin(Time.get_ticks_msec() * 0.0007) * 0.004
