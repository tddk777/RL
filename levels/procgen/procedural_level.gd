class_name ProceduralLevel
extends Level
## A level generated from a LevelProfile and a seed, streamed around the
## player in square chunks. Geometry is built on worker threads (ChunkBuilder)
## and turned into nodes here; each chunk bakes its own navigation mesh.
##
## Entity state (enemies, pickups, unlocked exits) lives in the LevelLayout,
## so it survives chunks unloading and loading again.

signal chunk_loaded(coord: Vector2i)

@export var profile: LevelProfile
## Chunks (each chunk_cells x cell_size metres) kept loaded around the player.
@export var load_radius: int = 2
@export var max_builds_in_flight: int = 3

var level_seed: int = 0
var layout: LevelLayout
var builder: ChunkBuilder
var exit_nodes: Dictionary = {}  # exit index -> ExitDoor

var _chunks: Dictionary = {}  # Vector2i -> Node3D
var _tasks: Dictionary = {}  # Vector2i -> WorkerThreadPool task id
var _results: Dictionary = {}  # Vector2i -> ChunkData
var _mutex := Mutex.new()
var _materials: Dictionary = {}
var _scenes: Dictionary = {}
var _entities: Dictionary = {}  # Vector2i -> Array of [kind, record]
var _active_npcs: Array = []  # [NPC, record]
var _stream_timer: float = 0.0
var _center := Vector2i(-999, -999)
var _preparing: bool = false


func configure(seed_value: int) -> void:
	level_seed = seed_value


## Called by Game before the player is placed: generate and load the area
## around the spawn.
func prepare() -> void:
	_preparing = true
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
	_index_entities()
	_warm_caches()
	_center = builder.chunk_of(layout.spawn_position)
	for coord in _wanted(_center):
		_request(coord)
	while not _tasks.is_empty() or not _jobs.is_empty():
		_poll(100)
		await get_tree().process_frame
	_preparing = false


## Load materials and prop scenes up front so the first chunks don't hitch.
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


func _process(delta: float) -> void:
	super(delta)
	if layout == null or _preparing:
		return
	# While the player stands on an unbuilt chunk (frozen by the safety net)
	# finishing it matters more than a smooth frame.
	if _chunks.has(_center):
		_poll(1, frame_budget_ms)
	else:
		_poll(2, 40.0)
	_stream_timer -= delta
	if _stream_timer <= 0.0:
		_stream_timer = 0.3
		_update_streaming()


func _exit_tree() -> void:
	for coord in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[coord])
	_tasks.clear()


# --- Streaming ---------------------------------------------------------------------------

func _wanted(center: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var count := builder.chunk_count()
	for dx in range(-load_radius, load_radius + 1):
		for dz in range(-load_radius, load_radius + 1):
			var c := center + Vector2i(dx, dz)
			if c.x >= 0 and c.y >= 0 and c.x < count.x and c.y < count.y:
				out.append(c)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.distance_squared_to(center) < b.distance_squared_to(center))
	return out


func _update_streaming() -> void:
	var player := Game.player
	if not is_instance_valid(player):
		return
	_center = builder.chunk_of(player.global_position)
	# Safety net: never let the player fall through ground that isn't built yet.
	var grounded := _chunks.has(_center)
	if player.is_physics_processing() != grounded:
		player.set_physics_process(grounded)
		player.velocity = Vector3.ZERO
	for coord in _wanted(_center):
		if not _chunks.has(coord) and not _tasks.has(coord) and not _pending_roots.has(coord) \
				and _tasks.size() < max_builds_in_flight:
			_request(coord)
	for coord in _chunks.keys() + _pending_roots.keys():
		var c: Vector2i = coord
		if maxi(absi(c.x - _center.x), absi(c.y - _center.y)) > load_radius + 1:
			_unload(c)
	_check_npcs()


func _request(coord: Vector2i) -> void:
	if _chunks.has(coord) or _tasks.has(coord) or _pending_roots.has(coord):
		return
	_tasks[coord] = WorkerThreadPool.add_task(_build_task.bind(coord), false, "chunk %s" % coord)


func _build_task(coord: Vector2i) -> void:
	var data := builder.build(coord)
	_mutex.lock()
	_results[coord] = data
	_mutex.unlock()


func _poll(max_apply: int, budget_ms: float = 1e9) -> void:
	var applied := 0
	for coord in _tasks.keys():
		if applied >= max_apply:
			break
		var id: int = _tasks[coord]
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		_tasks.erase(coord)
		_mutex.lock()
		var data: ChunkBuilder.ChunkData = _results.get(coord)
		_results.erase(coord)
		_mutex.unlock()
		var c: Vector2i = coord
		if data and (_preparing or maxi(absi(c.x - _center.x), absi(c.y - _center.y)) <= load_radius + 1):
			_instantiate(data)
			applied += 1
	_run_jobs(budget_ms)


func _unload(coord: Vector2i) -> void:
	var node: Node3D = _chunks.get(coord, _pending_roots.get(coord))
	_chunks.erase(coord)
	_pending_roots.erase(coord)
	if node == null:
		return
	for i in range(_active_npcs.size() - 1, -1, -1):
		var npc: Variant = _active_npcs[i][0]
		if not is_instance_valid(npc) or builder.chunk_of((npc as NPC).global_position) == coord:
			_store_npc(i)
	for key in exit_nodes.keys():
		if not is_instance_valid(exit_nodes[key]) or node.is_ancestor_of(exit_nodes[key]):
			exit_nodes.erase(key)
	node.queue_free()


# --- Building nodes from chunk data -----------------------------------------------------------

func _material(name: StringName) -> Material:
	if not _materials.has(name):
		_materials[name] = load("res://assets/materials/%s.tres" % name)
	return _materials[name]


func _scene(id: String) -> PackedScene:
	if not _scenes.has(id):
		_scenes[id] = load("res://levels/kit/%s.tscn" % id)
	return _scenes[id]


## Milliseconds per instantiation job on the main thread (diagnostics).
var instantiate_ms: Array = []
## Frame budget for instantiation jobs.
@export var frame_budget_ms: float = 4.0

var _jobs: Array = []  # [chunk root, Callable]
var _pending_roots: Dictionary = {}  # Vector2i -> Node3D being built


## Instantiation is split into stages run under a per-frame time budget so
## streaming never stalls a frame. A chunk counts as loaded once its
## collision exists.
func _instantiate(d: ChunkBuilder.ChunkData) -> void:
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [d.coord.x, d.coord.y]
	add_child(root)
	_pending_roots[d.coord] = root
	var state := {"props": []}
	_jobs.append([root, _stage_mesh.bind(d, root)])
	_jobs.append([root, _stage_collision.bind(d, root)])
	_jobs.append([root, _stage_props.bind(d, root, state)])
	_jobs.append([root, _stage_lights.bind(d, root, state)])
	_jobs.append([root, _stage_entities.bind(d, root)])


func _run_jobs(budget_ms: float) -> void:
	var start := Time.get_ticks_usec()
	while not _jobs.is_empty():
		var job: Array = _jobs.pop_front()
		if not is_instance_valid(job[0]):
			continue  # the chunk was unloaded before it finished building
		var t0 := Time.get_ticks_usec()
		(job[1] as Callable).call()
		instantiate_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		if (Time.get_ticks_usec() - start) / 1000.0 >= budget_ms:
			break


func _alive(d: ChunkBuilder.ChunkData, root: Node3D) -> bool:
	return is_instance_valid(root) and _pending_roots.get(d.coord) == root


func _stage_mesh(d: ChunkBuilder.ChunkData, root: Node3D) -> void:
	if not _alive(d, root):
		return
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


func _stage_collision(d: ChunkBuilder.ChunkData, root: Node3D) -> void:
	if not _alive(d, root):
		return
	var g := d.geo
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
	_chunks[d.coord] = root


func _stage_props(d: ChunkBuilder.ChunkData, root: Node3D, state: Dictionary) -> void:
	if not _alive(d, root):
		return
	var prop_nodes: Array = state["props"]
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


func _stage_lights(d: ChunkBuilder.ChunkData, root: Node3D, state: Dictionary) -> void:
	if not _alive(d, root):
		return
	for l in d.lights:
		_make_light(l, root, state["props"])
	for dec in d.decals:
		_make_decal(root, dec[0], dec[1], dec[2])
	for leak in d.leaks:
		var drip := Leak.new()
		root.add_child(drip)
		drip.setup(leak["position"], leak["floor"])


func _stage_entities(d: ChunkBuilder.ChunkData, root: Node3D) -> void:
	if not _alive(d, root):
		return
	_spawn_entities(d.coord, root)
	_bake_navigation(d.coord, d.nav_faces, root)
	_pending_roots.erase(d.coord)
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
	light.distance_fade_enabled = true
	light.distance_fade_begin = 42.0
	light.distance_fade_length = 14.0
	light.distance_fade_shadow = 28.0
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
	root.add_child(decal)
	decal.global_transform = xform
	return decal


func _bake_navigation(coord: Vector2i, faces: PackedVector3Array, root: Node3D) -> void:
	if faces.is_empty():
		return
	var navmesh := NavigationMesh.new()
	navmesh.cell_size = 0.25
	navmesh.cell_height = 0.25
	navmesh.agent_radius = 0.5
	navmesh.agent_height = 1.75
	navmesh.agent_max_climb = 0.5
	navmesh.agent_max_slope = 42.0
	navmesh.border_size = 1.0
	navmesh.edge_max_error = 1.0
	navmesh.filter_baking_aabb = builder.chunk_bounds(coord)
	var source := NavigationMeshSourceGeometryData3D.new()
	source.add_faces(faces, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data_async(navmesh, source, _on_nav_baked.bind(coord, navmesh, root))


func _on_nav_baked(coord: Vector2i, navmesh: NavigationMesh, root: Node3D) -> void:
	if not is_instance_valid(root) or _chunks.get(coord) != root:
		return
	var region := NavigationRegion3D.new()
	region.name = "Navigation"
	region.navigation_mesh = navmesh
	root.add_child.call_deferred(region)


# --- Entities -------------------------------------------------------------------------------

func _index_entities() -> void:
	_entities.clear()
	var add := func(kind: StringName, record: Dictionary, position: Vector3) -> void:
		var c := builder.chunk_of(position)
		if not _entities.has(c):
			_entities[c] = []
		_entities[c].append([kind, record])
	for i in layout.exits.size():
		var e: Dictionary = layout.exits[i]
		e["index"] = i
		add.call(&"exit", e, e["position"])
		if not (e["lever"] as Dictionary).is_empty():
			e["lever"]["exit"] = i
			add.call(&"lever", e["lever"], e["lever"]["position"])
	for p in layout.pickups:
		add.call(&"pickup", p, p["position"])
	for a in layout.anomalies:
		add.call(&"anomaly", a, a["position"])
	for c in layout.corpses:
		add.call(&"corpse", c, c["position"])
	for e in layout.enemies:
		add.call(&"enemy", e, e["position"])


func _spawn_entities(coord: Vector2i, root: Node3D) -> void:
	for entry in _entities.get(coord, []):
		var kind: StringName = entry[0]
		var record: Dictionary = entry[1]
		match kind:
			&"exit":
				var door := ExitDoor.new()
				door.setup(record)
				root.add_child(door)
				_place_on_wall(door, record["position"], record["dir"])
				exit_nodes[record["index"]] = door
			&"lever":
				var lever := BreakerLever.new()
				lever.record = record
				lever.pulled.connect(_on_lever_pulled.bind(record["exit"]))
				root.add_child(lever)
				_place_on_wall(lever, record["position"], record["dir"])
			&"pickup":
				if record.get("taken", false):
					continue
				var pickup := Pickup.create(record)
				if pickup:
					root.add_child(pickup)
					pickup.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
			&"anomaly":
				Anomalies.spawn(self, root, record)
			&"corpse":
				var body := Corpse.new()
				root.add_child(body)
				body.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
			&"enemy":
				if record.get("active", false):
					continue
				_spawn_enemy(record, root)


func _place_on_wall(node: Node3D, position: Vector3, dir: int) -> void:
	var inward := -LevelLayout.dir_vector(dir)
	node.global_transform = Transform3D(Basis(Vector3.UP, atan2(inward.x, inward.z)), position)


func _on_lever_pulled(exit_index: int) -> void:
	layout.exits[exit_index]["unlocked"] = true
	var door: ExitDoor = exit_nodes.get(exit_index)
	if is_instance_valid(door):
		door.unlock()


func _spawn_enemy(record: Dictionary, root: Node3D) -> void:
	if not record.get("alive", true):
		var corpse := Corpse.new()
		root.add_child(corpse)
		corpse.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
		return
	var data := Registry.enemy(record["id"])
	if data == null:
		return
	var npc := data.scene.instantiate() as NPC
	npc.data = data
	for p: Vector3 in record["patrol"]:
		npc.patrol_points.append(p)
	add_child(npc)  # NPCs live on the level, not the chunk, so they can roam
	npc.global_transform = Transform3D(Basis(Vector3.UP, record["yaw"]), record["position"])
	record["active"] = true
	_active_npcs.append([npc, record])


## NPCs that wander outside the loaded area are put back into the layout.
func _check_npcs() -> void:
	for i in range(_active_npcs.size() - 1, -1, -1):
		var ref: Variant = _active_npcs[i][0]
		if not is_instance_valid(ref):
			_active_npcs.remove_at(i)
			continue
		var npc := ref as NPC
		if not _chunks.has(builder.chunk_of(npc.global_position)):
			_store_npc(i)


func _store_npc(i: int) -> void:
	var ref: Variant = _active_npcs[i][0]
	var record: Dictionary = _active_npcs[i][1]
	_active_npcs.remove_at(i)
	if is_instance_valid(ref):
		var npc := ref as NPC
		record["position"] = npc.global_position
		record["yaw"] = npc.rotation.y
		record["alive"] = npc.alive
		npc.queue_free()
	record["active"] = false
	# Re-index under the chunk it is in now.
	var c := builder.chunk_of(record["position"])
	for key in _entities:
		var list: Array = _entities[key]
		for j in range(list.size() - 1, -1, -1):
			if list[j][1] == record:
				list.remove_at(j)
	if not _entities.has(c):
		_entities[c] = []
	_entities[c].append([&"enemy", record])
