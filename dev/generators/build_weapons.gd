extends SceneTree
## Builds the procedural weapon and attachment models into
## res://assets/models/weapons/<id>/<id>.tscn (+ mesh .res files).
## Each model follows the WeaponModel marker contract (weapons/weapon_model.gd).
## Replace a generated model by pointing the WeaponData at another scene with
## the same markers; this script is only the bootstrap.
##
##   godot --headless --path . --script res://dev/generators/build_weapons.gd

const OUT := "res://assets/models/weapons/"
const ATTACH_OUT := "res://assets/models/attachments/"


func _initialize() -> void:
	build_ak47()
	build_m16()
	build_mp5()
	build_m40()
	build_m1911()
	build_scope_m40()
	print("build_weapons: done")
	quit()


# --- Helpers ------------------------------------------------------------------

func m(name: String) -> Material:
	return load("res://assets/materials/%s.tres" % name)


static func P(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(p[0], p[1]))
	return out


## Curved magazine side profile from two edges sampled on t in [0, 1].
static func curved_mag(rear: Callable, front: Callable, steps := 10) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps + 1:
		pts.append(front.call(float(i) / steps))
	for i in range(steps, -1, -1):
		pts.append(rear.call(float(i) / steps))
	return pts


## Ribbed lathe profile between z0 and z1 (z0 > z1), alternating radii.
static func ribbed(r_hi: float, r_lo: float, z0: float, z1: float, ribs: int) -> PackedVector2Array:
	var pts := PackedVector2Array([Vector2(r_lo * 0.7, z0)])
	var step := (z1 - z0) / ribs
	for i in ribs:
		var za := z0 + step * i
		pts.append(Vector2(r_hi, za + step * 0.08))
		pts.append(Vector2(r_hi, za + step * 0.62))
		pts.append(Vector2(r_lo, za + step * 0.70))
		pts.append(Vector2(r_lo, za + step * 0.98))
	pts.append(Vector2(r_lo * 0.7, z1))
	return pts


## Saves a weapon model scene. parts: node name -> MeshKit. "Body" becomes a
## MeshInstance3D; any other part becomes a Node3D with a MeshInstance3D
## child so it can animate. markers: name -> Vector3 or Transform3D.
func save_model(dir: String, id: String, parts: Dictionary, markers: Dictionary, props: Dictionary,
		script_path := "res://weapons/weapon_model.gd") -> void:
	var folder := dir + id + "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var root := Node3D.new()
	root.name = id.to_pascal_case()
	if script_path != "":
		root.set_script(load(script_path))
	for key: String in props:
		root.set(key, props[key])
	for part_name: String in parts:
		var kit: MeshKit = parts[part_name]
		if kit.is_empty():
			continue
		var mesh := kit.commit()
		var mesh_path := folder + "%s_%s.res" % [id, part_name.to_snake_case()]
		ResourceSaver.save(mesh, mesh_path)
		mesh.take_over_path(mesh_path)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		if part_name == "Body":
			mi.name = "Body"
			root.add_child(mi)
			mi.owner = root
		else:
			var holder := Node3D.new()
			holder.name = part_name
			root.add_child(holder)
			holder.owner = root
			mi.name = "Mesh"
			holder.add_child(mi)
			mi.owner = root
	for marker_name: String in markers:
		var marker := Marker3D.new()
		marker.name = marker_name
		var value: Variant = markers[marker_name]
		marker.transform = value if value is Transform3D else Transform3D(Basis.IDENTITY, value)
		marker.gizmo_extents = 0.02
		root.add_child(marker)
		marker.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, folder + id + ".tscn")
	print("  %s -> %s (%s)" % [id, folder + id + ".tscn", error_string(err)])
	root.free()


# --- AK-47 --------------------------------------------------------------------

func build_ak47() -> void:
	var metal := m("gun_metal")
	var wood := m("gun_wood")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()

	# Stamped receiver with magazine well
	body.extrude(P([[0.0, -0.046], [0.0, 0.010], [-0.305, 0.010], [-0.305, -0.028], [-0.212, -0.028],
		[-0.204, -0.050], [-0.118, -0.050], [-0.108, -0.046]]), 0.044, metal, 0.004)
	# Dust cover: rounded top section running along the receiver
	var arc := PackedVector2Array()
	for i in 13:
		var a := PI * i / 12.0
		arc.append(Vector2(cos(a) * 0.0215, 0.009 + sin(a) * 0.017))
	body.at(Vector3(0, 0, -0.13), Vector3(0, 90, 0)).extrude(arc, 0.24, metal, 0.002)
	body.reset()
	# Rear sight block, leaf and notch
	body.box(Vector3(0.032, 0.02, 0.034), Vector3(0, 0.018, -0.29), metal, 0.003)
	body.box(Vector3(0.024, 0.007, 0.065), Vector3(0, 0.031, -0.27), metal, 0.002)
	body.box(Vector3(0.007, 0.012, 0.006), Vector3(0.0085, 0.040, -0.245), metal, 0.001)
	body.box(Vector3(0.007, 0.012, 0.006), Vector3(-0.0085, 0.040, -0.245), metal, 0.001)
	# Gas tube with upper handguard
	body.at(Vector3(0, 0.028, 0)).cylinder(0.0115, -0.31, -0.475, metal, 14)
	body.at(Vector3(0, 0.029, 0)).cylinder(0.0165, -0.312, -0.432, wood, 18, 0.005)
	body.reset()
	# Barrel, gas block, front sight, slant brake
	body.cylinder(0.0105, -0.30, -0.588, metal, 14)
	body.box(Vector3(0.026, 0.05, 0.03), Vector3(0, 0.012, -0.476), metal, 0.004)
	body.box(Vector3(0.024, 0.024, 0.036), Vector3(0, 0.008, -0.556), metal, 0.004)
	body.box(Vector3(0.003, 0.028, 0.003), Vector3(0, 0.034, -0.562), metal)
	body.box(Vector3(0.003, 0.032, 0.012), Vector3(0.011, 0.034, -0.562), metal, 0.001)
	body.box(Vector3(0.003, 0.032, 0.012), Vector3(-0.011, 0.034, -0.562), metal, 0.001)
	body.lathe(PackedVector2Array([Vector2(0.0125, -0.588), Vector2(0.0125, -0.612), Vector2(0.0105, -0.622)]), metal, 14)
	body.box(Vector3(0.012, 0.012, 0.02), Vector3(0, -0.017, -0.545), metal, 0.002)
	body.at(Vector3(0, -0.021, 0)).cylinder(0.003, -0.44, -0.585, metal, 6)
	body.reset()
	# Lower handguard and retaining ferrule
	body.extrude(P([[-0.305, 0.004], [-0.452, 0.004], [-0.458, -0.010], [-0.450, -0.031], [-0.420, -0.036],
		[-0.390, -0.033], [-0.360, -0.036], [-0.330, -0.036], [-0.310, -0.030]]), 0.052, wood, 0.01)
	body.box(Vector3(0.05, 0.048, 0.012), Vector3(0, -0.006, -0.459), metal, 0.003)
	# Pistol grip
	body.extrude(P([[-0.078, -0.040], [-0.032, -0.040], [0.006, -0.140], [0.002, -0.153], [-0.026, -0.157],
		[-0.040, -0.150], [-0.050, -0.128]]), 0.034, wood, 0.009)
	# Trigger guard and trigger
	body.box(Vector3(0.012, 0.004, 0.064), Vector3(0, -0.073, -0.097), metal, 0.001)
	body.box(Vector3(0.012, 0.028, 0.004), Vector3(0, -0.060, -0.128), metal, 0.001)
	body.extrude(P([[-0.086, -0.046], [-0.095, -0.046], [-0.094, -0.060], [-0.089, -0.068], [-0.084, -0.066],
		[-0.088, -0.057]]), 0.006, metal, 0.001)
	# Selector lever (right side) and magazine catch
	body.at(Vector3(0.0235, -0.006, -0.12), Vector3(-4, 0, 0)).box(Vector3(0.003, 0.012, 0.12), Vector3.ZERO, metal, 0.001)
	body.reset()
	body.box(Vector3(0.02, 0.018, 0.008), Vector3(0, -0.058, -0.112), metal, 0.002)
	# Stock, tang and butt plate
	body.extrude(P([[0.0, -0.002], [0.0, -0.046], [0.05, -0.075], [0.255, -0.150], [0.262, -0.148],
		[0.262, -0.036], [0.25, -0.032]]), 0.04, wood, 0.009)
	body.box(Vector3(0.03, 0.008, 0.05), Vector3(0, -0.004, 0.02), metal, 0.002)
	body.at(Vector3(0, -0.092, 0.265), Vector3(-1.5, 0, 0)).box(Vector3(0.043, 0.118, 0.006), Vector3.ZERO, metal, 0.002)
	body.reset()

	# Curved 30-round magazine with stiffening ribs
	var rear := func(t: float) -> Vector2: return Vector2(-0.118 - 0.018 * t - 0.075 * t * t, -0.044 - 0.198 * t)
	var front := func(t: float) -> Vector2: return Vector2(-0.205 - 0.010 * t - 0.088 * t * t, -0.044 - 0.188 * t)
	mag.extrude(curved_mag(rear, front), 0.026, metal, 0.004)
	for t in [0.35, 0.6, 0.85]:
		var a: Vector2 = rear.call(t)
		var b: Vector2 = front.call(t - 0.03)
		mag.at(Vector3(0, (a.y + b.y) * 0.5, (a.x + b.x) * 0.5), Vector3(-25.0 * t, 0, 0)).box(
			Vector3(0.028, 0.006, absf(a.x - b.x) * 0.85), Vector3.ZERO, metal, 0.002)
	mag.reset()

	# Charging handle on the bolt carrier (right side)
	bolt.tube_between(Vector3(0.02, 0.0, -0.215), Vector3(0.040, 0.0, -0.215), 0.0048, metal, 10)
	bolt.sphere(0.0075, Vector3(0.042, 0.0, -0.215), metal, 8, 12, Vector3(1.0, 0.8, 1.0))
	bolt.box(Vector3(0.004, 0.012, 0.05), Vector3(0.0225, 0.0, -0.19), metal, 0.001)

	save_model(OUT, "ak47", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.622),
		"Eject": Vector3(0.026, 0.004, -0.165),
		"ADS": Vector3(0, 0.046, -0.245),
		"Grip_R": Vector3(0, -0.095, -0.035),
		"Grip_L": Vector3(0, -0.028, -0.40),
		"Mount_muzzle": Vector3(0, 0, -0.588),
	}, {"bolt_travel": Vector3(0, 0, 0.075), "magazine_drop": Vector3(0, -0.24, -0.05)})


# --- M16 ----------------------------------------------------------------------

func build_m16() -> void:
	var metal := m("gun_metal")
	var alloy := m("gun_metal_grey")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()

	# Lower receiver with magazine well, upper receiver
	body.extrude(P([[0.0, -0.018], [0.0, -0.062], [-0.035, -0.066], [-0.093, -0.066], [-0.095, -0.077],
		[-0.170, -0.077], [-0.172, -0.050], [-0.205, -0.045], [-0.205, -0.018]]), 0.046, alloy, 0.004)
	body.extrude(P([[0.005, -0.018], [0.005, 0.022], [-0.225, 0.022], [-0.232, 0.010], [-0.232, -0.018]]), 0.042, alloy, 0.004)
	# Carry handle with rear sight
	body.extrude(P([[0.0, 0.02], [-0.006, 0.07], [-0.042, 0.07], [-0.052, 0.02]]), 0.026, alloy, 0.003)
	body.box(Vector3(0.022, 0.012, 0.15), Vector3(0, 0.064, -0.12), alloy, 0.003)
	body.extrude(P([[-0.18, 0.02], [-0.19, 0.07], [-0.205, 0.07], [-0.215, 0.02]]), 0.024, alloy, 0.003)
	body.box(Vector3(0.004, 0.012, 0.008), Vector3(0.007, 0.076, -0.02), alloy, 0.001)
	body.box(Vector3(0.004, 0.012, 0.008), Vector3(-0.007, 0.076, -0.02), alloy, 0.001)
	# Forward assist, ejection port cover
	body.at(Vector3(0.023, 0.012, 0)).cylinder(0.007, -0.02, -0.05, alloy, 10, 0.002)
	body.reset()
	body.box(Vector3(0.002, 0.018, 0.062), Vector3(0.0215, 0.0, -0.12), alloy, 0.0005)
	# Delta ring, ribbed round handguard, barrel, flash hider
	body.cylinder(0.031, -0.226, -0.238, metal, 20, 0.002)
	body.lathe(ribbed(0.029, 0.0265, -0.238, -0.48, 11), poly, 20)
	body.cylinder(0.019, -0.478, -0.49, metal, 18, 0.002)
	body.cylinder(0.0085, -0.235, -0.745, metal, 12)
	body.lathe(PackedVector2Array([Vector2(0.0085, -0.745), Vector2(0.011, -0.748), Vector2(0.011, -0.788), Vector2(0.0085, -0.79)]), metal, 12)
	# A-frame front sight base and post
	body.extrude(P([[-0.585, -0.012], [-0.625, -0.012], [-0.618, 0.040], [-0.600, 0.048], [-0.592, 0.040]]), 0.018, metal, 0.002)
	body.cylinder(0.013, -0.585, -0.625, metal, 14)
	body.box(Vector3(0.003, 0.033, 0.003), Vector3(0, 0.0615, -0.605), metal)
	body.box(Vector3(0.003, 0.03, 0.01), Vector3(0.010, 0.060, -0.605), metal, 0.001)
	body.box(Vector3(0.003, 0.03, 0.01), Vector3(-0.010, 0.060, -0.605), metal, 0.001)
	body.box(Vector3(0.01, 0.014, 0.02), Vector3(0, -0.02, -0.63), metal, 0.002)
	# Pistol grip, trigger guard, trigger
	body.extrude(P([[-0.075, -0.06], [-0.04, -0.062], [-0.005, -0.16], [-0.012, -0.17], [-0.04, -0.17], [-0.052, -0.15],
		[-0.058, -0.11], [-0.064, -0.105]]), 0.032, poly, 0.007)
	body.box(Vector3(0.012, 0.004, 0.07), Vector3(0, -0.085, -0.095), alloy, 0.001)
	body.box(Vector3(0.012, 0.022, 0.004), Vector3(0, -0.076, -0.13), alloy, 0.001)
	body.extrude(P([[-0.088, -0.064], [-0.097, -0.064], [-0.096, -0.076], [-0.091, -0.083], [-0.086, -0.081], [-0.089, -0.073]]), 0.006, metal, 0.001)
	# Fixed stock and butt plate
	body.extrude(P([[0.0, 0.012], [0.255, 0.012], [0.262, 0.008], [0.262, -0.12], [0.25, -0.125], [0.06, -0.07], [0.0, -0.06]]), 0.044, poly, 0.01)
	body.box(Vector3(0.046, 0.138, 0.008), Vector3(0, -0.055, 0.266), poly, 0.003)

	# Slightly curved 30-round STANAG magazine
	var rear := func(t: float) -> Vector2: return Vector2(-0.098 - 0.006 * t - 0.022 * t * t, -0.066 - 0.19 * t)
	var front := func(t: float) -> Vector2: return Vector2(-0.167 - 0.008 * t - 0.03 * t * t, -0.066 - 0.18 * t)
	mag.extrude(curved_mag(rear, front), 0.022, alloy, 0.003)
	mag.box(Vector3(0.026, 0.008, 0.074), Vector3(0, -0.252, -0.152), poly, 0.003)

	# T-shaped charging handle at the rear of the upper
	bolt.box(Vector3(0.042, 0.008, 0.012), Vector3(0, 0.014, 0.012), alloy, 0.002)
	bolt.box(Vector3(0.010, 0.006, 0.03), Vector3(0, 0.014, -0.004), alloy, 0.001)

	save_model(OUT, "m16", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.79),
		"Eject": Vector3(0.024, 0.002, -0.12),
		"ADS": Vector3(0, 0.078, -0.02),
		"Grip_R": Vector3(0, -0.11, -0.035),
		"Grip_L": Vector3(0, -0.032, -0.40),
		"Mount_optic": Vector3(0, 0.07, -0.11),
		"Mount_muzzle": Vector3(0, 0, -0.745),
	}, {"bolt_travel": Vector3(0, 0, 0.06), "magazine_drop": Vector3(0, -0.24, -0.02)})


# --- MP5 ----------------------------------------------------------------------

func build_mp5() -> void:
	var metal := m("gun_metal")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()

	# Round stamped receiver with flat lower section and magazine well
	body.cylinder(0.023, 0.0, -0.30, metal, 20, 0.003)
	body.box(Vector3(0.044, 0.03, 0.26), Vector3(0, -0.02, -0.15), metal, 0.003)
	body.box(Vector3(0.032, 0.034, 0.048), Vector3(0, -0.046, -0.185), metal, 0.003)
	# Rear diopter drum and front hooded post
	body.box(Vector3(0.03, 0.014, 0.03), Vector3(0, 0.026, -0.025), metal, 0.002)
	body.at(Vector3(0, 0.040, -0.025), Vector3(0, 90, 0)).cylinder(0.012, -0.013, 0.013, metal, 18, 0.002)
	body.reset()
	body.box(Vector3(0.012, 0.035, 0.016), Vector3(0, 0.017, -0.388), metal, 0.002)
	body.at(Vector3(0, 0.044, 0)).lathe(PackedVector2Array([Vector2(0.010, -0.380), Vector2(0.0135, -0.380),
		Vector2(0.0135, -0.396), Vector2(0.010, -0.396), Vector2(0.010, -0.380)]), metal, 18, false, false)
	body.reset()
	body.box(Vector3(0.003, 0.026, 0.003), Vector3(0, 0.041, -0.388), metal)
	# Cocking tube, barrel and three-lug collar
	body.at(Vector3(0, 0.014, 0)).cylinder(0.0115, -0.29, -0.386, metal, 14, 0.002)
	body.reset()
	body.cylinder(0.0095, -0.30, -0.445, metal, 14)
	body.cylinder(0.0128, -0.405, -0.428, metal, 14, 0.002)
	for i in 3:
		var a := TAU * i / 3.0 + PI * 0.5
		body.box(Vector3(0.006, 0.006, 0.012), Vector3(cos(a) * 0.014, sin(a) * 0.014, -0.42), metal, 0.001)
	# Slim handguard with finger grooves
	body.extrude(P([[-0.302, 0.002], [-0.40, 0.002], [-0.408, -0.012], [-0.40, -0.040], [-0.375, -0.047], [-0.362, -0.041],
		[-0.348, -0.047], [-0.334, -0.041], [-0.320, -0.046], [-0.305, -0.036]]), 0.05, poly, 0.009)
	# Trigger housing, grip, guard, trigger
	body.extrude(P([[-0.03, -0.034], [-0.137, -0.034], [-0.142, -0.054], [-0.122, -0.076], [-0.03, -0.062]]), 0.04, poly, 0.006)
	body.extrude(P([[-0.062, -0.06], [-0.026, -0.06], [0.0, -0.163], [-0.01, -0.174], [-0.036, -0.172], [-0.051, -0.15]]), 0.032, poly, 0.008)
	body.extrude(P([[-0.084, -0.066], [-0.093, -0.066], [-0.092, -0.078], [-0.087, -0.085], [-0.082, -0.083], [-0.085, -0.075]]), 0.006, metal, 0.001)
	# Fixed A2 stock and butt pad
	body.extrude(P([[0.0, 0.018], [0.06, 0.012], [0.235, 0.004], [0.24, -0.002], [0.24, -0.115], [0.225, -0.12],
		[0.05, -0.065], [0.0, -0.04]]), 0.04, poly, 0.01)
	body.box(Vector3(0.042, 0.122, 0.01), Vector3(0, -0.058, 0.244), poly, 0.003)

	# Curved 9mm 30-round magazine
	var rear := func(t: float) -> Vector2: return Vector2(-0.166 - 0.012 * t - 0.05 * t * t, -0.05 - 0.19 * t)
	var front := func(t: float) -> Vector2: return Vector2(-0.203 - 0.012 * t - 0.056 * t * t, -0.05 - 0.186 * t)
	mag.extrude(curved_mag(rear, front), 0.022, metal, 0.003)

	# Cocking handle on the left of the cocking tube
	bolt.tube_between(Vector3(-0.008, 0.016, -0.355), Vector3(-0.034, 0.03, -0.355), 0.0042, metal, 8)
	bolt.sphere(0.0062, Vector3(-0.036, 0.031, -0.355), metal, 8, 10)

	save_model(OUT, "mp5", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.445),
		"Eject": Vector3(0.026, 0.006, -0.16),
		"ADS": Vector3(0, 0.054, -0.025),
		"Grip_R": Vector3(0, -0.105, -0.035),
		"Grip_L": Vector3(0, -0.032, -0.355),
		"Mount_optic": Vector3(0, 0.026, -0.12),
		"Mount_muzzle": Vector3(0, 0, -0.445),
	}, {"bolt_travel": Vector3(0, 0, 0.08), "magazine_drop": Vector3(0, -0.24, -0.04)})


# --- M40 ----------------------------------------------------------------------

func build_m40() -> void:
	var metal := m("gun_metal")
	var olive := m("gun_polymer_olive")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var bolt := MeshKit.new()

	# One-piece fibreglass stock: butt, comb, pistol grip, forend
	body.extrude(P([[0.33, -0.006], [0.16, 0.004], [0.06, -0.018], [0.0, -0.016], [-0.60, -0.016], [-0.622, -0.03],
		[-0.62, -0.058], [-0.25, -0.074], [-0.10, -0.074], [-0.025, -0.066], [0.018, -0.088], [0.048, -0.124],
		[0.09, -0.132], [0.20, -0.142], [0.33, -0.166]]), 0.052, olive, 0.012)
	body.box(Vector3(0.05, 0.158, 0.022), Vector3(0, -0.086, 0.341), poly, 0.005)
	# Round receiver and bolt shroud
	body.cylinder(0.0175, 0.005, -0.215, metal, 22, 0.003)
	body.lathe(PackedVector2Array([Vector2(0.004, 0.055), Vector2(0.011, 0.05), Vector2(0.0135, 0.03), Vector2(0.0135, 0.005)]), metal, 16)
	# Heavy barrel with step and crown
	body.lathe(PackedVector2Array([Vector2(0.0155, -0.215), Vector2(0.0155, -0.27), Vector2(0.0125, -0.30),
		Vector2(0.0115, -0.86), Vector2(0.006, -0.862)]), metal, 18)
	# Scope base rail
	body.box(Vector3(0.02, 0.006, 0.17), Vector3(0, 0.019, -0.105), metal, 0.002)
	# Floorplate, trigger guard, trigger
	body.box(Vector3(0.02, 0.006, 0.11), Vector3(0, -0.077, -0.07), metal, 0.002)
	body.box(Vector3(0.012, 0.004, 0.06), Vector3(0, -0.092, -0.005), metal, 0.001)
	body.box(Vector3(0.012, 0.022, 0.004), Vector3(0, -0.082, 0.022), metal, 0.001)
	body.extrude(P([[0.005, -0.068], [-0.004, -0.068], [-0.003, -0.081], [0.002, -0.088], [0.007, -0.086], [0.004, -0.078]]), 0.006, metal, 0.001)

	# Bolt handle: lifts 60 degrees and draws back when cycled
	bolt.tube_between(Vector3(0.014, 0.002, -0.012), Vector3(0.05, -0.02, -0.012), 0.004, metal, 8)
	bolt.sphere(0.0095, Vector3(0.054, -0.022, -0.012), metal, 8, 12)

	save_model(OUT, "m40", {"Body": body, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.862),
		"Eject": Vector3(0.02, 0.008, -0.07),
		"ADS": Vector3(0, 0.03, -0.05),
		"Grip_R": Vector3(0, -0.085, 0.04),
		"Grip_L": Vector3(0, -0.062, -0.40),
		"Mount_optic": Vector3(0, 0.022, -0.105),
		"Mount_muzzle": Vector3(0, 0, -0.862),
	}, {"bolt_travel": Vector3(0, 0, 0.09), "bolt_lift_degrees": -60.0})


# --- M1911 -----------------------------------------------------------------------

func build_m1911() -> void:
	var metal := m("gun_metal")
	var dark := m("gun_metal_grey")
	var wood := m("gun_wood")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var slide := MeshKit.new()

	# Slide (the moving part): rounded top, flat sides, sights, serrations, port
	slide.extrude(P([[0.0, -0.007], [0.0, 0.012], [-0.004, 0.015], [-0.205, 0.015], [-0.214, 0.012],
		[-0.216, 0.0], [-0.216, -0.007]]), 0.0235, metal, 0.002)
	slide.box(Vector3(0.016, 0.007, 0.008), Vector3(0, 0.0175, -0.012), metal, 0.001)  # rear sight base
	for x in [-0.0055, 0.0055]:
		slide.box(Vector3(0.004, 0.005, 0.006), Vector3(x, 0.0205, -0.012), metal, 0.0005)  # notch ears
	slide.box(Vector3(0.0025, 0.0055, 0.008), Vector3(0, 0.0175, -0.203), metal)  # front blade
	for i in 8:
		for x in [-0.0119, 0.0119]:
			slide.box(Vector3(0.0012, 0.017, 0.0016), Vector3(x, 0.003, -0.005 - i * 0.0036), dark)  # serrations
	slide.box(Vector3(0.0015, 0.011, 0.032), Vector3(0.0118, 0.006, -0.06), dark)  # ejection port
	slide.lathe(PackedVector2Array([Vector2(0.0065, -0.214), Vector2(0.0088, -0.214), Vector2(0.0088, -0.222),
		Vector2(0.0058, -0.222)]), metal, 16, false, false)  # barrel bushing
	slide.cylinder(0.0058, -0.214, -0.2225, dark, 12)  # barrel

	# Frame: dust cover, trigger guard, grip with wood panels, beavertail, hammer
	body.extrude(P([[0.008, -0.007], [-0.17, -0.007], [-0.172, -0.016], [-0.12, -0.024], [-0.052, -0.024],
		[-0.046, -0.022], [0.0, -0.022], [0.012, -0.012]]), 0.022, metal, 0.002)
	body.extrude(P([[-0.046, -0.022], [-0.104, -0.022], [-0.108, -0.04], [-0.098, -0.052], [-0.06, -0.054],
		[-0.052, -0.046], [-0.058, -0.04], [-0.09, -0.04], [-0.094, -0.032], [-0.056, -0.03]]), 0.009, metal, 0.0015)
	var grip := P([[0.012, -0.018], [-0.03, -0.018], [-0.042, -0.06], [-0.005, -0.128], [0.03, -0.128], [0.03, -0.112]])
	body.extrude(grip, 0.022, metal, 0.002)
	body.extrude(P([[0.006, -0.03], [-0.032, -0.03], [-0.04, -0.062], [-0.008, -0.12], [0.022, -0.12], [0.024, -0.108]]),
		0.028, wood, 0.003)
	body.extrude(P([[0.012, -0.012], [0.03, -0.014], [0.034, -0.02], [0.016, -0.03]]), 0.02, metal, 0.002)  # beavertail
	body.at(Vector3(0, 0.004, 0.006), Vector3(-25, 0, 0)).box(Vector3(0.008, 0.016, 0.006), Vector3.ZERO, metal, 0.001)  # hammer
	body.reset()
	body.extrude(P([[-0.07, -0.026], [-0.078, -0.026], [-0.077, -0.04], [-0.072, -0.046], [-0.068, -0.044], [-0.071, -0.036]]),
		0.006, metal, 0.0008)  # trigger
	body.box(Vector3(0.003, 0.006, 0.026), Vector3(-0.0125, -0.009, 0.0), metal, 0.001)  # thumb safety
	body.box(Vector3(0.003, 0.005, 0.03), Vector3(-0.0125, -0.012, -0.08), metal, 0.001)  # slide stop

	# Magazine: mostly hidden in the grip; the base plate shows
	mag.at(Vector3(0, -0.07, 0.005), Vector3(-18, 0, 0)).box(Vector3(0.016, 0.11, 0.03), Vector3.ZERO, metal, 0.002)
	mag.reset()
	mag.box(Vector3(0.022, 0.008, 0.038), Vector3(0, -0.131, 0.012), metal, 0.002)

	save_model(OUT, "m1911", {"Body": body, "Magazine": mag, "Bolt": slide}, {
		"Muzzle": Vector3(0, 0, -0.223),
		"Eject": Vector3(0.013, 0.008, -0.06),
		"ADS": Vector3(0, 0.0205, -0.012),
		"Grip_R": Vector3(0, -0.068, 0.012),
		"Grip_L": Vector3(-0.024, -0.078, 0.004),
	}, {"bolt_travel": Vector3(0, 0, 0.035), "magazine_drop": Vector3(0, -0.16, 0.05)})


# --- Scope for the M40 ----------------------------------------------------------

func build_scope_m40() -> void:
	var metal := m("gun_metal")
	var lens := m("gun_lens")
	var body := MeshKit.new()
	var axis_y := 0.040
	body.at(Vector3(0, axis_y, 0)).lathe(PackedVector2Array([Vector2(0.0, 0.118), Vector2(0.0195, 0.118),
		Vector2(0.0195, 0.075), Vector2(0.0128, 0.048), Vector2(0.0128, -0.105), Vector2(0.0225, -0.155),
		Vector2(0.0225, -0.218), Vector2(0.0, -0.218)]), metal, 24, false, false)
	body.at(Vector3(0, axis_y, 0)).cylinder(0.017, 0.1185, 0.1195, lens, 20)
	body.at(Vector3(0, axis_y, 0)).cylinder(0.0205, -0.2185, -0.2195, lens, 20)
	# Elevation (top) and windage (right) turrets
	body.at(Vector3(0, axis_y, -0.03), Vector3(-90, 0, 0)).cylinder(0.011, 0.0, 0.027, metal, 16, 0.002)
	body.at(Vector3(0, axis_y, -0.03), Vector3(0, 90, 0)).cylinder(0.011, 0.0, 0.027, metal, 16, 0.002)
	# Rings and bases
	for z in [0.0, -0.075]:
		body.at(Vector3(0, axis_y, 0)).lathe(PackedVector2Array([Vector2(0.0129, z + 0.007), Vector2(0.0168, z + 0.007),
			Vector2(0.0168, z - 0.007), Vector2(0.0129, z - 0.007), Vector2(0.0129, z + 0.007)]), metal, 18, false, false)
		body.reset()
		body.box(Vector3(0.022, axis_y - 0.012, 0.014), Vector3(0, (axis_y - 0.012) * 0.5, z), metal, 0.002)
	body.reset()
	save_model(ATTACH_OUT, "scope_m40", {"Body": body}, {
		"ADS": Vector3(0, axis_y, 0.13),
	}, {}, "")
