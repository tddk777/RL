extends SceneTree
## Bootstraps Level 1 ("The Foundry"): an abandoned, rusting multi-storey
## factory hall with catwalks, an office block and a control room. Writes
## res://levels/l1_foundry/l1_foundry.tscn and bakes its navigation mesh.
##
## After generation the scene is a normal Godot scene: edit it in the editor.
## Re-running this script overwrites it.
##
##   godot --headless --path . --script res://dev/generators/build_l1.gd

const OUT_DIR := "res://levels/l1_foundry/"
const KIT := "res://levels/kit/"
const AUDIO := "res://assets/audio/"

const HALL_X := Vector2(-14.0, 24.0)
const OFFICE_X := Vector2(-24.0, -14.0)
const Z := Vector2(-16.0, 16.0)
const HEIGHT := 13.0
const DECK := 5.0  # catwalk / office floor 2
const TOP := 10.0  # control room floor
const COLUMNS_X := [-8.0, 0.0, 8.0, 16.0]
const COLUMNS_Z := [-8.0, 8.0]

var lvl  # Level (loaded at runtime: its script uses autoloads)
var structure: Node3D
var props: Node3D
var lights: Node3D
var nav: NavigationRegion3D
var _mat_cache := {}
var _ibeam_mesh: Mesh


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	lvl = load("res://levels/level.gd").new()
	lvl.name = "L1Foundry"
	lvl.ambience = _audio("ambience/industrial_interior_loop.wav")
	lvl.ambience_volume_db = -3.0
	var randoms: Array[AudioStream] = []
	for n in ["ambience/metal_groan_1.wav", "ambience/metal_groan_2.wav", "ambience/metal_groan_3.wav",
			"ambience/drip_1.wav", "ambience/drip_2.wav", "ambience/drip_3.wav"]:
		var s := _audio(n)
		if s:
			randoms.append(s)
	lvl.random_sounds = randoms
	lvl.reverb_room_size = 0.82
	lvl.reverb_wet = 0.16
	get_root().add_child(lvl)

	_environment()
	nav = _node(NavigationRegion3D.new(), "Navigation", lvl) as NavigationRegion3D
	structure = _node(Node3D.new(), "Structure", nav)
	props = _node(Node3D.new(), "Props", nav)
	lights = _node(Node3D.new(), "Lights", lvl)

	_shell()
	print("  _shell %d ms" % Time.get_ticks_msec())
	_roof()
	print("  _roof %d ms" % Time.get_ticks_msec())
	_columns()
	print("  _columns %d ms" % Time.get_ticks_msec())
	_office_block()
	print("  _office_block %d ms" % Time.get_ticks_msec())
	_catwalks()
	print("  _catwalks %d ms" % Time.get_ticks_msec())
	_hall_props()
	print("  _hall_props %d ms" % Time.get_ticks_msec())
	_office_props()
	print("  _office_props %d ms" % Time.get_ticks_msec())
	_lighting()
	print("  _lighting %d ms" % Time.get_ticks_msec())
	_atmosphere()
	print("  _atmosphere %d ms" % Time.get_ticks_msec())
	_gameplay()
	print("  _gameplay %d ms" % Time.get_ticks_msec())
	_bake_navigation()
	print("  _bake_navigation %d ms" % Time.get_ticks_msec())
	_save()
	print("  _save %d ms" % Time.get_ticks_msec())
	quit()


# --- Helpers ---------------------------------------------------------------------

func m(name: String) -> Material:
	if not _mat_cache.has(name):
		_mat_cache[name] = load("res://assets/materials/%s.tres" % name)
	return _mat_cache[name]


func _audio(path: String) -> AudioStream:
	return load(AUDIO + path) if ResourceLoader.exists(AUDIO + path) else null


func _node(node: Node, node_name: String, parent: Node) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = lvl
	return node


var _counter := {}


func _unique(base: String) -> String:
	_counter[base] = _counter.get(base, 0) + 1
	return "%s%d" % [base, _counter[base]]


## Solid axis-aligned box between two corners, with collision and a surface tag.
func box(parent: Node, a: Vector3, b: Vector3, mat: String, surface := &"concrete", collide := true, base := "Box") -> Node3D:
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	var size := hi - lo
	if size.x < 0.001 or size.y < 0.001 or size.z < 0.001:
		return null
	var holder: Node3D
	if collide:
		var body := StaticBody3D.new()
		body.set_meta(&"surface", surface)
		holder = _node(body, _unique(base), parent)
		var shape := BoxShape3D.new()
		shape.size = size
		var cs := CollisionShape3D.new()
		cs.shape = shape
		_node(cs, "Shape", holder)
	else:
		holder = _node(Node3D.new(), _unique(base), parent)
	holder.position = (lo + hi) * 0.5
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = m(mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_node(mi, "Mesh", holder)
	return holder


## A wall in the plane x = const (axis "x") or z = const (axis "z"), spanning
## `span` along the other horizontal axis and `ys` vertically, minus
## rectangular openings [along0, along1, y0, y1].
func wall(parent: Node, axis: String, coord: float, thickness: float, span: Vector2, ys: Vector2,
		openings: Array, mat: String, surface := &"concrete") -> void:
	var cuts := [span.x, span.y]
	for o in openings:
		cuts.append(clampf(o[0], span.x, span.y))
		cuts.append(clampf(o[1], span.x, span.y))
	cuts.sort()
	for i in cuts.size() - 1:
		var a0: float = cuts[i]
		var a1: float = cuts[i + 1]
		if a1 - a0 < 0.001:
			continue
		var mid := (a0 + a1) * 0.5
		var solids := [ys]
		for o in openings:
			if mid > o[0] and mid < o[1]:
				var next := []
				for s: Vector2 in solids:
					if o[3] <= s.x or o[2] >= s.y:
						next.append(s)
						continue
					if o[2] > s.x:
						next.append(Vector2(s.x, o[2]))
					if o[3] < s.y:
						next.append(Vector2(o[3], s.y))
				solids = next
		for s: Vector2 in solids:
			if axis == "x":
				box(parent, Vector3(coord - thickness * 0.5, s.x, a0), Vector3(coord + thickness * 0.5, s.y, a1), mat, surface, true, "Wall")
			else:
				box(parent, Vector3(a0, s.x, coord - thickness * 0.5), Vector3(a1, s.y, coord + thickness * 0.5), mat, surface, true, "Wall")


## Horizontal slab top at `top_y` over [x0,x1]x[z0,z1] minus rectangular holes.
func slab(parent: Node, xs: Vector2, zs: Vector2, top_y: float, thickness: float, holes: Array,
		mat: String, surface := &"concrete") -> void:
	var cuts := [xs.x, xs.y]
	for h in holes:
		cuts.append(h[0])
		cuts.append(h[1])
	cuts.sort()
	for i in cuts.size() - 1:
		var x0: float = cuts[i]
		var x1: float = cuts[i + 1]
		if x1 - x0 < 0.001:
			continue
		var mid := (x0 + x1) * 0.5
		var spans := [zs]
		for h in holes:
			if mid > h[0] and mid < h[1]:
				var next := []
				for s: Vector2 in spans:
					if h[3] <= s.x or h[2] >= s.y:
						next.append(s)
						continue
					if h[2] > s.x:
						next.append(Vector2(s.x, h[2]))
					if h[3] < s.y:
						next.append(Vector2(h[3], s.y))
				spans = next
		for s: Vector2 in spans:
			box(parent, Vector3(x0, top_y - thickness, s.x), Vector3(x1, top_y, s.y), mat, surface, true, "Slab")


func prop(parent: Node, id: String, pos: Vector3, rot_y := 0.0) -> Node3D:
	var inst := (load(KIT + id + ".tscn") as PackedScene).instantiate() as Node3D
	inst.name = _unique(id.to_pascal_case())
	parent.add_child(inst)
	inst.owner = lvl
	inst.position = pos
	inst.rotation_degrees.y = rot_y
	return inst


func ibeam_column(parent: Node, x: float, z: float, height: float) -> void:
	if _ibeam_mesh == null:
		var k := MeshKit.new()
		var w := 0.32
		var d := 0.3
		var f := 0.03
		var web := 0.018
		var profile := PackedVector2Array([
			Vector2(-d * 0.5, -w * 0.5), Vector2(-d * 0.5 + f, -w * 0.5), Vector2(-d * 0.5 + f, -web * 0.5),
			Vector2(d * 0.5 - f, -web * 0.5), Vector2(d * 0.5 - f, -w * 0.5), Vector2(d * 0.5, -w * 0.5),
			Vector2(d * 0.5, w * 0.5), Vector2(d * 0.5 - f, w * 0.5), Vector2(d * 0.5 - f, web * 0.5),
			Vector2(-d * 0.5 + f, web * 0.5), Vector2(-d * 0.5 + f, w * 0.5), Vector2(-d * 0.5, w * 0.5)])
		# Extrude along X then rotate so the extrusion runs up Y.
		k.at(Vector3(0, height * 0.5, 0), Vector3(0, 0, 90)).extrude(profile, height, m("painted_steel"), 0.004, 10.0)
		k.reset()
		k.box(Vector3(0.5, 0.03, 0.5), Vector3(0, 0.015, 0), m("rusted_metal"), 0.004)
		_ibeam_mesh = k.commit()
		ResourceSaver.save(_ibeam_mesh, "res://assets/models/props/ibeam_column.res")
		_ibeam_mesh.take_over_path("res://assets/models/props/ibeam_column.res")
	var body := StaticBody3D.new()
	body.set_meta(&"surface", &"metal")
	_node(body, _unique("Column"), parent)
	body.position = Vector3(x, 0, z)
	var mi := MeshInstance3D.new()
	mi.mesh = _ibeam_mesh
	_node(mi, "Mesh", body)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.32, height, 0.3)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, height * 0.5, 0)
	_node(cs, "Shape", body)


## Steel stair flight. Steps are visual; a hidden ramp gives smooth walking.
func stairs(parent: Node, x_range: Vector2, z_bottom: float, z_top: float, y_bottom: float, y_top: float) -> void:
	var holder := _node(Node3D.new(), _unique("Stairs"), parent) as Node3D
	var rise := y_top - y_bottom
	var run := z_top - z_bottom
	var steps := int(round(rise / 0.2))
	var step_rise := rise / steps
	var step_run := run / steps
	for i in steps:
		var y := y_bottom + step_rise * (i + 1)
		var z0 := z_bottom + step_run * i
		box(holder, Vector3(x_range.x + 0.05, y - 0.04, z0), Vector3(x_range.y - 0.05, y, z0 + step_run),
			"steel_grate", &"metal", false, "Step")
	# Stringers
	var length := sqrt(rise * rise + run * run)
	var angle := atan2(rise, absf(run))
	for x in [x_range.x, x_range.y]:
		var s := box(holder, Vector3(x - 0.04, -0.15, -length * 0.5), Vector3(x + 0.04, 0.15, length * 0.5),
			"painted_steel_yellow", &"metal", false, "Stringer")
		s.position = Vector3(x, (y_bottom + y_top) * 0.5, (z_bottom + z_top) * 0.5)
		s.rotation.x = angle * signf(-run)
	# Walkable ramp (collision only, sits just under the step noses)
	var ramp := StaticBody3D.new()
	ramp.set_meta(&"surface", &"metal")
	_node(ramp, "Ramp", holder)
	var shape := BoxShape3D.new()
	shape.size = Vector3(x_range.y - x_range.x, 0.1, length + 0.3)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_node(cs, "Shape", ramp)
	ramp.position = Vector3((x_range.x + x_range.y) * 0.5, (y_bottom + y_top) * 0.5 - 0.02, (z_bottom + z_top) * 0.5)
	ramp.rotation.x = angle * signf(-run)
	# Handrails
	for x in [x_range.x, x_range.y]:
		var r := box(holder, Vector3(x - 0.025, -0.025, -length * 0.5), Vector3(x + 0.025, 0.025, length * 0.5),
			"painted_steel_yellow", &"metal", false, "Handrail")
		r.position = Vector3(x, (y_bottom + y_top) * 0.5 + 1.0, (z_bottom + z_top) * 0.5)
		r.rotation.x = angle * signf(-run)


## Safety railing along a straight edge (posts, two rails, kick plate) with an
## invisible collision wall so nobody walks off the catwalk.
func railing(parent: Node, from: Vector3, to: Vector3) -> void:
	var holder := _node(Node3D.new(), _unique("Railing"), parent) as Node3D
	var dir := to - from
	var length := dir.length()
	var along_x := absf(dir.x) > absf(dir.z)
	var posts := maxi(int(ceil(length / 1.6)), 1)
	for i in posts + 1:
		var p := from + dir * (float(i) / posts)
		box(holder, p + Vector3(-0.025, 0, -0.025), p + Vector3(0.025, 1.1, 0.025), "painted_steel_yellow", &"metal", false, "Post")
	for h in [0.55, 1.08]:
		var half := Vector3(0.022, 0.022, 0.022)
		box(holder, from.min(to) + Vector3(0, h, 0) - half, from.max(to) + Vector3(0, h, 0) + half,
			"painted_steel_yellow", &"metal", false, "Rail")
	var kick := Vector3(0.0, 0.0, 0.006) if along_x else Vector3(0.006, 0.0, 0.0)
	box(holder, from.min(to) - kick, from.max(to) + kick + Vector3(0, 0.12, 0), "painted_steel", &"metal", false, "Kick")
	var guard := StaticBody3D.new()
	guard.collision_layer = Layers.CLIP  # blocks movement, not bullets or sight
	guard.set_meta(&"surface", &"metal")
	_node(guard, "Guard", holder)
	var shape := BoxShape3D.new()
	shape.size = Vector3(length if along_x else 0.08, 1.1, 0.08 if along_x else length)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_node(cs, "Shape", guard)
	guard.position = (from + to) * 0.5 + Vector3(0, 0.55, 0)


# --- Building shell ----------------------------------------------------------------

func _shell() -> void:
	var s := _node(Node3D.new(), "Shell", structure)
	# Ground slab (whole footprint)
	box(s, Vector3(-24.4, -0.4, -16.4), Vector3(24.4, 0.0, 16.4), "concrete_floor", &"concrete", true, "Ground")
	# High window band on long walls: openings 3 m wide between piers
	var windows := []
	for cx in [-20.0, -12.0, -4.0, 4.0, 12.0, 20.0]:
		windows.append([cx - 1.5, cx + 1.5, 7.2, 9.8])
	for zc in [-16.2, 16.2]:
		var openings: Array = windows.duplicate()
		wall(s, "z", zc, 0.4, Vector2(-24.4, 24.4), Vector2(0.0, 4.0),
			[[14.0, 20.0, 0.0, 5.0]] if zc > 0.0 else [], "concrete_wall")
		wall(s, "z", zc, 0.4, Vector2(-24.4, 24.4), Vector2(4.0, HEIGHT), openings + ([[14.0, 20.0, 4.0, 5.0]] if zc > 0.0 else []), "brick")
		# Window frames and a few remaining panes
		for w in windows:
			var x0: float = w[0]
			var x1: float = w[1]
			for xm in [x0 + 1.0, x0 + 2.0]:
				box(s, Vector3(xm - 0.04, 7.2, zc - 0.05), Vector3(xm + 0.04, 9.8, zc + 0.05), "rusted_metal", &"metal", false, "Mullion")
			box(s, Vector3(x0, 8.45, zc - 0.05), Vector3(x1, 8.53, zc + 0.05), "rusted_metal", &"metal", false, "Transom")
			if int(x0) % 3 == 0:
				box(s, Vector3(x0 + 0.05, 7.25, zc - 0.01), Vector3(x0 + 0.95, 8.45, zc + 0.01), "glass_dirty", &"metal", false, "Pane")
	# Rolling shutter in the south loading door
	box(s, Vector3(14.0, 0.0, 16.05), Vector3(20.0, 5.0, 16.25), "corrugated_metal", &"metal", true, "Shutter")
	box(s, Vector3(13.8, 5.0, 15.9), Vector3(20.2, 5.5, 16.3), "rusted_metal", &"metal", true, "ShutterBox")
	# End walls
	for xc in [-24.2, 24.2]:
		wall(s, "x", xc, 0.4, Vector2(-16.4, 16.4), Vector2(0.0, 4.0), [], "concrete_wall")
		var ends := [] if xc < 0.0 else [[-10.0, -7.0, 7.2, 9.8], [-1.5, 1.5, 7.2, 9.8], [7.0, 10.0, 7.2, 9.8]]
		wall(s, "x", xc, 0.4, Vector2(-16.4, 16.4), Vector2(4.0, HEIGHT), ends, "brick")
	# Wall-mounted pipe runs along the north wall
	for y in [3.2, 3.5]:
		var pipe := _node(MeshInstance3D.new(), _unique("Pipe"), s) as MeshInstance3D
		var k := MeshKit.new()
		k.at(Vector3(0, y, -15.75), Vector3(0, 90, 0)).cylinder(0.11 if y < 3.3 else 0.07, -23.8, 23.8, m("rusted_metal"), 14)
		pipe.mesh = k.commit()


func _roof() -> void:
	var r := _node(Node3D.new(), "Roof", structure)
	# 4 m panels with a few missing (collapsed) bays that let light shafts in.
	var holes := [Vector2(-4, -8), Vector2(-4, -4), Vector2(-4, 0), Vector2(8, -12), Vector2(12, -12), Vector2(12, 4)]
	var x := -24.0
	while x < 24.0:
		var z := -16.0
		while z < 16.0:
			if not holes.has(Vector2(x, z)):
				box(r, Vector3(x - 0.2 if x == -24.0 else x, HEIGHT, z - 0.2 if z == -16.0 else z),
					Vector3(x + 4.0 + (0.2 if x == 20.0 else 0.0), HEIGHT + 0.15, z + 4.0 + (0.2 if z == 12.0 else 0.0)),
					"corrugated_metal", &"metal", true, "RoofPanel")
			z += 4.0
		x += 4.0
	# Trusses over every column line, purlins every 4 m
	for tx in COLUMNS_X + [-16.0]:
		box(r, Vector3(tx - 0.12, HEIGHT - 0.7, -16.0), Vector3(tx + 0.12, HEIGHT - 0.4, 16.0), "painted_steel", &"metal", true, "Truss")
		box(r, Vector3(tx - 0.08, HEIGHT - 0.4, -16.0), Vector3(tx + 0.08, HEIGHT, 16.0), "rusted_metal", &"metal", false, "TrussWeb")
	var pz := -12.0
	while pz <= 12.0:
		box(r, Vector3(-24.0, HEIGHT - 0.25, pz - 0.06), Vector3(24.0, HEIGHT - 0.05, pz + 0.06), "rusted_metal", &"metal", false, "Purlin")
		pz += 4.0
	# A panel hanging down from a collapsed bay
	var hanging := box(r, Vector3(-2.0, -0.075, -2.0), Vector3(2.0, 0.075, 2.0), "corrugated_metal", &"metal", true, "Fallen")
	hanging.position = Vector3(-2.6, 10.6, -5.4)
	hanging.rotation_degrees = Vector3(52, 12, 8)


func _columns() -> void:
	var c := _node(Node3D.new(), "Columns", structure)
	for x in COLUMNS_X:
		for z in COLUMNS_Z:
			ibeam_column(c, x, z, HEIGHT - 0.4)
	# Crane rails along the column rows, plus an overhead gantry crane
	for z in COLUMNS_Z:
		box(c, Vector3(-14.0, 10.0, z - 0.2), Vector3(24.0, 10.5, z + 0.2), "painted_steel_yellow", &"metal", true, "CraneRail")
	box(c, Vector3(3.4, 10.5, -9.0), Vector3(4.2, 11.2, 9.0), "painted_steel_yellow", &"metal", true, "Gantry")
	box(c, Vector3(3.2, 9.9, -2.6), Vector3(4.4, 10.5, -1.4), "painted_steel", &"metal", true, "Trolley")
	var chain := _node(MeshInstance3D.new(), "Chain", c) as MeshInstance3D
	var k := MeshKit.new()
	k.tube_between(Vector3(3.8, 9.9, -2.0), Vector3(3.8, 6.4, -2.0), 0.02, m("gun_metal"), 6)
	k.box(Vector3(0.45, 0.6, 0.3), Vector3(3.8, 6.1, -2.0), m("painted_steel_yellow"), 0.04)
	k.at(Vector3(3.8, 5.6, -2.0), Vector3(0, 90, 0)).lathe(PackedVector2Array([Vector2(0.06, -0.02), Vector2(0.18, -0.02),
		Vector2(0.18, 0.02), Vector2(0.06, 0.02), Vector2(0.06, -0.02)]), m("gun_metal"), 16, false, false)
	chain.mesh = k.commit()


# --- Office block -------------------------------------------------------------------

func _office_block() -> void:
	var o := _node(Node3D.new(), "OfficeBlock", structure)
	# Wall between hall and office, with doorways onto each level
	wall(o, "x", -14.0, 0.3, Vector2(Z.x, Z.y), Vector2(0.0, HEIGHT), [
		[1.0, 4.0, 0.0, 3.0], [-10.0, -8.6, 0.0, 2.3],  # ground floor
		[-15.4, -13.8, DECK, DECK + 2.3], [-0.7, 0.7, DECK, DECK + 2.3],  # catwalk and bridge doors
		[-11.0, -3.0, DECK + 1.2, DECK + 3.2], [3.0, 11.0, DECK + 1.2, DECK + 3.2],  # office windows
		[-14.0, -2.0, TOP + 1.0, TOP + 2.6],  # control room window
	], "concrete_wall")
	# Floors with stairwell openings
	slab(o, OFFICE_X, Z, DECK, 0.3, [[-23.8, -21.6, 6.0, 14.0]], "concrete_floor")
	slab(o, OFFICE_X, Z, TOP, 0.3, [[-23.8, -21.6, -14.0, -6.0]], "concrete_floor")
	stairs(o, Vector2(-23.8, -21.6), 14.0, 6.0, 0.0, DECK)
	stairs(o, Vector2(-23.8, -21.6), -6.0, -14.0, DECK, TOP)
	# Guard rails around the stairwell openings
	railing(o, Vector3(-21.6, DECK, 6.0), Vector3(-21.6, DECK, 14.0))
	railing(o, Vector3(-21.6, TOP, -14.0), Vector3(-21.6, TOP, -6.0))
	railing(o, Vector3(-23.8, TOP, -6.0), Vector3(-21.6, TOP, -6.0))
	# Floor 2 partitions: corridor wall and a cross wall
	wall(o, "x", -19.0, 0.15, Vector2(Z.x, Z.y), Vector2(DECK, DECK + 3.4),
		[[-9.0, -7.8, DECK, DECK + 2.2], [3.5, 4.7, DECK, DECK + 2.2]], "concrete_wall")
	wall(o, "z", -1.0, 0.15, Vector2(-24.0, -19.0), Vector2(DECK, DECK + 3.4), [[-21.0, -20.0, DECK, DECK + 2.2]], "tiles_dirty")
	# Ground floor: a storeroom partition
	wall(o, "z", -4.0, 0.2, Vector2(-24.0, -14.0), Vector2(0.0, 3.6), [[-18.0, -16.4, 0.0, 2.3]], "brick")
	# Control room partition with doorway and the exit door frame
	wall(o, "z", 0.0, 0.15, Vector2(-24.0, -14.0), Vector2(TOP, HEIGHT), [[-17.0, -15.9, TOP, TOP + 2.2]], "concrete_wall")
	box(o, Vector3(-24.0, TOP, -15.7), Vector3(-23.85, TOP + 2.35, -14.3), "rusted_metal", &"metal", false, "ExitFrame")
	box(o, Vector3(-23.98, TOP, -15.55), Vector3(-23.9, TOP + 2.2, -14.45), "painted_steel_red", &"metal", false, "ExitDoor")
	box(o, Vector3(-23.92, TOP + 1.0, -14.65), Vector3(-23.85, TOP + 1.08, -14.55), "gun_metal", &"metal", false, "ExitHandle")


# --- Catwalks -------------------------------------------------------------------------

func _catwalks() -> void:
	var c := _node(Node3D.new(), "Catwalks", structure)
	var t := 0.08
	# North catwalk, east catwalk, bridge, stair landing
	box(c, Vector3(-14.0, DECK - t, -16.0), Vector3(24.0, DECK, -13.0), "steel_grate", &"metal", true, "Grate")
	box(c, Vector3(21.0, DECK - t, -13.0), Vector3(24.0, DECK, 16.0), "steel_grate", &"metal", true, "Grate")
	box(c, Vector3(-14.0, DECK - t, -1.0), Vector3(21.0, DECK, 1.0), "steel_grate", &"metal", true, "Grate")
	box(c, Vector3(18.6, DECK - t, 4.6), Vector3(21.0, DECK, 6.0), "steel_grate", &"metal", true, "Grate")
	# Support beams and posts
	for x in [-12.0, -4.0, 4.0, 12.0, 20.0]:
		box(c, Vector3(x - 0.1, 0.0, -13.3), Vector3(x + 0.1, DECK - t, -13.1), "painted_steel", &"metal", true, "Post")
	box(c, Vector3(-14.0, DECK - 0.4, -13.3), Vector3(24.0, DECK - t, -13.0), "painted_steel", &"metal", true, "Beam")
	for z in [-8.0, 0.0, 8.0, 15.0]:
		box(c, Vector3(20.9, 0.0, z - 0.1), Vector3(21.1, DECK - t, z + 0.1), "painted_steel", &"metal", true, "Post")
	box(c, Vector3(20.9, DECK - 0.4, -13.0), Vector3(21.2, DECK - t, 16.0), "painted_steel", &"metal", true, "Beam")
	for x in [-6.0, 4.0, 13.0]:
		for z in [-1.1, 1.1]:
			box(c, Vector3(x - 0.08, 0.0, z - 0.08), Vector3(x + 0.08, DECK - t, z + 0.08), "painted_steel", &"metal", true, "Post")
	for z in [-1.0, 1.0]:
		box(c, Vector3(-14.0, DECK - 0.35, z - 0.08), Vector3(21.0, DECK - t, z + 0.08), "painted_steel", &"metal", true, "Beam")
	# Railings (gaps where the bridge and stair meet the east catwalk)
	railing(c, Vector3(-13.85, DECK, -13.0), Vector3(21.0, DECK, -13.0))
	railing(c, Vector3(21.0, DECK, -13.0), Vector3(21.0, DECK, -1.0))
	railing(c, Vector3(21.0, DECK, 1.0), Vector3(21.0, DECK, 4.6))
	railing(c, Vector3(21.0, DECK, 6.0), Vector3(21.0, DECK, 16.0))
	railing(c, Vector3(-13.85, DECK, -1.0), Vector3(21.0, DECK, -1.0))
	railing(c, Vector3(-13.85, DECK, 1.0), Vector3(21.0, DECK, 1.0))
	railing(c, Vector3(18.6, DECK, 4.6), Vector3(21.0, DECK, 4.6))
	stairs(c, Vector2(18.6, 20.8), 14.0, 6.0, 0.0, DECK)


# --- Props ------------------------------------------------------------------------------

func _hall_props() -> void:
	var p := _node(Node3D.new(), "Hall", props)
	prop(p, "machine_press", Vector3(-6.0, 0, -6.5))
	prop(p, "machine_press", Vector3(4.5, 0, -10.0), 90.0)
	prop(p, "machine_press", Vector3(10.5, 0, 4.0))
	prop(p, "tank", Vector3(-2.0, 0, 11.4))
	for x in [-10.0, -6.0, -2.0, 2.0]:
		prop(p, "conveyor", Vector3(x, 0, 3.4))
	for x in [-12.0, -10.0, -8.0]:
		prop(p, "shelf", Vector3(x, 0, 14.6))
	for x in [-12.0, -10.0]:
		prop(p, "shelf", Vector3(x, 0, 11.0), 180.0)
	# Crate stacks and pallets
	prop(p, "crate_wood", Vector3(6.0, 0, 12.6), 8.0)
	prop(p, "crate_wood", Vector3(7.1, 0, 12.8), -5.0)
	prop(p, "crate_wood", Vector3(6.5, 0.8, 12.7), 20.0)
	prop(p, "crate_small", Vector3(7.6, 0, 11.6), 35.0)
	prop(p, "pallet", Vector3(3.2, 0, 13.4), 4.0)
	prop(p, "crate_small", Vector3(3.0, 0.145, 13.4), -10.0)
	prop(p, "pallet", Vector3(14.6, 0, -1.0), 80.0)
	prop(p, "crate_wood", Vector3(18.2, 0, -3.0), 15.0)
	prop(p, "crate_small", Vector3(18.0, 0.8, -3.2), 50.0)
	prop(p, "crate_wood", Vector3(-11.0, 0, -11.5), -12.0)
	# Barrels
	for b in [[12.0, 10.2, "barrel_blue"], [12.65, 10.55, "barrel_rust"], [11.6, 10.85, "barrel_orange"], [22.6, -6.0, "barrel_rust"],
			[22.6, -6.65, "barrel_rust"], [-12.6, 6.0, "barrel_blue"], [0.8, -14.8, "barrel_orange"], [8.4, -1.9, "barrel_rust"]]:
		prop(p, b[2], Vector3(b[0], 0, b[1]), randf() * 360.0)
	# Collapse debris below the broken roof
	prop(p, "rubble", Vector3(-2.2, 0, -3.0), 20.0)
	prop(p, "rubble", Vector3(-3.0, 0, -6.6), 140.0)
	prop(p, "rubble", Vector3(13.6, 0, -11.0), 70.0)
	# Electrical cabinets against the north wall
	for x in [-12.5, -1.5, 10.0]:
		prop(p, "electrical_cabinet", Vector3(x, 0, -15.75), 180.0)
	# Scavenger camp tucked under the catwalk in the north-east corner
	prop(p, "bedroll", Vector3(21.8, 0, -14.6), 90.0)
	prop(p, "fire_pit", Vector3(18.6, 0, -11.8))
	prop(p, "sandbags", Vector3(18.4, 0, -9.6), 0.0)
	prop(p, "crate_small", Vector3(23.2, 0, -12.4), 12.0)
	# Cover on the catwalk
	prop(p, "sandbags", Vector3(6.0, DECK, -13.75), 0.0)
	prop(p, "crate_wood", Vector3(-6.0, DECK, -15.3), 5.0)


func _office_props() -> void:
	var p := _node(Node3D.new(), "Office", props)
	# Ground floor storeroom/workshop
	for i in 4:
		prop(p, "locker", Vector3(-23.65, 0, -15.2 + i * 0.52), -90.0)
	prop(p, "shelf", Vector3(-17.0, 0, -15.3))
	prop(p, "crate_wood", Vector3(-20.0, 0, -7.0), 25.0)
	prop(p, "crate_small", Vector3(-15.4, 0, 9.0), 10.0)
	prop(p, "desk", Vector3(-16.0, 0, 13.6), 180.0)
	prop(p, "filing_cabinet", Vector3(-14.5, 0, 6.0), 90.0)
	# Floor 2 offices
	prop(p, "desk", Vector3(-16.8, DECK, -12.0))
	prop(p, "desk", Vector3(-16.4, DECK, -4.5), 12.0)
	prop(p, "desk", Vector3(-16.8, DECK, 8.5), 180.0)
	prop(p, "desk", Vector3(-21.0, DECK, 1.8), 90.0)
	for z in [-15.2, -14.6]:
		prop(p, "filing_cabinet", Vector3(-14.6, DECK, z + 3.0), 90.0)
	prop(p, "filing_cabinet", Vector3(-18.6, DECK, 12.0), 90.0)
	prop(p, "locker", Vector3(-20.6, DECK, -15.6), 0.0)
	prop(p, "crate_small", Vector3(-22.6, DECK, 15.2), 30.0)
	# Control room
	prop(p, "desk", Vector3(-19.0, TOP, -15.3), 180.0)
	prop(p, "desk", Vector3(-15.0, TOP, -12.0), 90.0)
	prop(p, "electrical_cabinet", Vector3(-17.0, TOP, -15.7), 180.0)
	prop(p, "filing_cabinet", Vector3(-14.6, TOP, -5.0), 90.0)
	prop(p, "rubble", Vector3(-19.0, TOP, 8.0), 60.0)


# --- Lighting & atmosphere ---------------------------------------------------------------

func _environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.3, 0.32, 0.36)
	sky_mat.sky_horizon_color = Color(0.45, 0.46, 0.47)
	sky_mat.ground_bottom_color = Color(0.05, 0.05, 0.05)
	sky_mat.ground_horizon_color = Color(0.3, 0.3, 0.3)
	sky_mat.sun_angle_max = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.35
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.2
	env.ssil_enabled = true
	env.sdfgi_enabled = true
	env.sdfgi_use_occlusion = true
	env.sdfgi_energy = 0.9
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.028
	env.volumetric_fog_albedo = Color(0.72, 0.72, 0.7)
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 70.0
	env.volumetric_fog_ambient_inject = 0.25
	env.volumetric_fog_sky_affect = 0.15
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.78
	env.adjustment_contrast = 1.08
	var we := WorldEnvironment.new()
	we.environment = env
	_node(we, "WorldEnvironment", lvl)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.74, 0.8, 0.9)
	sun.light_energy = 2.2
	sun.light_volumetric_fog_energy = 2.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	_node(sun, "Sun", lvl)
	sun.rotation_degrees = Vector3(-58.0, 28.0, 0.0)


func _light(light: Light3D, node_name: String, pos: Vector3, color: Color, energy: float, shadows := true) -> Light3D:
	light.light_color = color
	light.light_energy = energy
	light.shadow_enabled = shadows
	_node(light, node_name, lights)
	light.position = pos
	return light


func _flicker(light: Light3D, emissive: GeometryInstance3D, amount: float, interval: float, pulse := false) -> void:
	var f := FlickerLight.new()
	f.light = light
	f.emissive_mesh = emissive
	f.flicker_amount = amount
	f.burst_interval = interval
	f.pulse = pulse
	_node(f, "Flicker", light)


func _lighting() -> void:
	var sodium := Color(1.0, 0.72, 0.42)
	var tube := Color(0.82, 0.9, 1.0)
	# Hanging lamps over the hall: two still work, one flickers, two are dead.
	var lamps := [[Vector3(-4.0, 9.6, -6.0), "on"], [Vector3(10.0, 9.6, 4.0), "flicker"], [Vector3(12.0, 9.6, -6.0), "dead"],
		[Vector3(18.0, 9.6, 10.0), "on"], [Vector3(2.0, 9.6, 10.0), "dead"]]
	for lamp in lamps:
		var inst := prop(props, "lamp_hanging", lamp[0])
		var bulb := inst.get_node("Bulb") as MeshInstance3D
		if lamp[1] == "dead":
			bulb.material_override = m("lamp_dead")
			continue
		bulb.material_override = (m("lamp_emissive") as StandardMaterial3D).duplicate()
		var spot := _light(SpotLight3D.new(), _unique("LampLight"), (lamp[0] as Vector3) + Vector3(0, -0.15, 0), sodium, 7.0) as SpotLight3D
		spot.rotation_degrees.x = -90.0
		spot.spot_range = 16.0
		spot.spot_angle = 58.0
		spot.spot_attenuation = 1.2
		spot.light_volumetric_fog_energy = 1.4
		if lamp[1] == "flicker":
			_flicker(spot, bulb, 0.85, 3.0)
	# Office fluorescent tubes
	var tubes := [[Vector3(-16.5, DECK + 3.9, -10.0), "on"], [Vector3(-16.5, DECK + 3.9, 8.0), "flicker"],
		[Vector3(-21.5, DECK + 3.9, -8.0), "dead"], [Vector3(-21.5, DECK + 3.9, 10.0), "flicker"],
		[Vector3(-19.0, TOP + 2.6, -8.0), "flicker"], [Vector3(-19.0, 3.2, 8.0), "on"]]
	var buzz := _audio("ambience/fluorescent_buzz_loop.wav")
	for t in tubes:
		var inst := prop(props, "fluorescent", t[0], 90.0)
		var tube_mesh := inst.get_node("Tubes") as MeshInstance3D
		if t[1] == "dead":
			tube_mesh.material_override = m("lamp_dead")
			continue
		tube_mesh.material_override = (m("lamp_emissive") as StandardMaterial3D).duplicate()
		var omni := _light(OmniLight3D.new(), _unique("TubeLight"), (t[0] as Vector3) + Vector3(0, -0.2, 0), tube, 1.4) as OmniLight3D
		omni.omni_range = 8.0
		omni.omni_attenuation = 1.3
		if t[1] == "flicker":
			_flicker(omni, tube_mesh, 0.9, 2.5)
		if buzz:
			var player := AudioStreamPlayer3D.new()
			player.stream = buzz
			player.autoplay = true
			player.bus = &"World"
			player.volume_db = -10.0
			player.unit_size = 2.0
			player.max_distance = 14.0
			_node(player, "Buzz", omni)
	# Emergency beacon above the exit, and the camp fire's embers
	var beacon := _light(OmniLight3D.new(), "ExitBeacon", Vector3(-23.3, TOP + 2.6, -15.0), Color(1.0, 0.12, 0.08), 1.1) as OmniLight3D
	beacon.omni_range = 5.0
	_flicker(beacon, null, 0.0, 1.0, true)
	var beacon_mesh := _node(MeshInstance3D.new(), "BeaconLamp", lights) as MeshInstance3D
	var k := MeshKit.new()
	k.sphere(0.08, Vector3.ZERO, m("lamp_emissive_red"), 8, 12, Vector3(1, 0.6, 1))
	beacon_mesh.mesh = k.commit()
	beacon_mesh.position = Vector3(-23.85, TOP + 2.55, -15.0)
	var embers := _light(OmniLight3D.new(), "Embers", Vector3(18.6, 0.35, -11.8), Color(1.0, 0.45, 0.15), 1.2) as OmniLight3D
	embers.omni_range = 4.5
	_flicker(embers, null, 0.35, 0.6)
	# Faint fills so unlit corners read as dark, not void
	for f in [[Vector3(-19.0, 2.5, 0.0), 12.0], [Vector3(5.0, 2.5, -14.0), 10.0], [Vector3(-19.0, DECK + 2.5, 0.0), 12.0],
			[Vector3(16.0, 2.0, 12.0), 9.0], [Vector3(22.5, DECK + 2.0, -4.0), 10.0], [Vector3(22.5, DECK + 2.0, 10.0), 10.0],
			[Vector3(-19.0, TOP + 1.8, -8.0), 9.0], [Vector3(-6.0, 3.0, 10.0), 10.0]]:
		var fill := _light(OmniLight3D.new(), _unique("Fill"), f[0], Color(0.6, 0.65, 0.72), 0.6, false) as OmniLight3D
		fill.omni_range = f[1]
		fill.light_volumetric_fog_energy = 0.0
	var probe := ReflectionProbe.new()
	probe.size = Vector3(48, 13, 32)
	probe.interior = true
	probe.box_projection = true
	_node(probe, "ReflectionProbe", lvl)
	probe.position = Vector3(0, 6.5, 0)


func _atmosphere() -> void:
	# Floating dust that catches the light shafts
	var dust := GPUParticles3D.new()
	dust.amount = 700
	dust.lifetime = 24.0
	dust.preprocess = 24.0
	dust.visibility_aabb = AABB(Vector3(-24, -1, -16), Vector3(48, 14, 32))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(23, 6, 15.5)
	process.gravity = Vector3(0, -0.004, 0)
	process.direction = Vector3(1, 0.1, 0)
	process.spread = 180.0
	process.initial_velocity_min = 0.01
	process.initial_velocity_max = 0.06
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.4
	process.turbulence_noise_speed_random = 0.2
	process.scale_min = 0.6
	process.scale_max = 1.4
	dust.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.012, 0.012)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_color = Color(0.85, 0.82, 0.75, 0.55)
	if ResourceLoader.exists("res://assets/textures/fx/dust_mote.png"):
		mat.albedo_texture = load("res://assets/textures/fx/dust_mote.png")
	quad.material = mat
	dust.draw_pass_1 = quad
	dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_node(dust, "Dust", lvl)
	dust.position = Vector3(0, 6.5, 0)
	# Wind moaning through the collapsed roof
	var wind := _audio("ambience/wind_gust_loop.wav")
	if wind:
		for pos in [Vector3(-2.0, 11.5, -4.0), Vector3(12.0, 11.5, -8.0)]:
			var player := AudioStreamPlayer3D.new()
			player.stream = wind
			player.autoplay = true
			player.bus = &"Ambience"
			player.volume_db = -4.0
			player.unit_size = 8.0
			_node(player, _unique("Wind"), lvl)
			player.position = pos


# --- Gameplay markers -------------------------------------------------------------------

func _gameplay() -> void:
	var spawn := Marker3D.new()
	_node(spawn, "PlayerSpawn", lvl)
	spawn.position = Vector3(17.0, 0.05, 13.4)
	spawn.rotation_degrees.y = 25.0
	var route := _node(Node3D.new(), "PatrolCatwalk", lvl) as Node3D
	for i in 6:
		var pts := [Vector3(22.5, DECK, -9.0), Vector3(10.0, DECK, -14.5), Vector3(-11.0, DECK, -14.5),
			Vector3(-11.0, DECK, 0.0), Vector3(9.0, DECK, 0.0), Vector3(22.5, DECK, 3.0)]
		var marker := Marker3D.new()
		_node(marker, "Point%d" % (i + 1), route)
		marker.position = pts[i]
	var enemy = load("res://levels/enemy_spawn.gd").new()
	enemy.enemy_id = &"scavenger"
	enemy.patrol_route = route
	_node(enemy, "RivalSpawn", lvl)
	enemy.position = Vector3(20.0, DECK + 0.05, -14.4)
	enemy.rotation_degrees.y = 90.0
	var cover := _node(Node3D.new(), "Cover", lvl)
	for pos in [Vector3(-6.0, 0, -8.6), Vector3(10.5, 0, 6.2), Vector3(18.4, 0, -8.8), Vector3(6.0, DECK, -14.5),
			Vector3(-2.0, 0, 13.4), Vector3(6.5, 0, 14.0), Vector3(-6.0, DECK, -15.8), Vector3(22.6, DECK, -6.3)]:
		var marker := Marker3D.new()
		_node(marker, _unique("CoverPoint"), cover)
		marker.position = pos
		marker.add_to_group(&"cover", true)
	var exit = load("res://levels/level_exit.gd").new()
	exit.prompt = "Take the service stairs down"
	_node(exit, "Exit", lvl)
	exit.position = Vector3(-23.55, TOP + 1.1, -15.0)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 2.2, 1.3)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_node(cs, "Shape", exit)


func _bake_navigation() -> void:
	var navmesh := NavigationMesh.new()
	navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navmesh.geometry_collision_mask = Layers.WORLD | Layers.CLIP
	navmesh.cell_size = 0.1
	navmesh.cell_height = 0.1
	navmesh.agent_radius = 0.4
	navmesh.agent_height = 1.75
	navmesh.agent_max_climb = 0.35
	navmesh.agent_max_slope = 40.0
	nav.navigation_mesh = navmesh
	nav.bake_navigation_mesh(false)
	var polys := navmesh.get_polygon_count()
	print("build_l1: navmesh polygons: %d" % polys)
	ResourceSaver.save(navmesh, OUT_DIR + "l1_navmesh.res")
	navmesh.take_over_path(OUT_DIR + "l1_navmesh.res")


func _save() -> void:
	var packed := PackedScene.new()
	var err := packed.pack(lvl)
	if err != OK:
		push_error("pack failed: %s" % error_string(err))
	err = ResourceSaver.save(packed, OUT_DIR + "l1_foundry.tscn")
	print("build_l1: saved (%s), nodes: %d" % [error_string(err), _count(lvl)])


func _count(n: Node) -> int:
	var c := 1
	for child in n.get_children():
		c += _count(child)
	return c
