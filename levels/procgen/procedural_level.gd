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
	random_sounds = profile.random_sounds
	if profile.environment:
		var env := WorldEnvironment.new()
		env.name = "WorldEnvironment"
		env.environment = profile.environment.duplicate()
		add_child(env)
	_warm_caches()
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
	navmesh.agent_radius = 0.35
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
