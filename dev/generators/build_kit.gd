extends SceneTree
## Builds reusable level props into res://levels/kit/<name>.tscn with meshes
## in res://assets/models/props/. Each prop is a StaticBody3D tagged with a
## surface (metadata "surface") and simple box/cylinder collision. Lamps are
## plain Node3D roots; levels add the actual lights.
##
##   godot --headless --path . --script res://dev/generators/build_kit.gd

const SCENES := "res://levels/kit/"
const MESHES := "res://assets/models/props/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENES))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MESHES))
	crate("crate_wood", Vector3(1.0, 0.8, 1.0))
	crate("crate_small", Vector3(0.6, 0.5, 0.6))
	for variant in [["barrel_blue", "prop_steel_blue"], ["barrel_rust", "prop_rust"], ["barrel_orange", "prop_steel_orange"]]:
		barrel(variant[0], variant[1])
	pallet()
	shelf()
	machine_press()
	tank()
	conveyor()
	locker()
	desk()
	filing_cabinet()
	electrical_cabinet()
	lamp_hanging()
	fluorescent()
	rubble()
	sandbags()
	bedroll()
	fire_pit()
	cage_lamp()
	shipping_container()
	vat()
	print("build_kit: done")
	quit()


func m(name: String) -> Material:
	return load("res://assets/materials/%s.tres" % name)


static func box_shape(size: Vector3, center: Vector3) -> Array:
	var s := BoxShape3D.new()
	s.size = size
	return [s, Transform3D(Basis.IDENTITY, center)]


static func cyl_shape(radius: float, height: float, center: Vector3, basis := Basis.IDENTITY) -> Array:
	var s := CylinderShape3D.new()
	s.radius = radius
	s.height = height
	return [s, Transform3D(basis, center)]


## meshes: node name -> MeshKit. shapes: [[Shape3D, Transform3D], ...].
func save_prop(id: String, meshes: Dictionary, shapes: Array, surface: StringName) -> void:
	var root: Node3D
	if shapes.is_empty():
		root = Node3D.new()
	else:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta(&"surface", surface)
		root = body
	root.name = id.to_pascal_case()
	for node_name: String in meshes:
		var kit: MeshKit = meshes[node_name]
		var mesh := kit.commit()
		var path := MESHES + "%s_%s.res" % [id, node_name.to_snake_case()]
		ResourceSaver.save(mesh, path)
		mesh.take_over_path(path)
		var mi := MeshInstance3D.new()
		mi.name = node_name
		mi.mesh = mesh
		root.add_child(mi)
		mi.owner = root
	for i in shapes.size():
		var cs := CollisionShape3D.new()
		cs.name = "Shape%d" % i
		cs.shape = shapes[i][0]
		cs.transform = shapes[i][1]
		root.add_child(cs)
		cs.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, SCENES + id + ".tscn")
	print("  ", id)
	root.free()


# --- Props ------------------------------------------------------------------------

func crate(id: String, size: Vector3) -> void:
	var wood := m("prop_wood")
	var k := MeshKit.new()
	var h := size * 0.5
	k.box(size - Vector3(0.04, 0.04, 0.04), Vector3(0, h.y, 0), wood, 0.01)
	var b := 0.07  # batten width
	# Edge battens on all 12 edges
	for sy in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			k.box(Vector3(size.x, b, b), Vector3(0, h.y + sy * (h.y - b * 0.5), sz * (h.z - b * 0.5)), wood, 0.008)
		for sx in [-1.0, 1.0]:
			k.box(Vector3(b, b, size.z), Vector3(sx * (h.x - b * 0.5), h.y + sy * (h.y - b * 0.5), 0), wood, 0.008)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			k.box(Vector3(b, size.y, b), Vector3(sx * (h.x - b * 0.5), h.y, sz * (h.z - b * 0.5)), wood, 0.008)
	# Diagonal brace on the long faces
	var diag := atan2(size.y - b * 2, size.x - b * 2)
	for sz in [-1.0, 1.0]:
		k.at(Vector3(0, h.y, sz * (h.z - 0.005)), Vector3(0, 0, rad_to_deg(diag))).box(
			Vector3(Vector2(size.x, size.y).length() - b * 2.2, b * 0.9, 0.02), Vector3.ZERO, wood, 0.006)
	k.reset()
	save_prop(id, {"Mesh": k}, [box_shape(size, Vector3(0, h.y, 0))], &"wood")


func barrel(id: String, mat_name: String) -> void:
	var steel := m(mat_name)
	var k := MeshKit.new()
	var r := 0.29
	var pts := PackedVector2Array([Vector2(0.0, 0.0), Vector2(r - 0.01, 0.0), Vector2(r, 0.015), Vector2(r - 0.008, 0.03)])
	for ring_y in [0.29, 0.59]:
		pts.append(Vector2(r - 0.008, ring_y - 0.03))
		pts.append(Vector2(r + 0.006, ring_y - 0.01))
		pts.append(Vector2(r + 0.006, ring_y + 0.01))
		pts.append(Vector2(r - 0.008, ring_y + 0.03))
	pts.append_array(PackedVector2Array([Vector2(r - 0.008, 0.85), Vector2(r, 0.865), Vector2(r - 0.01, 0.88),
		Vector2(r - 0.03, 0.875), Vector2(0.0, 0.875)]))
	k.at(Vector3.ZERO, Vector3(-90, 0, 0)).lathe(pts, steel, 24)
	k.at(Vector3(0.12, 0.875, 0.05), Vector3(-90, 0, 0)).cylinder(0.03, 0.0, 0.012, steel, 10)
	k.reset()
	save_prop(id, {"Mesh": k}, [cyl_shape(r, 0.88, Vector3(0, 0.44, 0))], &"metal")


func pallet() -> void:
	var wood := m("prop_wood")
	var k := MeshKit.new()
	for i in 5:
		k.box(Vector3(1.2, 0.022, 0.14), Vector3(0, 0.133, -0.43 + i * 0.215), wood, 0.004)
	for x in [-0.55, 0.0, 0.55]:
		k.box(Vector3(0.1, 0.08, 1.0), Vector3(x, 0.08, 0), wood, 0.006)
	for z in [-0.43, 0.0, 0.43]:
		k.box(Vector3(1.2, 0.022, 0.14), Vector3(0, 0.011, z), wood, 0.004)
	save_prop("pallet", {"Mesh": k}, [box_shape(Vector3(1.2, 0.145, 1.0), Vector3(0, 0.072, 0))], &"wood")


func shelf() -> void:
	var upright := m("prop_steel_orange")
	var beam := m("prop_steel_blue")
	var deck := m("prop_steel")
	var wood := m("prop_wood")
	var k := MeshKit.new()
	var shapes := []
	for x in [-1.0, 1.0]:
		for z in [-0.28, 0.28]:
			k.box(Vector3(0.08, 2.6, 0.06), Vector3(x, 1.3, z), upright, 0.006)
			shapes.append(box_shape(Vector3(0.08, 2.6, 0.06), Vector3(x, 1.3, z)))
		for y in [0.4, 1.2, 2.0]:
			k.box(Vector3(0.03, 0.03, 0.56), Vector3(x, y, 0), upright, 0.004)  # side bracing
	for y in [0.15, 1.05, 1.95]:
		for z in [-0.28, 0.28]:
			k.box(Vector3(2.0, 0.1, 0.05), Vector3(0, y, z), beam, 0.008)
		k.box(Vector3(1.94, 0.03, 0.6), Vector3(0, y + 0.06, 0), deck, 0.004)
		shapes.append(box_shape(Vector3(2.08, 0.14, 0.64), Vector3(0, y + 0.02, 0)))
	# Stored crates and sacks
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	for y in [0.225, 1.125, 2.025]:
		var x := -0.85
		while x < 0.75:
			var w := rng.randf_range(0.3, 0.55)
			if rng.randf() < 0.75:
				var hgt := rng.randf_range(0.25, 0.6)
				k.box(Vector3(w - 0.04, hgt, 0.5), Vector3(x + w * 0.5, y + hgt * 0.5, rng.randf_range(-0.04, 0.04)), wood, 0.02)
			x += w
	save_prop("shelf", {"Mesh": k}, shapes, &"metal")


func machine_press() -> void:
	var paint := m("prop_steel")
	var rust := m("prop_rust")
	var dark := m("gun_metal")
	var k := MeshKit.new()
	k.box(Vector3(2.4, 0.9, 1.7), Vector3(0, 0.45, 0), paint, 0.04)  # base
	k.box(Vector3(1.6, 0.25, 1.2), Vector3(0, 1.0, 0), rust, 0.02)  # bolster
	for x in [-0.95, 0.95]:
		k.box(Vector3(0.4, 2.6, 0.9), Vector3(x, 2.0, 0), paint, 0.04)  # columns
	k.box(Vector3(2.8, 0.9, 1.4), Vector3(0, 3.6, 0), paint, 0.05)  # crown
	k.box(Vector3(1.4, 0.5, 1.0), Vector3(0, 2.6, 0), rust, 0.03)  # ram
	k.box(Vector3(0.25, 0.4, 0.25), Vector3(0, 3.0, 0), dark, 0.02)
	# Flywheel and motor on the side
	k.at(Vector3(1.5, 3.6, 0), Vector3(0, 90, 0)).cylinder(0.75, -0.12, 0.12, rust, 28, 0.02)
	k.at(Vector3(1.5, 3.6, 0), Vector3(0, 90, 0)).cylinder(0.12, -0.25, 0.25, dark, 12)
	k.at(Vector3(-1.55, 3.4, 0), Vector3(0, 90, 0)).cylinder(0.32, -0.25, 0.4, paint, 18, 0.03)
	k.reset()
	# Control box with buttons
	k.box(Vector3(0.35, 0.55, 0.22), Vector3(-1.45, 1.4, -0.6), paint, 0.02)
	for i in 3:
		k.at(Vector3(-1.45, 1.55 - i * 0.12, -0.72)).cylinder(0.025, 0.0, -0.03, m("painted_steel_red") if i == 0 else dark, 10)
	k.reset()
	k.at(Vector3(-1.45, 0.9, -0.6)).tube_between(Vector3(0, 0.0, 0), Vector3(0, 0.22, 0), 0.025, dark)
	k.reset()
	save_prop("machine_press", {"Mesh": k}, [
		box_shape(Vector3(2.4, 1.15, 1.7), Vector3(0, 0.57, 0)),
		box_shape(Vector3(0.4, 2.6, 0.9), Vector3(-0.95, 2.0, 0)),
		box_shape(Vector3(0.4, 2.6, 0.9), Vector3(0.95, 2.0, 0)),
		box_shape(Vector3(2.8, 0.9, 1.4), Vector3(0, 3.6, 0)),
	], &"metal")


func tank() -> void:
	var rust := m("prop_rust")
	var paint := m("prop_steel")
	var k := MeshKit.new()
	var r := 1.1
	var pts := PackedVector2Array()
	for i in 7:
		var a := PI * 0.5 * i / 6.0
		pts.append(Vector2(sin(a) * r, -2.2 - cos(a) * 0.45))
	for i in 7:
		var a := PI * 0.5 + PI * 0.5 * i / 6.0
		pts.append(Vector2(sin(a) * r, 2.2 - cos(a) * 0.45))
	k.at(Vector3(0, 1.55, 0), Vector3(0, 90, 0)).lathe(pts, rust, 28)
	for z in [-1.2, 1.2]:
		k.at(Vector3(z, 0.0, 0)).box(Vector3(0.3, 1.0, 1.9), Vector3(0, 0.5, 0), paint, 0.03)
	k.reset()
	k.reset()
	k.tube_between(Vector3(-0.8, 2.55, 0.0), Vector3(-0.8, 3.4, 0.0), 0.09, rust)
	k.tube_between(Vector3(-0.8, 3.4, 0.0), Vector3(-2.6, 3.4, 0.0), 0.09, rust)
	k.box(Vector3(0.5, 0.15, 0.5), Vector3(0.6, 2.68, 0), paint, 0.02)  # manway
	save_prop("tank", {"Mesh": k}, [
		cyl_shape(r, 5.3, Vector3(0, 1.55, 0), Basis(Vector3.BACK, PI * 0.5)),
		box_shape(Vector3(2.7, 1.0, 1.9), Vector3(0, 0.5, 0)),
	], &"metal")


func conveyor() -> void:
	var paint := m("prop_steel")
	var steel := m("gun_metal")
	var rubber := m("prop_rubber")
	var k := MeshKit.new()
	var length := 4.0
	for z in [-0.42, 0.42]:
		k.box(Vector3(length, 0.18, 0.06), Vector3(0, 0.82, z), paint, 0.01)
	var x := -length * 0.5 + 0.15
	while x < length * 0.5:
		k.at(Vector3(x, 0.85, 0)).cylinder(0.05, -0.4, 0.4, steel, 10)
		x += 0.3
	k.reset()
	k.box(Vector3(length - 0.2, 0.02, 0.76), Vector3(0, 0.905, 0), rubber, 0.004)
	for lx in [-1.6, 0.0, 1.6]:
		for z in [-0.4, 0.4]:
			k.box(Vector3(0.06, 0.75, 0.06), Vector3(lx, 0.37, z), paint, 0.005)
		k.box(Vector3(0.05, 0.05, 0.8), Vector3(lx, 0.2, 0), paint, 0.005)
	save_prop("conveyor", {"Mesh": k}, [box_shape(Vector3(length, 0.3, 0.9), Vector3(0, 0.78, 0))], &"metal")


func locker() -> void:
	var paint := m("prop_steel_blue")
	var dark := m("gun_metal")
	var k := MeshKit.new()
	k.box(Vector3(0.5, 1.9, 0.5), Vector3(0, 0.95, 0), paint, 0.01)
	k.box(Vector3(0.44, 1.78, 0.012), Vector3(0, 0.96, -0.255), paint, 0.003)  # door
	for i in 4:
		k.box(Vector3(0.24, 0.012, 0.006), Vector3(0, 1.62 + i * 0.035, -0.263), dark, 0.0)  # vents
	k.box(Vector3(0.03, 0.12, 0.02), Vector3(0.17, 1.0, -0.27), dark, 0.004)  # handle
	save_prop("locker", {"Mesh": k}, [box_shape(Vector3(0.5, 1.9, 0.5), Vector3(0, 0.95, 0))], &"metal")


func desk() -> void:
	var wood := m("prop_wood")
	var steel := m("prop_steel")
	var k := MeshKit.new()
	k.box(Vector3(1.4, 0.04, 0.7), Vector3(0, 0.74, 0), wood, 0.008)
	k.box(Vector3(0.42, 0.66, 0.64), Vector3(0.45, 0.37, 0), steel, 0.01)  # drawer pedestal
	for i in 3:
		k.box(Vector3(0.38, 0.19, 0.01), Vector3(0.45, 0.58 - i * 0.21, -0.325), steel, 0.004)
		k.box(Vector3(0.1, 0.015, 0.015), Vector3(0.45, 0.62 - i * 0.21, -0.335), m("gun_metal"), 0.003)
	for x in [-0.66]:
		for z in [-0.31, 0.31]:
			k.box(Vector3(0.04, 0.72, 0.04), Vector3(x, 0.36, z), steel, 0.005)
	k.box(Vector3(0.04, 0.3, 0.6), Vector3(-0.66, 0.55, 0), steel, 0.004)  # modesty panel
	save_prop("desk", {"Mesh": k}, [
		box_shape(Vector3(1.4, 0.06, 0.7), Vector3(0, 0.73, 0)),
		box_shape(Vector3(0.42, 0.7, 0.64), Vector3(0.45, 0.36, 0)),
	], &"wood")


func filing_cabinet() -> void:
	var steel := m("prop_steel")
	var dark := m("gun_metal")
	var k := MeshKit.new()
	k.box(Vector3(0.5, 1.32, 0.65), Vector3(0, 0.66, 0), steel, 0.01)
	for i in 4:
		var y := 0.18 + i * 0.32
		k.box(Vector3(0.46, 0.29, 0.012), Vector3(0, y, -0.33), steel, 0.004)
		k.box(Vector3(0.12, 0.02, 0.02), Vector3(0, y + 0.06, -0.345), dark, 0.004)
	save_prop("filing_cabinet", {"Mesh": k}, [box_shape(Vector3(0.5, 1.32, 0.65), Vector3(0, 0.66, 0))], &"metal")


func electrical_cabinet() -> void:
	var steel := m("prop_steel")
	var dark := m("gun_metal")
	var yellow := m("painted_steel_yellow")
	var k := MeshKit.new()
	k.box(Vector3(0.9, 1.8, 0.4), Vector3(0, 0.9, 0), steel, 0.01)
	for x in [-0.22, 0.22]:
		k.box(Vector3(0.42, 1.7, 0.01), Vector3(x, 0.9, -0.205), steel, 0.003)
		k.box(Vector3(0.02, 0.1, 0.03), Vector3(x + (0.17 if x < 0 else -0.17), 1.0, -0.22), dark, 0.004)
	k.box(Vector3(0.18, 0.12, 0.004), Vector3(-0.22, 1.5, -0.212), yellow, 0.0)  # warning plate
	k.tube_between(Vector3(0.3, 1.8, 0.0), Vector3(0.3, 3.5, 0.0), 0.04, dark)
	k.tube_between(Vector3(-0.3, 1.8, 0.0), Vector3(-0.3, 3.5, 0.0), 0.03, dark)
	save_prop("electrical_cabinet", {"Mesh": k}, [box_shape(Vector3(0.9, 1.8, 0.4), Vector3(0, 0.9, 0))], &"metal")


func lamp_hanging() -> void:
	var steel := m("prop_steel")
	var k := MeshKit.new()
	k.at(Vector3.ZERO, Vector3(90, 0, 0)).lathe(PackedVector2Array([Vector2(0.04, -0.02), Vector2(0.07, 0.0),
		Vector2(0.11, 0.08), Vector2(0.28, 0.25), Vector2(0.29, 0.27)]), steel, 20, false, false)
	k.at(Vector3.ZERO, Vector3(90, 0, 0)).lathe(PackedVector2Array([Vector2(0.285, 0.265), Vector2(0.1, 0.075),
		Vector2(0.065, 0.005)]), steel, 20, false, false)  # inside of the shade
	k.reset()
	k.tube_between(Vector3(0, 0.0, 0), Vector3(0, 2.5, 0), 0.008, m("gun_metal"))
	var bulb := MeshKit.new()
	bulb.sphere(0.065, Vector3(0, -0.12, 0), m("lamp_emissive"), 8, 12)
	save_prop("lamp_hanging", {"Shade": k, "Bulb": bulb}, [], &"metal")


func fluorescent() -> void:
	var steel := m("prop_steel")
	var k := MeshKit.new()
	k.box(Vector3(1.3, 0.07, 0.24), Vector3(0, 0.035, 0), steel, 0.008)
	for z in [-0.09, 0.09]:
		k.box(Vector3(1.3, 0.04, 0.012), Vector3(0, -0.01, z), steel, 0.002)
	k.tube_between(Vector3(-0.5, 0.07, 0), Vector3(-0.5, 1.2, 0), 0.004, m("gun_metal"))
	k.tube_between(Vector3(0.5, 0.07, 0), Vector3(0.5, 1.2, 0), 0.004, m("gun_metal"))
	var tubes := MeshKit.new()
	for z in [-0.05, 0.05]:
		tubes.at(Vector3(0, -0.02, z), Vector3(0, 90, 0)).cylinder(0.016, -0.6, 0.6, m("lamp_emissive"), 8)
	tubes.reset()
	save_prop("fluorescent", {"Housing": k, "Tubes": tubes}, [], &"metal")


func rubble() -> void:
	var concrete := m("concrete_wall")
	var dark := m("gun_metal")
	var k := MeshKit.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 26:
		var size := Vector3(rng.randf_range(0.15, 0.7), rng.randf_range(0.08, 0.35), rng.randf_range(0.15, 0.6))
		var dist := rng.randf_range(0.0, 1.0) ** 0.7 * 1.3
		var a := rng.randf() * TAU
		var pos := Vector3(cos(a) * dist, size.y * 0.4 + (1.3 - dist) * 0.25, sin(a) * dist)
		k.at(pos, Vector3(rng.randf_range(-25, 25), rng.randf() * 360.0, rng.randf_range(-25, 25))).box(size, Vector3.ZERO, concrete, 0.02)
	for i in 5:
		var a := rng.randf() * TAU
		var start := Vector3(cos(a) * 0.4, 0.3, sin(a) * 0.4)
		k.reset().tube_between(start, start + Vector3(rng.randf_range(-0.6, 0.6), rng.randf_range(0.2, 0.7), rng.randf_range(-0.6, 0.6)), 0.008, dark, 6)
	k.reset()
	save_prop("rubble", {"Mesh": k}, [box_shape(Vector3(2.0, 0.45, 2.0), Vector3(0, 0.2, 0))], &"concrete")


func sandbags() -> void:
	var canvas := m("fabric_canvas")
	var k := MeshKit.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for row in 4:
		var offset := 0.2 if row % 2 == 1 else 0.0
		var count := 4 if row % 2 == 0 else 3
		for i in count:
			var x := -0.6 + offset + i * 0.4 + rng.randf_range(-0.02, 0.02)
			k.at(Vector3(x, 0.09 + row * 0.16, rng.randf_range(-0.02, 0.02)), Vector3(0, 90 + rng.randf_range(-6, 6), 0))
			k.capsule(0.13, -0.2, 0.2, canvas, 12, Vector3(1.0, 0.62, 1.0))
	k.reset()
	save_prop("sandbags", {"Mesh": k}, [box_shape(Vector3(1.6, 0.66, 0.36), Vector3(0, 0.33, 0))], &"concrete")


func bedroll() -> void:
	var canvas := m("fabric_canvas")
	var dark := m("fabric_dark")
	var k := MeshKit.new()
	k.box(Vector3(0.75, 0.06, 1.9), Vector3(0, 0.03, 0), dark, 0.025)
	k.at(Vector3(0, 0.11, -0.8), Vector3(0, 90, 0)).capsule(0.1, -0.33, 0.33, canvas, 12)
	k.reset()
	k.box(Vector3(0.45, 0.4, 0.25), Vector3(0.6, 0.2, 0.6), canvas, 0.05)  # pack
	save_prop("bedroll", {"Mesh": k}, [], &"wood")


## Wall-mounted bulb in a wire cage. Faces +Z (wall at z = 0).
func cage_lamp() -> void:
	var steel := m("prop_steel")
	var dark := m("gun_metal")
	var k := MeshKit.new()
	k.at(Vector3(0, 0, 0.0), Vector3(0, 0, 0)).cylinder(0.07, 0.0, 0.03, steel, 14, 0.005)  # wall plate
	k.reset()
	k.cylinder(0.045, 0.03, 0.12, steel, 12, 0.004)  # socket
	for i in 6:
		var a := TAU * i / 6.0
		k.tube_between(Vector3(cos(a) * 0.05, sin(a) * 0.05, 0.12), Vector3(cos(a) * 0.075, sin(a) * 0.075, 0.2), 0.004, dark, 4)
		k.tube_between(Vector3(cos(a) * 0.075, sin(a) * 0.075, 0.2), Vector3(cos(a) * 0.02, sin(a) * 0.02, 0.29), 0.004, dark, 4)
	k.at(Vector3(0, 0, 0.2)).lathe(PackedVector2Array([Vector2(0.078, -0.005), Vector2(0.078, 0.005)]), dark, 12, false, false)
	k.reset()
	var bulb := MeshKit.new()
	bulb.sphere(0.04, Vector3(0, 0, 0.17), m("lamp_emissive"), 8, 10, Vector3(1, 1, 1.3))
	save_prop("cage_lamp", {"Mesh": k, "Bulb": bulb}, [], &"metal")


## 20 ft shipping container, doors at +X.
func shipping_container() -> void:
	var body := m("corrugated_metal")
	var frame := m("prop_rust")
	var k := MeshKit.new()
	var L := 6.06
	var W := 2.44
	var Hh := 2.59
	k.box(Vector3(L - 0.1, Hh - 0.1, W - 0.1), Vector3(0, Hh * 0.5, 0), body, 0.02)
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			k.box(Vector3(0.16, Hh, 0.16), Vector3(x * (L * 0.5 - 0.08), Hh * 0.5, z * (W * 0.5 - 0.08)), frame, 0.01)
	for y in [0.08, Hh - 0.08]:
		for z in [-1.0, 1.0]:
			k.box(Vector3(L, 0.16, 0.14), Vector3(0, y, z * (W * 0.5 - 0.07)), frame, 0.01)
		for x in [-1.0, 1.0]:
			k.box(Vector3(0.14, 0.16, W), Vector3(x * (L * 0.5 - 0.07), y, 0), frame, 0.01)
	# Door locking bars
	for z in [-0.75, -0.35, 0.35, 0.75]:
		k.at(Vector3(L * 0.5 + 0.02, 0, z)).tube_between(Vector3(0, 0.25, 0), Vector3(0, Hh - 0.25, 0), 0.02, frame, 6)
	k.reset()
	save_prop("shipping_container", {"Mesh": k}, [box_shape(Vector3(L, Hh, W), Vector3(0, Hh * 0.5, 0))], &"metal")


## Open-top processing vat on legs, with a rim and an outlet pipe.
func vat() -> void:
	var steel := m("prop_steel")
	var rust := m("prop_rust")
	var k := MeshKit.new()
	var r := 1.2
	k.at(Vector3(0, 0, 0), Vector3(-90, 0, 0)).lathe(PackedVector2Array([Vector2(0.0, 0.35), Vector2(r - 0.25, 0.4),
		Vector2(r, 0.7), Vector2(r, 2.2), Vector2(r + 0.06, 2.22), Vector2(r + 0.06, 2.28), Vector2(r - 0.05, 2.28),
		Vector2(r - 0.05, 0.75), Vector2(0.0, 0.5)]), steel, 28, false, false)
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		k.reset().tube_between(Vector3(cos(a) * (r - 0.15), 0.0, sin(a) * (r - 0.15)), Vector3(cos(a) * (r - 0.15), 0.8, sin(a) * (r - 0.15)), 0.06, rust, 8)
	k.reset()
	k.tube_between(Vector3(0, 0.4, 0), Vector3(0, 0.15, 0), 0.08, rust, 10)
	k.tube_between(Vector3(0, 0.15, 0), Vector3(r + 0.6, 0.15, 0), 0.08, rust, 10)
	k.at(Vector3(r + 0.6, 0.15, 0), Vector3(0, 90, 0)).cylinder(0.12, -0.03, 0.03, rust, 12)
	k.reset()
	save_prop("vat", {"Mesh": k}, [cyl_shape(r + 0.06, 2.28, Vector3(0, 1.14, 0))], &"metal")


func fire_pit() -> void:
	var concrete := m("concrete_dark")
	var wood := m("prop_wood")
	var k := MeshKit.new()
	for i in 9:
		var a := TAU * i / 9.0
		k.sphere(0.11, Vector3(cos(a) * 0.4, 0.06, sin(a) * 0.4), concrete, 6, 8, Vector3(1.2, 0.7, 1.0))
	for i in 4:
		var a := TAU * i / 4.0 + 0.4
		k.tube_between(Vector3(cos(a) * 0.28, 0.03, sin(a) * 0.28), Vector3(-cos(a) * 0.05, 0.16, -sin(a) * 0.05), 0.035, wood, 8)
	save_prop("fire_pit", {"Mesh": k}, [], &"concrete")
