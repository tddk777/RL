class_name Leak
extends Node3D
## A pipe dripping onto the floor: falling drops and the occasional drip sound.

const SOUNDS := ["res://assets/audio/ambience/drip_1.wav", "res://assets/audio/ambience/drip_2.wav",
	"res://assets/audio/ambience/drip_3.wav"]

var _timer: float = 0.0
var _streams: Array[AudioStream] = []


func setup(origin: Vector3, floor_y: float) -> void:
	global_position = origin
	var drops := CPUParticles3D.new()
	drops.amount = 4
	drops.lifetime = sqrt(2.0 * maxf(origin.y - floor_y, 0.5) / 9.8)
	drops.direction = Vector3.DOWN
	drops.spread = 2.0
	drops.initial_velocity_min = 0.0
	drops.initial_velocity_max = 0.2
	drops.gravity = Vector3(0, -9.8, 0)
	drops.scale_amount_min = 0.6
	var quad := QuadMesh.new()
	quad.size = Vector2(0.012, 0.035)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.75, 0.8, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.roughness = 0.05
	mat.metallic = 0.3
	quad.material = mat
	drops.mesh = quad
	drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(drops)
	for path: String in SOUNDS:
		if ResourceLoader.exists(path):
			_streams.append(load(path))
	_timer = randf_range(0.5, 3.0)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0 and not _streams.is_empty():
		_timer = randf_range(1.2, 3.5)
		var listener := get_viewport().get_camera_3d()
		if listener and listener.global_position.distance_to(global_position) < 18.0:
			Audio.play_3d(_streams.pick_random(), global_position + Vector3.DOWN * 2.0, &"World", -14.0, 3.0, 0.15)
