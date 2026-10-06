extends Node
## Spawns short-lived visual effects: impact particles, bullet-hole decals,
## ejected casings and tracers. Everything is parented under Game.world so a
## level unload cleans it up. Looks are driven by SurfaceData resources.

const MAX_DECALS := 96
const MAX_CASINGS := 40
const SPARK_TEXTURE := "res://assets/textures/fx/spark.png"
const SMOKE_TEXTURE := "res://assets/textures/fx/smoke_puff.png"

var _decals: Array[Decal] = []
var _casings: Array[RigidBody3D] = []
var _particle_materials: Dictionary = {}  # texture path or "" -> StandardMaterial3D
var _casing_mesh: CylinderMesh
var _casing_shape: CylinderShape3D
var _tracer_mesh: CylinderMesh


func _ready() -> void:
	_casing_mesh = CylinderMesh.new()
	_casing_mesh.top_radius = 0.0045
	_casing_mesh.bottom_radius = 0.0055
	_casing_mesh.height = 0.039
	_casing_mesh.radial_segments = 8
	_casing_mesh.rings = 1
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.78, 0.6, 0.3)
	brass.metallic = 1.0
	brass.roughness = 0.35
	_casing_mesh.material = brass
	_casing_shape = CylinderShape3D.new()
	_casing_shape.radius = 0.005
	_casing_shape.height = 0.039
	_tracer_mesh = CylinderMesh.new()
	_tracer_mesh.top_radius = 0.004
	_tracer_mesh.bottom_radius = 0.004
	_tracer_mesh.height = 1.0
	_tracer_mesh.radial_segments = 4
	_tracer_mesh.rings = 1


func container() -> Node:
	var world: Node = Game.world if is_instance_valid(Game.world) else null
	return world if world else get_tree().current_scene


func clear() -> void:
	_decals.clear()
	_casings.clear()


func impact(surface_id: StringName, position: Vector3, normal: Vector3, direction: Vector3, collider: Node = null) -> void:
	var surface := Registry.surface(surface_id)
	if surface == null:
		return
	var sound := Audio.pick(surface.impact_sounds)
	if surface.ricochet_chance > 0.0 and randf() < surface.ricochet_chance:
		sound = Audio.pick(surface.ricochet_sounds) if not surface.ricochet_sounds.is_empty() else sound
	Audio.play_3d(sound, position, &"World", -3.0, 5.0, 0.12)
	_spawn_particles(surface, position, normal, direction)
	if not surface.decal_textures.is_empty():
		_spawn_decal(surface, position, normal, collider)


## Throws a spent casing from `from` (the ejection port marker).
func eject_casing(from: Node3D, side_velocity: Vector3, scale: float = 1.0, surface_hint: SurfaceData = null) -> void:
	var parent := container()
	if parent == null:
		return
	var body: RigidBody3D
	if _casings.size() >= MAX_CASINGS:
		body = _casings.pop_front()
		if not is_instance_valid(body):
			body = null
	if body == null:
		body = _make_casing()
		parent.add_child(body)
	_casings.append(body)
	body.set_meta(&"sounded", 0)
	body.global_transform = from.global_transform
	body.scale = Vector3.ONE * scale
	body.linear_velocity = side_velocity
	body.angular_velocity = Vector3(randf_range(-20, 20), randf_range(-20, 20), randf_range(-20, 20))
	body.sleeping = false


## A thin glowing streak. Returned node's -Z axis points along the flight
## path; Ballistics scales its Z to the distance covered each tick.
func create_tracer(color: Color) -> Node3D:
	var pivot := Node3D.new()
	var tracer := MeshInstance3D.new()
	tracer.mesh = _tracer_mesh
	tracer.rotation_degrees.x = 90.0  # cylinder runs along Y; lay it along Z
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 6.0
	tracer.material_override = mat
	pivot.add_child(tracer)
	container().add_child(pivot)
	return pivot


func _make_casing() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = Layers.DEBRIS
	body.collision_mask = Layers.WORLD
	body.mass = 0.012
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 1
	var mesh := MeshInstance3D.new()
	mesh.mesh = _casing_mesh
	mesh.rotation_degrees.x = 90.0
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	shape.shape = _casing_shape
	shape.rotation_degrees.x = 90.0
	body.add_child(shape)
	body.body_entered.connect(_on_casing_contact.bind(body))
	return body


func _on_casing_contact(other: Node, casing: RigidBody3D) -> void:
	var count: int = casing.get_meta(&"sounded", 0)
	if count >= 2 or casing.linear_velocity.length() < 0.4:
		return
	casing.set_meta(&"sounded", count + 1)
	var surface := Registry.surface(Surface.of(other))
	if surface:
		Audio.play_3d(Audio.pick(surface.casing_sounds), casing.global_position, &"World", -10.0 - count * 6.0, 2.0, 0.15)


func _spawn_particles(surface: SurfaceData, position: Vector3, normal: Vector3, direction: Vector3) -> void:
	var parent := container()
	if parent == null:
		return
	var puff := _make_emitter(surface.particle_texture, surface.particle_color, surface.particle_amount,
		surface.particle_size, surface.particle_speed, 0.9, 35.0)
	parent.add_child(puff)
	_orient_emitter(puff, position, normal.lerp(-direction, 0.25).normalized())
	puff.emitting = true
	if surface.sparks:
		var spark_tex: Texture2D = load(SPARK_TEXTURE) if ResourceLoader.exists(SPARK_TEXTURE) else null
		var sparks := _make_emitter(spark_tex, Color(1.0, 0.75, 0.4) * 4.0, 14, 0.035, 7.0, 0.25, 60.0, true)
		parent.add_child(sparks)
		_orient_emitter(sparks, position, normal)
		sparks.emitting = true


func _make_emitter(texture: Texture2D, color: Color, amount: int, size: float, speed: float,
		lifetime: float, spread: float, glow: bool = false) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = maxi(amount, 1)
	p.lifetime = lifetime
	p.direction = Vector3(0, 0, -1)
	p.spread = spread
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.8 if glow else -1.5, 0)
	p.damping_min = 0.0 if glow else 2.0
	p.damping_max = 0.0 if glow else 4.0
	p.scale_amount_min = size * 0.6
	p.scale_amount_max = size * 1.4
	if not glow:
		var grow := Curve.new()
		grow.add_point(Vector2(0, 0.5))
		grow.add_point(Vector2(1, 1.6))
		p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	p.color = color
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = _particle_material(texture, glow)
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.finished.connect(p.queue_free)
	return p


func _particle_material(texture: Texture2D, glow: bool) -> StandardMaterial3D:
	var key := "%s|%s" % [texture.resource_path if texture else "", glow]
	if _particle_materials.has(key):
		return _particle_materials[key]
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if glow else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = texture
	if glow:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_particle_materials[key] = mat
	return mat


func _orient_emitter(node: Node3D, position: Vector3, facing: Vector3) -> void:
	node.global_position = position + facing * 0.02
	var up := Vector3.UP if absf(facing.y) < 0.95 else Vector3.FORWARD
	node.look_at(position + facing, up)


func _spawn_decal(surface: SurfaceData, position: Vector3, normal: Vector3, collider: Node) -> void:
	var parent: Node = collider if collider is Node3D and not (collider is Hitbox) else container()
	if parent == null:
		return
	var decal := Decal.new()
	decal.texture_albedo = surface.decal_textures.pick_random()
	var s := surface.decal_size * randf_range(0.8, 1.2)
	decal.size = Vector3(s, 0.08, s)
	decal.upper_fade = 0.0
	decal.lower_fade = 0.0
	decal.cull_mask = 1
	parent.add_child(decal)
	var up := normal
	var tangent := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	tangent = tangent.rotated(up, randf() * TAU)
	decal.global_transform = Transform3D(Basis(tangent, up, tangent.cross(up)), position)
	_decals.append(decal)
	while _decals.size() > MAX_DECALS:
		var old: Decal = _decals.pop_front()
		if is_instance_valid(old):
			old.queue_free()
