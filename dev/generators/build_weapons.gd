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
	# `-- id id ...` builds only those (the others may have been replaced).
	var only := OS.get_cmdline_user_args()
	for id in ["ak47", "m16", "mp5", "m40", "m1911", "scope_m40", "remington870", "uzi", "fal", "g3", "aks74u", "svd",
			"scope_pso1", "beretta92", "python"]:
		if only.is_empty() or id in only:
			call("build_" + id)
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


# --- Remington 870 --------------------------------------------------------------
# Pump shotgun: steel receiver, barrel over the magazine tube, wooden pump
# (the "Bolt": it slides back and forward when cycled), wooden stock.

func build_remington870() -> void:
	var metal := m("gun_metal")
	var wood := m("gun_wood")
	var body := MeshKit.new()
	var pump := MeshKit.new()
	# Receiver: slab sides, rounded top, loading port underneath
	body.extrude(P([[0.0, -0.05], [0.0, 0.012], [-0.012, 0.022], [-0.205, 0.022], [-0.215, 0.012], [-0.215, -0.05]]),
		0.038, metal, 0.004)
	body.box(Vector3(0.002, 0.02, 0.06), Vector3(0.0192, -0.004, -0.11), m("gun_metal_grey"))  # ejection port
	# Barrel with vent rib and bead, magazine tube and cap
	body.cylinder(0.0115, -0.205, -0.68, metal, 16)
	body.box(Vector3(0.008, 0.0095, 0.46), Vector3(0, 0.01625, -0.445), metal, 0.001)  # rib, flush with the receiver top
	body.sphere(0.0026, Vector3(0, 0.0235, -0.674), m("gun_metal_grey"), 6, 8)
	body.at(Vector3(0, -0.026, 0)).cylinder(0.012, -0.205, -0.6, metal, 14)
	body.at(Vector3(0, -0.026, 0)).cylinder(0.0135, -0.6, -0.622, metal, 14, 0.003)
	body.reset()
	body.box(Vector3(0.012, 0.022, 0.016), Vector3(0, -0.014, -0.59), metal, 0.002)  # barrel ring
	# Trigger group, guard, trigger, safety
	body.extrude(P([[-0.03, -0.05], [-0.14, -0.05], [-0.145, -0.064], [-0.12, -0.072], [-0.03, -0.068]]), 0.028, metal, 0.003)
	body.box(Vector3(0.01, 0.004, 0.07), Vector3(0, -0.088, -0.085), metal, 0.001)
	body.box(Vector3(0.01, 0.02, 0.004), Vector3(0, -0.078, -0.118), metal, 0.001)
	body.extrude(P([[-0.072, -0.068], [-0.08, -0.068], [-0.079, -0.082], [-0.074, -0.088], [-0.07, -0.086], [-0.072, -0.077]]),
		0.006, metal, 0.001)
	# Wooden stock with grip and rubber pad
	body.extrude(P([[0.0, 0.012], [0.03, 0.01], [0.33, -0.01], [0.335, -0.016], [0.335, -0.15], [0.32, -0.156],
		[0.12, -0.1], [0.06, -0.11], [0.03, -0.09], [0.0, -0.05]]), 0.042, wood, 0.012)
	body.box(Vector3(0.044, 0.148, 0.018), Vector3(0, -0.083, 0.344), m("gun_polymer"), 0.004)
	# Grooved wooden pump round the magazine tube
	pump.at(Vector3(0, -0.026, 0)).lathe(ribbed(0.0215, 0.0195, -0.27, -0.45, 9), wood, 18)
	pump.reset()
	pump.box(Vector3(0.006, 0.012, 0.22), Vector3(0.012, -0.006, -0.25), metal, 0.001)  # action bar
	save_model(OUT, "remington870", {"Body": body, "Bolt": pump}, {
		"Muzzle": Vector3(0, 0, -0.68),
		"Eject": Vector3(0.02, 0.0, -0.11),
		"ADS": Vector3(0, 0.0255, 0.0),  # along the rib to the bead
		"Grip_R": Vector3(0, -0.08, 0.05),
		"Grip_L": Vector3(0, -0.045, -0.36),
		"Mount_muzzle": Vector3(0, 0, -0.68),
	}, {"bolt_travel": Vector3(0, 0, 0.09)})


# --- Uzi --------------------------------------------------------------------------
# Boxy stamped receiver, magazine through the pistol grip, folded stock under.

func build_uzi() -> void:
	var metal := m("gun_metal")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()
	body.box(Vector3(0.05, 0.062, 0.31), Vector3(0, -0.006, -0.15), metal, 0.004)
	for i in 4:
		body.box(Vector3(0.052, 0.004, 0.018), Vector3(0, -0.02 + i * 0.0001, -0.07 - i * 0.05), metal, 0.001)  # stampings
	# Short barrel and nut, sight towers
	body.cylinder(0.0095, -0.30, -0.37, metal, 14)
	body.cylinder(0.016, -0.30, -0.315, metal, 16, 0.002)
	for z in [-0.01, -0.285]:
		for x in [-0.011, 0.011]:
			body.box(Vector3(0.004, 0.022, 0.012), Vector3(x, 0.034, z), metal, 0.001)
	body.box(Vector3(0.003, 0.016, 0.004), Vector3(0, 0.032, -0.285), metal)
	body.box(Vector3(0.014, 0.008, 0.012), Vector3(0, 0.03, -0.01), metal, 0.001)
	# Grip with plastic panels, trigger guard, trigger, grip safety
	var grip := P([[-0.10, -0.036], [-0.155, -0.036], [-0.15, -0.16], [-0.096, -0.16]])
	body.extrude(grip, 0.034, poly, 0.006)
	body.extrude(P([[-0.07, -0.036], [-0.096, -0.036], [-0.096, -0.068], [-0.06, -0.07], [-0.052, -0.05]]), 0.01, metal, 0.002)
	body.extrude(P([[-0.074, -0.04], [-0.082, -0.04], [-0.081, -0.054], [-0.076, -0.06], [-0.072, -0.058], [-0.075, -0.05]]),
		0.006, metal, 0.001)
	body.box(Vector3(0.02, 0.05, 0.006), Vector3(0, -0.07, -0.157), metal, 0.002)
	# Folding stock tucked under the receiver
	for x in [-0.018, 0.018]:
		body.box(Vector3(0.004, 0.008, 0.24), Vector3(x, -0.045, -0.12), metal, 0.001)
	body.box(Vector3(0.042, 0.03, 0.006), Vector3(0, -0.045, -0.24), metal, 0.002)
	# Straight 32-round magazine, base showing under the grip
	mag.extrude(P([[-0.106, -0.04], [-0.146, -0.04], [-0.14, -0.27], [-0.104, -0.27]]), 0.022, metal, 0.003)
	mag.box(Vector3(0.026, 0.008, 0.046), Vector3(0, -0.274, -0.122), metal, 0.002)
	# Cocking knob on top
	bolt.box(Vector3(0.012, 0.016, 0.012), Vector3(0, 0.032, -0.2), metal, 0.002)
	save_model(OUT, "uzi", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.37),
		"Eject": Vector3(0.026, 0.004, -0.16),
		"ADS": Vector3(0, 0.04, -0.01),
		"Grip_R": Vector3(0, -0.1, -0.12),
		"Grip_L": Vector3(0, -0.04, -0.26),
		"Mount_muzzle": Vector3(0, 0, -0.37),
	}, {"bolt_travel": Vector3(0, 0, 0.08), "magazine_drop": Vector3(0, -0.24, 0.0)})


# --- FN FAL -----------------------------------------------------------------------

func build_fal() -> void:
	var metal := m("gun_metal")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()
	# Machined receiver, top cover, magazine well
	body.extrude(P([[0.0, -0.05], [0.0, 0.006], [-0.285, 0.006], [-0.29, -0.03], [-0.2, -0.03], [-0.195, -0.06],
		[-0.11, -0.06], [-0.1, -0.05]]), 0.044, metal, 0.004)
	body.extrude(P([[0.01, 0.006], [0.01, 0.024], [-0.02, 0.03], [-0.26, 0.03], [-0.27, 0.006]]), 0.036, metal, 0.003)
	# Carry handle (folded) and rear aperture
	body.box(Vector3(0.004, 0.02, 0.12), Vector3(0.02, 0.025, -0.17), metal, 0.001)
	body.box(Vector3(0.016, 0.014, 0.012), Vector3(0, 0.037, -0.01), metal, 0.002)
	body.at(Vector3(0, 0.05, 0)).lathe(PackedVector2Array([Vector2(0.002, -0.006), Vector2(0.0065, -0.006),
		Vector2(0.0065, -0.014), Vector2(0.002, -0.014), Vector2(0.002, -0.006)]), metal, 16, false, false)  # peep
	body.reset()
	# Handguard (ventilated), gas block, barrel, flash hider, front sight
	body.extrude(P([[-0.285, 0.016], [-0.53, 0.016], [-0.535, 0.0], [-0.53, -0.036], [-0.285, -0.036]]), 0.05, poly, 0.008)
	for i in 6:
		body.box(Vector3(0.052, 0.006, 0.02), Vector3(0, 0.004, -0.31 - i * 0.04), metal, 0.001)
	body.box(Vector3(0.028, 0.05, 0.05), Vector3(0, 0.01, -0.56), metal, 0.004)
	body.cylinder(0.0105, -0.28, -0.80, metal, 14)
	body.lathe(ribbed(0.0135, 0.0115, -0.74, -0.84, 4), metal, 14)
	body.box(Vector3(0.003, 0.03, 0.003), Vector3(0, 0.035, -0.565), metal)  # post tip on the sight line
	for x in [-0.01, 0.01]:
		body.box(Vector3(0.003, 0.028, 0.01), Vector3(x, 0.045, -0.565), metal, 0.001)
	# Pistol grip, guard, trigger
	body.extrude(P([[-0.078, -0.058], [-0.04, -0.058], [-0.005, -0.16], [-0.012, -0.17], [-0.04, -0.168], [-0.05, -0.15]]),
		0.032, poly, 0.008)
	body.box(Vector3(0.012, 0.004, 0.07), Vector3(0, -0.084, -0.095), metal, 0.001)
	body.box(Vector3(0.012, 0.022, 0.004), Vector3(0, -0.073, -0.13), metal, 0.001)
	body.extrude(P([[-0.088, -0.062], [-0.097, -0.062], [-0.096, -0.075], [-0.091, -0.082], [-0.086, -0.08], [-0.089, -0.072]]),
		0.006, metal, 0.001)
	# Fixed stock
	body.extrude(P([[0.0, 0.006], [0.27, -0.005], [0.278, -0.012], [0.278, -0.13], [0.26, -0.135], [0.06, -0.075], [0.0, -0.05]]),
		0.042, poly, 0.01)
	# 20-round box magazine, slight curve
	var rear := func(t: float) -> Vector2: return Vector2(-0.112 - 0.008 * t - 0.012 * t * t, -0.058 - 0.16 * t)
	var front := func(t: float) -> Vector2: return Vector2(-0.192 - 0.01 * t - 0.016 * t * t, -0.058 - 0.152 * t)
	mag.extrude(curved_mag(rear, front), 0.03, metal, 0.003)
	mag.box(Vector3(0.034, 0.008, 0.09), Vector3(0, -0.221, -0.168), metal, 0.002)
	# Folding charging handle, left side
	bolt.box(Vector3(0.018, 0.008, 0.01), Vector3(-0.03, 0.0, -0.24), metal, 0.002)
	save_model(OUT, "fal", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.84),
		"Eject": Vector3(0.024, 0.008, -0.14),
		"ADS": Vector3(0, 0.05, -0.01),
		"Grip_R": Vector3(0, -0.105, -0.035),
		"Grip_L": Vector3(0, -0.03, -0.42),
		"Mount_muzzle": Vector3(0, 0, -0.84),
	}, {"bolt_travel": Vector3(0, 0, 0.1), "magazine_drop": Vector3(0, -0.22, -0.03)})


# --- HK G3 ------------------------------------------------------------------------

func build_g3() -> void:
	var metal := m("gun_metal")
	var poly := m("gun_polymer_olive")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()
	# Stamped receiver (round top), lower, magazine well
	body.cylinder(0.026, 0.0, -0.34, metal, 20, 0.003)
	body.box(Vector3(0.048, 0.034, 0.3), Vector3(0, -0.022, -0.16), metal, 0.003)
	body.box(Vector3(0.036, 0.04, 0.07), Vector3(0, -0.055, -0.19), metal, 0.003)
	# Rotary drum rear sight, hooded front post
	body.box(Vector3(0.032, 0.016, 0.03), Vector3(0, 0.032, -0.02), metal, 0.002)
	body.at(Vector3(0, 0.036, -0.02), Vector3(0, 90, 0)).cylinder(0.0095, -0.015, 0.015, metal, 18, 0.002)
	body.reset()
	body.at(Vector3(0, 0.05, 0)).lathe(PackedVector2Array([Vector2(0.002, -0.017), Vector2(0.0055, -0.017),
		Vector2(0.0055, -0.023), Vector2(0.002, -0.023), Vector2(0.002, -0.017)]), metal, 16, false, false)  # peep
	body.box(Vector3(0.014, 0.04, 0.02), Vector3(0, 0.03, -0.47), metal, 0.002)  # post tip on the sight line
	body.at(Vector3(0, 0.05, 0)).lathe(PackedVector2Array([Vector2(0.011, -0.462), Vector2(0.015, -0.462),
		Vector2(0.015, -0.48), Vector2(0.011, -0.48), Vector2(0.011, -0.462)]), metal, 18, false, false)
	body.reset()
	# Cocking tube, barrel, flash hider
	body.at(Vector3(0, 0.016, 0)).cylinder(0.012, -0.34, -0.47, metal, 14)
	body.reset()
	body.cylinder(0.0105, -0.34, -0.72, metal, 14)
	body.lathe(ribbed(0.0145, 0.0125, -0.69, -0.76, 4), metal, 14)
	# Slim handguard
	body.extrude(P([[-0.34, 0.006], [-0.5, 0.006], [-0.505, -0.008], [-0.5, -0.042], [-0.34, -0.044]]), 0.054, poly, 0.012)
	# Grip, guard, trigger
	body.extrude(P([[-0.07, -0.04], [-0.035, -0.04], [-0.005, -0.15], [-0.012, -0.16], [-0.04, -0.158], [-0.05, -0.14]]),
		0.032, poly, 0.008)
	body.box(Vector3(0.012, 0.004, 0.07), Vector3(0, -0.07, -0.09), metal, 0.001)
	body.extrude(P([[-0.085, -0.044], [-0.094, -0.044], [-0.093, -0.058], [-0.088, -0.064], [-0.083, -0.062], [-0.086, -0.054]]),
		0.006, metal, 0.001)
	# Fixed stock
	body.extrude(P([[0.0, 0.02], [0.24, 0.0], [0.248, -0.006], [0.248, -0.13], [0.23, -0.135], [0.05, -0.07], [0.0, -0.04]]),
		0.046, poly, 0.012)
	# Straight 20-round magazine
	mag.extrude(P([[-0.152, -0.07], [-0.228, -0.07], [-0.234, -0.24], [-0.16, -0.24]]), 0.03, metal, 0.003)
	# Cocking handle on the tube, left
	bolt.tube_between(Vector3(-0.01, 0.016, -0.42), Vector3(-0.04, 0.03, -0.42), 0.0045, metal, 8)
	bolt.sphere(0.0065, Vector3(-0.042, 0.031, -0.42), metal, 8, 10)
	save_model(OUT, "g3", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.76),
		"Eject": Vector3(0.026, 0.006, -0.18),
		"ADS": Vector3(0, 0.05, -0.02),
		"Grip_R": Vector3(0, -0.1, -0.03),
		"Grip_L": Vector3(0, -0.03, -0.43),
		"Mount_muzzle": Vector3(0, 0, -0.76),
	}, {"bolt_travel": Vector3(0, 0, 0.08), "magazine_drop": Vector3(0, -0.22, -0.02)})


# --- AKS-74U ----------------------------------------------------------------------

func build_aks74u() -> void:
	var metal := m("gun_metal")
	var wood := m("gun_wood")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()
	body.extrude(P([[0.0, -0.046], [0.0, 0.010], [-0.30, 0.010], [-0.30, -0.028], [-0.21, -0.028],
		[-0.204, -0.050], [-0.118, -0.050], [-0.108, -0.046]]), 0.044, metal, 0.004)
	# Hinged top cover with the flip rear sight
	var arc := PackedVector2Array()
	for i in 13:
		var a := PI * i / 12.0
		arc.append(Vector2(cos(a) * 0.0215, 0.009 + sin(a) * 0.017))
	body.at(Vector3(0, 0, -0.15), Vector3(0, 90, 0)).extrude(arc, 0.3, metal, 0.002)
	body.reset()
	body.box(Vector3(0.012, 0.012, 0.012), Vector3(0, 0.032, -0.29), metal, 0.002)
	for x in [-0.0045, 0.0045]:  # U notch
		body.box(Vector3(0.003, 0.012, 0.008), Vector3(x, 0.042, -0.29), metal, 0.0005)
	# Short gas tube with wooden guard, barrel, cone booster
	body.at(Vector3(0, 0.022, 0)).cylinder(0.0145, -0.30, -0.4, wood, 16, 0.005)
	body.reset()
	body.extrude(P([[-0.30, 0.004], [-0.4, 0.004], [-0.404, -0.03], [-0.30, -0.032]]), 0.05, wood, 0.009)
	body.cylinder(0.0095, -0.30, -0.47, metal, 12)
	body.box(Vector3(0.024, 0.05, 0.03), Vector3(0, 0.012, -0.43), metal, 0.004)
	body.lathe(PackedVector2Array([Vector2(0.012, -0.46), Vector2(0.016, -0.47), Vector2(0.019, -0.53), Vector2(0.0, -0.53)]),
		metal, 16, true, false)
	body.box(Vector3(0.003, 0.02, 0.003), Vector3(0, 0.034, -0.45), metal)  # post tip on the sight line
	# Grip, guard, trigger, selector
	body.extrude(P([[-0.078, -0.040], [-0.032, -0.040], [0.006, -0.140], [0.002, -0.153], [-0.026, -0.157],
		[-0.040, -0.150], [-0.050, -0.128]]), 0.034, poly, 0.009)
	body.box(Vector3(0.012, 0.004, 0.064), Vector3(0, -0.073, -0.097), metal, 0.001)
	body.extrude(P([[-0.086, -0.046], [-0.095, -0.046], [-0.094, -0.060], [-0.089, -0.068], [-0.084, -0.066],
		[-0.088, -0.057]]), 0.006, metal, 0.001)
	body.at(Vector3(0.0235, -0.006, -0.12), Vector3(-4, 0, 0)).box(Vector3(0.003, 0.012, 0.12), Vector3.ZERO, metal, 0.001)
	body.reset()
	# Side-folding skeleton stock, open
	for y in [-0.004, -0.07]:
		body.box(Vector3(0.008, 0.01, 0.24), Vector3(0.0, y - 0.01 * (1 if y < -0.01 else 0), 0.12), metal, 0.002)
	body.box(Vector3(0.012, 0.11, 0.014), Vector3(0, -0.04, 0.245), metal, 0.003)
	# Curved 5.45 magazine (plum polymer)
	var rear := func(t: float) -> Vector2: return Vector2(-0.118 - 0.016 * t - 0.07 * t * t, -0.044 - 0.19 * t)
	var front := func(t: float) -> Vector2: return Vector2(-0.205 - 0.010 * t - 0.082 * t * t, -0.044 - 0.18 * t)
	mag.extrude(curved_mag(rear, front), 0.024, m("gun_polymer"), 0.004)
	bolt.tube_between(Vector3(0.02, 0.0, -0.215), Vector3(0.040, 0.0, -0.215), 0.0048, metal, 10)
	bolt.sphere(0.0075, Vector3(0.042, 0.0, -0.215), metal, 8, 12, Vector3(1.0, 0.8, 1.0))
	save_model(OUT, "aks74u", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -0.53),
		"Eject": Vector3(0.026, 0.004, -0.165),
		"ADS": Vector3(0, 0.044, -0.29),
		"Grip_R": Vector3(0, -0.095, -0.035),
		"Grip_L": Vector3(0, -0.026, -0.36),
		"Mount_muzzle": Vector3(0, 0, -0.53),
	}, {"bolt_travel": Vector3(0, 0, 0.075), "magazine_drop": Vector3(0, -0.24, -0.05)})


# --- SVD Dragunov ------------------------------------------------------------------

func build_svd() -> void:
	var metal := m("gun_metal")
	var wood := m("gun_wood")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var bolt := MeshKit.new()
	# Long AK-style receiver
	body.extrude(P([[0.0, -0.046], [0.0, 0.012], [-0.33, 0.012], [-0.33, -0.028], [-0.21, -0.028],
		[-0.205, -0.05], [-0.115, -0.05], [-0.105, -0.046]]), 0.044, metal, 0.004)
	body.box(Vector3(0.008, 0.03, 0.12), Vector3(-0.026, 0.0, -0.17), metal, 0.002)  # scope rail (left)
	# Two-piece wooden handguard, gas block, long barrel, slotted flash hider, front sight
	body.at(Vector3(0, 0.004, 0)).cylinder(0.024, -0.33, -0.56, wood, 18, 0.006)
	body.reset()
	for i in 5:
		body.box(Vector3(0.05, 0.004, 0.012), Vector3(0, 0.012, -0.36 - i * 0.04), m("gun_metal_grey"), 0.001)
	body.box(Vector3(0.028, 0.042, 0.04), Vector3(0, 0.008, -0.585), metal, 0.004)
	body.cylinder(0.0105, -0.33, -1.0, metal, 14)
	body.lathe(ribbed(0.0125, 0.0105, -0.95, -1.05, 4), metal, 14)
	body.box(Vector3(0.003, 0.03, 0.003), Vector3(0, 0.032, -0.93), metal)
	body.box(Vector3(0.02, 0.016, 0.02), Vector3(0, 0.012, -0.93), metal, 0.002)
	# Skeleton thumbhole stock: frame members, cheek riser, butt plate
	body.extrude(P([[0.0, 0.004], [0.06, 0.004], [0.30, -0.02], [0.32, -0.03], [0.32, -0.06], [0.06, -0.035], [0.0, -0.03]]),
		0.04, wood, 0.008)  # comb
	body.extrude(P([[0.0, -0.05], [0.06, -0.06], [0.3, -0.13], [0.32, -0.15], [0.3, -0.16], [0.06, -0.09], [0.0, -0.08]]),
		0.04, wood, 0.008)  # lower member
	body.extrude(P([[0.03, -0.03], [0.07, -0.03], [0.06, -0.12], [0.02, -0.12]]), 0.036, wood, 0.008)  # grip
	body.box(Vector3(0.04, 0.16, 0.012), Vector3(0, -0.08, 0.322), m("gun_polymer"), 0.003)
	body.box(Vector3(0.012, 0.004, 0.06), Vector3(0, -0.072, -0.09), metal, 0.001)
	body.extrude(P([[-0.075, -0.046], [-0.084, -0.046], [-0.083, -0.06], [-0.078, -0.066], [-0.073, -0.064], [-0.076, -0.055]]),
		0.006, metal, 0.001)
	# 10-round magazine
	mag.extrude(P([[-0.115, -0.05], [-0.2, -0.05], [-0.208, -0.15], [-0.122, -0.155]]), 0.028, metal, 0.003)
	bolt.tube_between(Vector3(0.02, 0.0, -0.23), Vector3(0.040, 0.0, -0.23), 0.0048, metal, 10)
	bolt.sphere(0.0075, Vector3(0.042, 0.0, -0.23), metal, 8, 12)
	save_model(OUT, "svd", {"Body": body, "Magazine": mag, "Bolt": bolt}, {
		"Muzzle": Vector3(0, 0, -1.05),
		"Eject": Vector3(0.026, 0.004, -0.17),
		"ADS": Vector3(0, 0.034, -0.24),
		"Grip_R": Vector3(0, -0.085, 0.045),
		"Grip_L": Vector3(0, -0.02, -0.45),
		"Mount_optic": Vector3(-0.03, 0.0, -0.17),
		"Mount_muzzle": Vector3(0, 0, -1.05),
	}, {"bolt_travel": Vector3(0, 0, 0.09), "magazine_drop": Vector3(0, -0.2, -0.02)})


## PSO-1: 4x scope offset to the left on the SVD's side rail, rubber eyecup.
func build_scope_pso1() -> void:
	var metal := m("gun_metal")
	var lens := m("gun_lens")
	var rubber := m("gun_polymer")
	var body := MeshKit.new()
	var ax := Vector3(0.03, 0.062, 0)  # tube axis relative to the rail mount (rail is on the left: shift back over the bore)
	body.at(ax).lathe(PackedVector2Array([Vector2(0.0, 0.07), Vector2(0.016, 0.07), Vector2(0.016, 0.045),
		Vector2(0.013, 0.03), Vector2(0.013, -0.09), Vector2(0.018, -0.115), Vector2(0.018, -0.16), Vector2(0.0, -0.16)]),
		metal, 22, false, false)
	body.at(ax).lathe(PackedVector2Array([Vector2(0.016, 0.07), Vector2(0.019, 0.12), Vector2(0.015, 0.12), Vector2(0.0135, 0.072)]),
		rubber, 18, false, false)
	body.at(ax).cylinder(0.0155, 0.0705, 0.0715, lens, 18)
	body.at(ax).cylinder(0.017, -0.1605, -0.1615, lens, 18)
	body.at(ax + Vector3(0, 0, -0.02), Vector3(-90, 0, 0)).cylinder(0.01, 0.0, 0.022, metal, 14, 0.002)
	body.at(ax + Vector3(0, 0, -0.02), Vector3(0, -90, 0)).cylinder(0.01, 0.0, 0.022, metal, 14, 0.002)
	body.reset()
	# Side mount clamping to the rail
	body.box(Vector3(0.012, 0.07, 0.1), Vector3(0.0, 0.03, -0.02), metal, 0.003)
	body.box(Vector3(0.032, 0.012, 0.09), Vector3(0.016, 0.06, -0.02), metal, 0.002)
	save_model(ATTACH_OUT, "scope_pso1", {"Body": body}, {
		"ADS": ax + Vector3(0, 0, 0.12),
	}, {}, "")


# --- Beretta 92 ---------------------------------------------------------------------

func build_beretta92() -> void:
	var metal := m("gun_metal")
	var dark := m("gun_metal_grey")
	var poly := m("gun_polymer")
	var body := MeshKit.new()
	var mag := MeshKit.new()
	var slide := MeshKit.new()
	# Open-top slide: the barrel shows through the cut
	slide.extrude(P([[0.0, -0.008], [0.0, 0.012], [-0.004, 0.016], [-0.06, 0.016], [-0.07, 0.009], [-0.16, 0.009],
		[-0.17, 0.016], [-0.212, 0.016], [-0.217, 0.0], [-0.217, -0.008]]), 0.0245, metal, 0.002)
	slide.cylinder(0.0065, -0.06, -0.218, dark, 14)
	slide.box(Vector3(0.016, 0.006, 0.008), Vector3(0, 0.019, -0.01), metal, 0.001)
	for x in [-0.0055, 0.0055]:
		slide.box(Vector3(0.004, 0.005, 0.006), Vector3(x, 0.0215, -0.01), metal, 0.0005)
	slide.box(Vector3(0.0025, 0.006, 0.008), Vector3(0, 0.019, -0.205), metal)
	slide.box(Vector3(0.004, 0.008, 0.02), Vector3(0.012, 0.011, -0.02), metal, 0.001)  # decocker
	# Alloy frame, guard, grip with plastic panels
	body.extrude(P([[0.008, -0.008], [-0.175, -0.008], [-0.18, -0.02], [-0.1, -0.026], [0.0, -0.024], [0.012, -0.014]]),
		0.024, metal, 0.002)
	body.extrude(P([[-0.044, -0.024], [-0.11, -0.024], [-0.112, -0.044], [-0.098, -0.056], [-0.058, -0.058],
		[-0.05, -0.05], [-0.056, -0.044], [-0.094, -0.044], [-0.098, -0.034], [-0.054, -0.032]]), 0.009, metal, 0.0015)
	body.extrude(P([[0.012, -0.02], [-0.032, -0.02], [-0.044, -0.064], [-0.008, -0.135], [0.03, -0.135], [0.032, -0.118]]),
		0.024, metal, 0.002)
	body.extrude(P([[0.006, -0.032], [-0.034, -0.032], [-0.042, -0.064], [-0.01, -0.126], [0.024, -0.126], [0.026, -0.114]]),
		0.03, poly, 0.003)
	body.at(Vector3(0, 0.004, 0.008), Vector3(-25, 0, 0)).box(Vector3(0.008, 0.016, 0.006), Vector3.ZERO, metal, 0.001)
	body.reset()
	body.extrude(P([[-0.072, -0.028], [-0.08, -0.028], [-0.079, -0.042], [-0.074, -0.048], [-0.07, -0.046], [-0.073, -0.038]]),
		0.006, metal, 0.0008)
	# 15-round magazine, base plate showing
	mag.at(Vector3(0, -0.072, 0.008), Vector3(-18, 0, 0)).box(Vector3(0.018, 0.115, 0.032), Vector3.ZERO, metal, 0.002)
	mag.reset()
	mag.box(Vector3(0.024, 0.008, 0.04), Vector3(0, -0.138, 0.014), poly, 0.002)
	save_model(OUT, "beretta92", {"Body": body, "Magazine": mag, "Bolt": slide}, {
		"Muzzle": Vector3(0, 0, -0.218),
		"Eject": Vector3(0.013, 0.012, -0.11),
		"ADS": Vector3(0, 0.0215, -0.01),
		"Grip_R": Vector3(0, -0.07, 0.012),
		"Grip_L": Vector3(-0.024, -0.08, 0.004),
	}, {"bolt_travel": Vector3(0, 0, 0.04), "magazine_drop": Vector3(0, -0.17, 0.05)})


# --- Colt Python ---------------------------------------------------------------------
# Vent-ribbed barrel with full underlug, fluted six-shot cylinder (the "Bolt":
# it swings out to the left to reload).

func build_python() -> void:
	var metal := m("gun_metal")
	var dark := m("gun_metal_grey")
	var wood := m("gun_wood")
	var body := MeshKit.new()
	var cyl := MeshKit.new()
	# Frame with top strap, round butt grip in wood
	body.extrude(P([[0.02, -0.03], [0.02, 0.012], [-0.07, 0.018], [-0.075, 0.0], [-0.072, -0.03], [-0.03, -0.04]]),
		0.03, metal, 0.003)
	body.extrude(P([[0.02, -0.03], [-0.02, -0.035], [-0.03, -0.06], [0.005, -0.13], [0.035, -0.13], [0.035, -0.06]]),
		0.034, wood, 0.006)
	# Barrel (4"), vent rib, heavy underlug, front ramp, rear sight
	body.cylinder(0.0085, -0.075, -0.18, metal, 14)
	body.box(Vector3(0.01, 0.01, 0.105), Vector3(0, 0.012, -0.128), metal, 0.002)
	for i in 4:
		body.box(Vector3(0.0105, 0.003, 0.008), Vector3(0, 0.012, -0.09 - i * 0.022), dark)
	body.box(Vector3(0.014, 0.018, 0.105), Vector3(0, -0.012, -0.128), metal, 0.003)
	body.box(Vector3(0.003, 0.01, 0.012), Vector3(0, 0.021, -0.175), metal)
	body.box(Vector3(0.012, 0.006, 0.01), Vector3(0, 0.02, 0.005), metal, 0.001)
	# Hammer, trigger, guard
	body.at(Vector3(0, 0.012, 0.024), Vector3(-30, 0, 0)).box(Vector3(0.008, 0.02, 0.008), Vector3.ZERO, metal, 0.001)
	body.reset()
	body.extrude(P([[-0.004, -0.032], [-0.012, -0.032], [-0.011, -0.05], [-0.006, -0.056], [-0.002, -0.054], [-0.005, -0.044]]),
		0.006, metal, 0.0008)
	body.extrude(P([[0.012, -0.034], [-0.03, -0.036], [-0.04, -0.054], [-0.03, -0.066], [0.004, -0.066], [0.01, -0.058],
		[0.004, -0.054], [-0.024, -0.054], [-0.028, -0.046]]), 0.009, metal, 0.0015)
	# Fluted cylinder
	cyl.cylinder(0.019, -0.01, -0.07, metal, 24, 0.003)
	for i in 6:
		var a := TAU * i / 6.0 + TAU / 12.0
		cyl.box(Vector3(0.006, 0.004, 0.044), Vector3(cos(a) * 0.0185, sin(a) * 0.0185, -0.04), dark)
	save_model(OUT, "python", {"Body": body, "Bolt": cyl}, {
		"Muzzle": Vector3(0, 0, -0.18),
		"Eject": Vector3(0.0, 0.0, -0.04),
		"ADS": Vector3(0, 0.024, 0.005),
		"Grip_R": Vector3(0, -0.07, 0.015),
		"Grip_L": Vector3(-0.022, -0.08, 0.008),
	}, {"bolt_travel": Vector3(-0.03, 0, 0.0), "bolt_lift_degrees": 0.0})
