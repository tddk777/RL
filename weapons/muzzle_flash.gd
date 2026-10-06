class_name MuzzleFlash
extends Node3D
## Brief flash at the muzzle: crossed side-view quads, a front burst and a
## short-lived light. Parented to the WeaponModel's Muzzle marker.

const SIDE_TEXTURE := "res://assets/textures/fx/muzzle_flash_side.png"
const FRONT_TEXTURE := "res://assets/textures/fx/muzzle_flash_front.png"
const DURATION := 0.045

static var _side_mat: StandardMaterial3D
static var _front_mat: StandardMaterial3D

var _quads: Array[MeshInstance3D] = []
var _light: OmniLight3D
var _timer: float = 0.0


func _ready() -> void:
	if _side_mat == null:
		_side_mat = _make_material(SIDE_TEXTURE)
		_front_mat = _make_material(FRONT_TEXTURE)
	for i in 2:
		var quad := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(0.16, 0.08)
		mesh.center_offset = Vector3(0.08, 0, 0)
		quad.mesh = mesh
		quad.material_override = _side_mat
		quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Quad lies in XY; rotate so its X axis runs down the barrel (-Z).
		quad.rotation = Vector3(0.0, PI * 0.5, PI * 0.5 * i)
		add_child(quad)
		_quads.append(quad)
	var front := MeshInstance3D.new()
	var front_mesh := QuadMesh.new()
	front_mesh.size = Vector2(0.09, 0.09)
	front.mesh = front_mesh
	front.material_override = _front_mat
	front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	front.position = Vector3(0, 0, -0.01)
	add_child(front)
	_quads.append(front)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.72, 0.4)
	_light.omni_range = 4.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, 0, -0.05)
	add_child(_light)
	visible = false
	set_process(false)


func flash(scale_factor: float = 1.0) -> void:
	visible = true
	_timer = DURATION
	rotation.z = randf() * TAU
	scale = Vector3.ONE * scale_factor * randf_range(0.8, 1.25)
	_light.light_energy = 2.5 * scale_factor
	set_process(true)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		visible = false
		_light.light_energy = 0.0
		set_process(false)


static func _make_material(path: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.85, 0.6) * 2.0
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path)
	return mat
