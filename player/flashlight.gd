class_name Flashlight
extends SpotLight3D
## Hand torch: a shadowed spot that trails the view a little. Toggle with
## the `flashlight` action. (A projector texture blacked the beam out in
## testing, so the falloff comes from spot_angle_attenuation alone.)
## (No battery: power rules aren't designed yet.)

const ON_SOUND := "res://assets/audio/player/flashlight_on.wav"
const OFF_SOUND := "res://assets/audio/player/flashlight_off.wav"

@export var beam_energy: float = 7.0
@export var beam_range: float = 30.0
@export var beam_angle: float = 28.0
## Where the torch is held, relative to the camera.
@export var hold_offset := Vector3(0.18, -0.16, -0.1)
## How quickly the beam catches up with the view (higher = stiffer).
@export var follow_rate: float = 16.0

var on: bool = false
var _view: Node3D


func _init() -> void:
	name = "Flashlight"
	top_level = true


func setup(view: Node3D) -> void:
	_view = view
	light_color = Color(1.0, 0.94, 0.82)
	light_energy = beam_energy
	spot_range = beam_range
	spot_angle = beam_angle
	spot_attenuation = 0.9
	spot_angle_attenuation = 2.2
	shadow_enabled = true
	shadow_bias = 0.08
	shadow_normal_bias = 2.5
	shadow_blur = 0.6
	light_volumetric_fog_energy = 0.5
	visible = false
	global_transform = _target()


func toggle() -> void:
	on = not on
	visible = on
	Audio.play_2d(load(ON_SOUND if on else OFF_SOUND), &"SFX", -6.0, 0.03)


func _process(delta: float) -> void:
	if _view == null or not is_instance_valid(_view):
		return
	var want := _target()
	var t := 1.0 - exp(-follow_rate * delta)
	var q := global_transform.basis.get_rotation_quaternion().slerp(want.basis.get_rotation_quaternion(), t)
	global_transform = Transform3D(Basis(q), want.origin)


func _target() -> Transform3D:
	var xf := _view.global_transform
	return Transform3D(xf.basis.orthonormalized(), xf * hold_offset)

