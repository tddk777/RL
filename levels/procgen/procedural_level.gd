class_name ProceduralLevel
extends Level
## A level generated from a LevelProfile and a seed. The whole complex is
## built while the level loads: ChunkBuilder makes each chunk's geometry on a
## worker thread, this node turns it into meshes, collision, lights and a
## navigation mesh per chunk, then places the entities.
##
## Entity state (enemies, pickups, unlocked exits) lives in the LevelLayout.

signal chunk_loaded(coord: Vector2i)

@export var profile: LevelProfile

var level_seed: int = 0
var layout: LevelLayout
var builder: ChunkBuilder
var exit_nodes: Dictionary = {}  # exit index -> ExitDoor
## Milliseconds spent building each chunk on its worker thread (diagnostics).
var build_ms: Array = []
## Milliseconds spent instantiating each chunk on the main thread (diagnostics).
var instantiate_ms: Array = []

var _chunks: Dictionary = {}  # Vector2i -> Node3D
var _tasks: Dictionary = {}  # Vector2i -> WorkerThreadPool task id
var _results: Dictionary = {}  # Vector2i -> ChunkData
var _mutex := Mutex.new()
var _materials: Dictionary = {}
var _scenes: Dictionary = {}
var _bakes_pending: int = 0
var _nav_source := NavigationMeshSourceGeometryData3D.new()
## Milliseconds the navigation bake took (diagnostics).
var nav_bake_ms: float = 0.0
var _active_npcs: Array = []  # [NPC, record]


func configure(seed_value: int) -> void:
	level_seed = seed_value


## Called by Game before the player is placed: generate and build everything.
func prepare() -> void:
	if level_seed == 0:
		level_seed = randi()
	layout = LayoutGenerator.generate(profile, level_seed)
	builder = ChunkBuilder.new(layout)
	ambience = profile.ambience
	ambience_bed = profile.ambience_bed
	ambience_bed_volume_db = profile.ambience_bed_volume_db
	random_sounds = profile.random_sounds
	if profile.environment:
		var env := WorldEnvironment.new()
		env.name = "WorldEnvironment"
		env.environment = profile.environment.duplicate()
		add_child(env)
	_warm_caches()
	_add_daylight()
	_add_sun_rays()
	_add_surroundings()
	var count := builder.chunk_count()
	for cx in count.x:
		for cz in count.y:
			_request(Vector2i(cx, cz))
	while not _tasks.is_empty():
		_poll()
		await get_tree().process_frame
	# One navigation mesh for the whole complex (no seams between chunks).
	_bake_navigation()
	var t := 0.0
	while _bakes_pending > 0 and t < 60.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	# The navigation map syncs on a physics frame after the region is added;
	# wait until it answers queries.
	var map := get_world_3d().navigation_map
	t = 0.0
	while NavigationServer3D.map_get_closest_point(map, layout.spawn_position) == Vector3.ZERO and t < 10.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	_snap_to_navigation()
	_spawn_entities()


## Load materials and prop scenes up front so building doesn't hitch.
func _warm_caches() -> void:
	for f in ResourceLoader.list_directory("res://assets/materials"):
		if f.ends_with(".tres"):
			_material(StringName(f.get_basename()))
	for f in ResourceLoader.list_directory("res://levels/kit"):
		if f.ends_with(".tscn"):
			_scene(f.get_basename())


func player_spawn_transform() -> Transform3D:
	if layout == null:
		return super()
	return Transform3D(Basis(Vector3.UP, layout.spawn_yaw), layout.spawn_position)


func loaded_chunks() -> Array:
	return _chunks.keys()


func _exit_tree() -> void:
	for coord in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[coord])
	_tasks.clear()


# --- Daylight and surroundings ------------------------------------------------------------------

func _add_daylight() -> void:
	if profile.daylight_energy <= 0.0:
		return
	var sun := DirectionalLight3D.new()
	sun.name = "Daylight"
	sun.light_color = profile.daylight_color
	sun.light_energy = profile.daylight_energy
	sun.shadow_enabled = true
	sun.shadow_blur = 2.5  # overcast: soft edges
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.light_volumetric_fog_energy = 0.2
	add_child(sun)
	var dir := builder.sun_dir()
	sun.global_basis = Basis.looking_at(dir, Vector3.UP)
	_sun = sun


## Screen-space god rays and a soft glare round the sun (ARez's lens_effects).
## Needs a RenderingDevice, so there's none headless or on Compatibility.
func _add_sun_rays() -> void:
	var env := get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	if _sun == null or env == null or profile.sun_rays.a <= 0.0 or RenderingServer.get_rendering_device() == null:
		return
	var fx := LensFlareEffect.new()
	fx.sun_color = profile.sun_rays
	fx.Effect_Multiplier = 1.2
	fx.Anamorphic_Intensity = 60.0
	fx.Anamorphic_Brightness = 0.25
	fx.Weight = 0.08
	fx.SampleCount = 48
	env.compositor = Compositor.new()
	env.compositor.compositor_effects = [fx]
	_sun_fx = fx


## Open ground round the complex (with collision, so nothing falls forever):
## rolling hills (a Landscape mesh, or Terrain3D) or a flat plane;
## and a hazy skyline of ruins, stacks and towers far beyond the fence.
func _add_surroundings() -> void:
	var size := Vector2(layout.size) * layout.cell
	var centre := Vector3(size.x * 0.5, 0.0, size.y * 0.5)
	var hills := profile.terrain
	if hills and profile.use_terrain3d and ClassDB.class_exists(&"Terrain3D"):
		_add_terrain(centre)
	elif hills:
		add_child(Landscape.build(ground_height, Rect2(Vector2.ZERO, size), centre, _material(profile.terrain_material)))
	else:
		var ground := MeshInstance3D.new()
		ground.name = "Ground"
		var plane := PlaneMesh.new()
		plane.size = Vector2(1600, 1600)
		plane.subdivide_width = 16
		plane.subdivide_depth = 16
		ground.mesh = plane
		ground.material_override = _material(profile.ground_material)
		ground.position = centre + Vector3.DOWN * 0.06
		add_child(ground)
	# Flat collision under the site either way (the terrain's own collision
	# only follows the camera).
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	body.collision_mask = 0
	body.set_meta(&"surface", &"concrete")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1600, 1.0, 1600)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.position = centre + Vector3.DOWN * 0.56
	if not profile.skyline:
		return
	var g := GeoBuilder.new()
	var r := RandomNumberGenerator.new()
	r.seed = hash([level_seed, 7001])
	var radius := maxf(size.x, size.y) * 0.5
	var mats: Array[StringName] = [&"concrete_dark", &"brick", &"concrete_wall", &"rusted_metal"]
	var a := 0.0
	while a < TAU:
		var dist := radius + r.randf_range(70.0, 240.0)
		var p := centre + Vector3(cos(a), 0, sin(a)) * dist
		if hills:
			p.y = ground_height(p.x, p.z) - 1.5  # sunk into the slope
		var roll := r.randf()
		var mat := mats[r.randi_range(0, mats.size() - 1)]
		var yaw := Basis(Vector3.UP, a + r.randf_range(-0.3, 0.3))
		if roll < 0.1:
			# Smokestack
			var h := r.randf_range(35.0, 70.0)
			g.frustum(p, p + Vector3.UP * h, r.randf_range(2.2, 3.5), r.randf_range(1.2, 2.0), &"brick", 10, true)
		elif roll < 0.16:
			# Cooling tower
			var h := r.randf_range(30.0, 50.0)
			g.frustum(p, p + Vector3.UP * h * 0.65, h * 0.42, h * 0.28, &"concrete_wall", 16, false)
			g.frustum(p + Vector3.UP * h * 0.65, p + Vector3.UP * h, h * 0.28, h * 0.32, &"concrete_wall", 16, false)
		elif roll < 0.22:
			# Water tower on legs
			var h := r.randf_range(18.0, 28.0)
			for i in 4:
				var leg := p + Vector3(cos(i * PI * 0.5 + 0.7), 0, sin(i * PI * 0.5 + 0.7)) * 3.0
				g.cylinder(leg, p + Vector3.UP * h, 0.35, &"rusted_metal", 6)
			g.frustum(p + Vector3.UP * h, p + Vector3.UP * (h + 7.0), 4.5, 4.5, &"rusted_metal", 12, true)
		else:
			# Block of ruined buildings: a main mass and a lower wing, broken top.
			var w := r.randf_range(18.0, 55.0)
			var d := r.randf_range(14.0, 35.0)
			var h := r.randf_range(7.0, 34.0)
			g.box(p + Vector3.UP * (h * 0.5), Vector3(w, h, d), mat, &"", false, yaw)
			g.box(p + yaw * Vector3(w * 0.5, 0, d * 0.2) + Vector3.UP * (h * 0.3), Vector3(w * 0.6, h * 0.6, d * 0.7), mat, &"", false, yaw)
			for i in r.randi_range(0, 3):
				var q := p + yaw * Vector3(r.randf_range(-w, w) * 0.4, 0, r.randf_range(-d, d) * 0.4)
				var bh := r.randf_range(2.0, 6.0)
				g.box(q + Vector3.UP * (h + bh * 0.5 - 0.5), Vector3(r.randf_range(3, 9), bh, r.randf_range(3, 9)), mat, &"", false, yaw)
		a += r.randf_range(0.06, 0.2)
	g.finalize()
	var mesh := ArrayMesh.new()
	for mat: StringName in g.packed_surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, g.packed_surfaces[mat])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(mat))
	var sky := MeshInstance3D.new()
	sky.name = "Skyline"
	sky.mesh = mesh
	sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sky)


const TERRAIN_REGION := 1024  # Terrain3D region size (vertices)
const TERRAIN_SPACING := 2.0  # m between terrain vertices: 2 x 2 regions = 4 km
const TERRAIN_SAMPLES := 512  # height samples across, smoothed up to the full map

var _hill_noise: FastNoiseLite
var _swell_noise: FastNoiseLite
var _terrain: Node3D
var _sun: DirectionalLight3D
var _sun_fx: CompositorEffect
var _terrain_camera: Camera3D


## Height of the landscape at a world position: flat over the site and a
## strip round it, then embankments and rolling hills further out.
func ground_height(x: float, z: float) -> float:
	var size := Vector2(layout.size) * layout.cell
	var dx := maxf(maxf(-x, x - size.x), 0.0)
	var dz := maxf(maxf(-z, z - size.y), 0.0)
	var d := Vector2(dx, dz).length()
	if d <= 0.0 or not profile.terrain:
		return -0.06
	if _hill_noise == null:
		_hill_noise = FastNoiseLite.new()
		_hill_noise.seed = hash([level_seed, 7101])
		_hill_noise.frequency = 0.0045
		_hill_noise.fractal_octaves = 4
		_swell_noise = FastNoiseLite.new()
		_swell_noise.seed = hash([level_seed, 7102])
		_swell_noise.frequency = 0.025
	var hill := _hill_noise.get_noise_2d(x, z) * 0.5 + 0.5
	var swell := _swell_noise.get_noise_2d(x, z) * 0.5 + 0.5
	var bank := smoothstep(8.0, 40.0, d)  # embankment off the fence strip
	var far := smoothstep(25.0, 180.0, d)
	return -0.06 + bank * (2.0 + 4.0 * swell) + far * profile.terrain_height * hill


func _add_terrain(centre: Vector3) -> void:
	var terrain: Node3D = ClassDB.instantiate(&"Terrain3D")
	terrain.name = "Terrain"
	terrain.set(&"debug_level", 0)
	terrain.call(&"change_region_size", TERRAIN_REGION)
	terrain.set(&"vertex_spacing", TERRAIN_SPACING)
	terrain.set(&"collision_layer", Layers.WORLD)
	terrain.set(&"collision_mask", 0)
	# Terrain3D follows a camera (LODs, collision); the player's doesn't exist
	# yet, so start with a stand-in at the spawn and hand over in _process.
	_terrain_camera = Camera3D.new()
	_terrain_camera.name = "TerrainCamera"
	_terrain_camera.position = layout.spawn_position + Vector3.UP * 1.7
	add_child(_terrain_camera)
	_terrain = terrain
	add_child(terrain)
	terrain.call(&"set_camera", _terrain_camera)
	var mat: Resource = terrain.get(&"material")
	mat.set(&"world_background", 0)  # nothing outside the regions
	mat.set(&"auto_shader", true)
	mat.call(&"set_shader_param", &"auto_slope", 2.0)
	var assets: Resource = ClassDB.instantiate(&"Terrain3DAssets")
	var names := ["scrub", "dirt"]
	for i in names.size():
		var ta: Resource = ClassDB.instantiate(&"Terrain3DTextureAsset")
		ta.set(&"name", names[i])
		ta.set(&"albedo_texture", load("res://assets/textures/terrain/%s_albedo_height.png" % names[i]))
		ta.set(&"normal_texture", load("res://assets/textures/terrain/%s_normal_rough.png" % names[i]))
		ta.set(&"uv_scale", 0.12)
		ta.set(&"detiling_rotation", 0.2)
		assets.call(&"set_texture", i, ta)
	terrain.set(&"assets", assets)
	mat.call(&"set_shader_param", &"auto_base_texture", 1)
	mat.call(&"set_shader_param", &"auto_overlay_texture", 0)
	# Heights on a coarse grid, smoothed up to one value per vertex.
	var span := TERRAIN_REGION * 2 * TERRAIN_SPACING
	# Regions sit on a fixed grid (region size x spacing); align to it.
	var region_m := TERRAIN_REGION * TERRAIN_SPACING
	var origin := Vector3(floorf((centre.x - span * 0.5) / region_m) * region_m, 0.0,
		floorf((centre.z - span * 0.5) / region_m) * region_m)
	var n := TERRAIN_SAMPLES
	var data := PackedFloat32Array()
	data.resize(n * n)
	var step := span / float(n - 1)
	for j in n:
		for i in n:
			data[j * n + i] = ground_height(origin.x + i * step, origin.z + j * step)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, data.to_byte_array())
	img.resize(TERRAIN_REGION * 2, TERRAIN_REGION * 2, Image.INTERPOLATE_CUBIC)
	terrain.get(&"data").call(&"import_images", [img, null, null], origin, 0.0, 1.0)


func _process(delta: float) -> void:
	super(delta)
	if _sun_fx:
		var cam := get_viewport().get_camera_3d()
		_sun_fx.enabled = cam != null and Settings.get_value("graphics", "quality") >= Settings.Quality.MEDIUM
		if _sun_fx.enabled:
			var to_sun := _sun.global_basis.z.normalized()
			var lfx := _sun_fx as LensFlareEffect
			lfx.sun_dir_sign = (-cam.global_basis.z).normalized().dot(to_sun)
			lfx.sun_position = cam.unproject_position(cam.global_position + to_sun * maxf(cam.near, 1.0)) / get_viewport().get_visible_rect().size
	if _terrain:
		var cam := get_viewport().get_camera_3d()
		if cam and cam != _terrain.call(&"get_camera"):
			_terrain.call(&"set_camera", cam)


# --- Building ---------------------------------------------------------------------------------

func _request(coord: Vector2i) -> void:
	_tasks[coord] = WorkerThreadPool.add_task(_build_task.bind(coord), false, "chunk %s" % coord)


func _build_task(coord: Vector2i) -> void:
	var t0 := Time.get_ticks_usec()
	var data := builder.build(coord)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_mutex.lock()
	_results[coord] = data
	build_ms.append(ms)
	_mutex.unlock()


func _poll() -> void:
	for coord in _tasks.keys():
		var id: int = _tasks[coord]
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		_tasks.erase(coord)
		_mutex.lock()
		var data: ChunkBuilder.ChunkData = _results.get(coord)
		_results.erase(coord)
		_mutex.unlock()
		if data:
			var t0 := Time.get_ticks_usec()
			_instantiate(data)
			instantiate_ms.append((Time.get_ticks_usec() - t0) / 1000.0)


func _material(name: StringName) -> Material:
	if not _materials.has(name):
		var path := "res://assets/materials/%s.tres" % name
		_materials[name] = load(path) if ResourceLoader.exists(path) else load("res://assets/materials/concrete_wall.tres")
	return _materials[name]


func _scene(id: String) -> PackedScene:
	if not _scenes.has(id):
		_scenes[id] = load("res://levels/kit/%s.tscn" % id)
	return _scenes[id]


func _instantiate(d: ChunkBuilder.ChunkData) -> void:
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [d.coord.x, d.coord.y]
	add_child(root)
	var g := d.geo
	var mesh := ArrayMesh.new()
	for mat: StringName in g.packed_surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, g.packed_surfaces[mat])
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(mat))
	var mi := MeshInstance3D.new()
	mi.name = "Architecture"
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	root.add_child(mi)
	if not g.packed_occluder_vertices.is_empty():
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(g.packed_occluder_vertices, g.packed_occluder_indices)
		var oi := OccluderInstance3D.new()
		oi.occluder = occ
		root.add_child(oi)
	for key: String in g.packed_collisions:
		var parts := key.split("|")
		var body := StaticBody3D.new()
		body.collision_layer = int(parts[1])
		body.collision_mask = 0
		body.set_meta(&"surface", StringName(parts[0]))
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(g.packed_collisions[key])
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		root.add_child(body)
	var prop_nodes: Array = []
	for p in d.props:
		var inst := _scene(p[0]).instantiate() as Node3D
		root.add_child(inst)
		inst.transform = p[1]
		if (p[2] as Dictionary).get("dead", false):
			for child_name in ["Bulb", "Tubes"]:
				var e := inst.get_node_or_null(NodePath(child_name)) as GeometryInstance3D
				if e:
					e.material_override = _material(&"lamp_dead")
		prop_nodes.append(inst)
	for l in d.lights:
		_make_light(l, root, prop_nodes)
	for dec in d.decals:
		_make_decal(root, dec[0], dec[1], dec[2])
	for leak in d.leaks:
		var drip := Leak.new()
		root.add_child(drip)
		drip.setup(leak["position"], leak["floor"])
	_chunks[d.coord] = root
	if not d.nav_faces.is_empty():
		_nav_source.add_faces(d.nav_faces, Transform3D.IDENTITY)
	for ob in d.obstructions:
		_nav_source.add_projected_obstruction(ob[0], ob[1], ob[2], false)
	chunk_loaded.emit(d.coord)


func _make_light(l: Dictionary, root: Node3D, props: Array) -> void:
	var light: Light3D
	if l["type"] == "spot":
		var spot := SpotLight3D.new()
		spot.spot_range = l["range"]
		spot.spot_angle = l["angle"]
		spot.spot_attenuation = 1.1
		light = spot
	else:
		var omni := OmniLight3D.new()
		omni.omni_range = l["range"]
		omni.omni_attenuation = 1.2
		light = omni
	light.light_color = l["color"]
	light.light_energy = l["energy"]
	light.shadow_enabled = l.get("shadow", false)
	light.light_volumetric_fog_energy = l.get("fog", 1.0)
	# Far lights fade out instead of popping, but late enough that a big hall
	# stays lit across its length.
	light.distance_fade_enabled = true
	light.distance_fade_begin = 85.0
	light.distance_fade_length = 25.0
	light.distance_fade_shadow = 35.0
	root.add_child(light)
	light.global_position = l["position"]
	if l.has("target"):
		var to: Vector3 = l["target"] - light.global_position
		light.look_at(l["target"], Vector3.FORWARD if absf(to.normalized().y) > 0.98 else Vector3.UP)
	var flicker: float = l.get("flicker", 0.0)
	var pulse: bool = l.get("pulse", false)
	if flicker > 0.0 or pulse:
		var f := FlickerLight.new()
		f.light = light
		f.flicker_amount = flicker
		f.pulse = pulse
		var prop_index: int = l.get("prop", -1)
		if prop_index >= 0 and prop_index < props.size():
			var e := (props[prop_index] as Node).get_node_or_null(NodePath(l.get("emissive", "Bulb"))) as GeometryInstance3D
			if e:
				e.material_override = (_material(&"lamp_emissive") as StandardMaterial3D).duplicate()
				f.emissive_mesh = e
		light.add_child(f)
	if l.get("buzz", false):
		var buzz := AudioStreamPlayer3D.new()
		buzz.stream = _buzz_stream()
		buzz.autoplay = true
		buzz.bus = &"World"
		buzz.volume_db = -12.0
		buzz.unit_size = 2.0
		buzz.max_distance = 14.0
		light.add_child(buzz)


var _buzz: AudioStream


func _buzz_stream() -> AudioStream:
	if _buzz == null:
		_buzz = load("res://assets/audio/ambience/fluorescent_buzz_loop.wav")
	return _buzz


func _make_decal(root: Node3D, texture_name: String, xform: Transform3D, size: Vector3) -> Decal:
	var decal := Decal.new()
	decal.texture_albedo = load("res://assets/textures/decals/%s.png" % texture_name)
	decal.size = size
	decal.cull_mask = 1
	decal.distance_fade_enabled = true
	decal.distance_fade_begin = 35.0
	decal.distance_fade_length = 10.0
	root.add_child(decal)
	decal.global_transform = xform
	return decal


func _bake_navigation() -> void:
	var navmesh := NavigationMesh.new()
	navmesh.cell_size = 0.25
	navmesh.cell_height = 0.25
	# A whole number of cells: the baker rounds the radius up to one, and at
	# 0.5 m the 1.4 m office doors would close.
	navmesh.agent_radius = 0.25
	navmesh.agent_height = 1.75
	navmesh.agent_max_climb = 0.5
	navmesh.agent_max_slope = 42.0
	navmesh.edge_max_error = 1.0
	_bakes_pending += 1
	var t0 := Time.get_ticks_msec()
	NavigationServer3D.bake_from_source_geometry_data_async(navmesh, _nav_source, _on_nav_baked.bind(navmesh, t0))


func _on_nav_baked(navmesh: NavigationMesh, t0: int) -> void:
	_bakes_pending -= 1
	nav_bake_ms = Time.get_ticks_msec() - t0
	var region := NavigationRegion3D.new()
	region.name = "Navigation"
	region.navigation_mesh = navmesh
	add_child(region)


# --- Entities -------------------------------------------------------------------------------

## Set pieces fill rooms after the layout placed people and loot: move every
## floor-standing record onto the nearest walkable spot.
func _snap_to_navigation() -> void:
	var map := get_world_3d().navigation_map
	var snap := func(p: Vector3) -> Vector3:
		# Nearest walkable spot on the same floor; if p is inside a machine the
		# nearest navmesh may be on top of it, so look around on a ring too.
		for radius: float in [0.0, 1.0, 2.0, 3.0, 4.5]:
			var best := Vector3.INF
			var steps := 1 if radius == 0.0 else 12
			for i in steps:
				var probe := p + Vector3(cos(TAU * i / steps), 0, sin(TAU * i / steps)) * radius
				var q := NavigationServer3D.map_get_closest_point(map, probe + Vector3.UP * 0.3)
				if q == Vector3.ZERO or absf(q.y - p.y) > 0.9 or Vector2(q.x - probe.x, q.z - probe.z).length() > 1.0:
					continue
				if best == Vector3.INF or q.distance_to(p) < best.distance_to(p):
					best = q
			if best != Vector3.INF:
				return best + Vector3.UP * 0.05
		return p
	layout.spawn_position = snap.call(layout.spawn_position)
	for list in [layout.pickups, layout.corpses, layout.enemies]:
		for rec: Dictionary in list:
			rec["position"] = snap.call(rec["position"])
	for e: Dictionary in layout.enemies:
		var patrol: Array = e["patrol"]
		for i in patrol.size():
			patrol[i] = snap.call(patrol[i])


func _spawn_entities() -> void:
	for i in layout.exits.size():
		var e: Dictionary = layout.exits[i]
		e["index"] = i
		var door := ExitDoor.new()
		door.setup(e)
		add_child(door)
		_place_on_wall(door, e["position"], e["dir"])
		exit_nodes[i] = door
		var lever_rec: Dictionary = e["lever"]
		if not lever_rec.is_empty():
			lever_rec["exit"] = i
			var lever := BreakerLever.new()
			lever.record = lever_rec
			lever.pulled.connect(_on_lever_pulled.bind(i))
			add_child(lever)
			_place_on_wall(lever, lever_rec["position"], lever_rec["dir"])
	for p: Dictionary in layout.pickups:
		if p.get("taken", false):
			continue
		var pickup := Pickup.create(p)
		if pickup:
			add_child(pickup)
			pickup.global_transform = Transform3D(Basis(Vector3.UP, p["yaw"]), p["position"])
	for a: Dictionary in layout.anomalies:
		Anomalies.spawn(self, self, a)
	for c: Dictionary in layout.corpses:
		var body := Corpse.new()
		add_child(body)
		body.global_transform = Transform3D(Basis(Vector3.UP, c["yaw"]), c["position"])
	for e: Dictionary in layout.enemies:
		_spawn_enemy(e)


func _place_on_wall(node: Node3D, position: Vector3, dir: int) -> void:
	var inward := -LevelLayout.dir_vector(dir)
	node.global_transform = Transform3D(Basis(Vector3.UP, atan2(inward.x, inward.z)), position)


func _on_lever_pulled(exit_index: int) -> void:
	layout.exits[exit_index]["unlocked"] = true
	var door: ExitDoor = exit_nodes.get(exit_index)
	if is_instance_valid(door):
		door.unlock()


func _spawn_enemy(record: Dictionary) -> void:
	if not record.get("alive", true):
		var corpse := Corpse.new()
		add_child(corpse)
		corpse.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
		return
	var data := Registry.enemy(record["id"])
	if data == null:
		return
	var npc := data.scene.instantiate() as NPC
	npc.data = data
	for p: Vector3 in record["patrol"]:
		npc.patrol_points.append(p)
	add_child(npc)
	npc.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
	record["active"] = true
	_active_npcs.append([npc, record])
