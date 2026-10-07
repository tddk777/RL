extends SceneTree
## Wraps the 1960s Soviet PSX weapon pack (assets/third_party/soviet_psx_weapons)
## in the WeaponModel contract and writes their weapon and ammo data. A
## bootstrap like the other generators: markers are found from the meshes
## (barrel tip, front sight, grip below the receiver, magazine), stats are
## the real guns' (calibre, capacity, rate of fire, muzzle velocity, weight).
## Re-running overwrites the scenes and .tres files it writes; the AK-47 only
## gets its model swapped.
##
##   godot --headless --path . --script res://dev/generators/build_psx_weapons.gd

const SRC := "res://assets/third_party/soviet_psx_weapons/"
const OUT := "res://assets/models/weapons/"

## id -> real overall length (m), kind, moving parts in the .glb
const GUNS := {
	"makarov": {"length": 0.161, "kind": "pistol", "mag": "mag", "bolt": "slide", "travel": 0.022},
	"tokarev": {"length": 0.196, "kind": "pistol", "mag": "mag", "bolt": "slide", "travel": 0.026},
	"ppsh41": {"length": 0.843, "kind": "rifle", "mag": "mag", "bolt": "charging_handle", "travel": 0.06},
	"sks": {"length": 1.02, "kind": "rifle", "mag": "", "bolt": "charger", "travel": 0.07},
	"ak47": {"length": 0.88, "kind": "rifle", "mag": "mag", "bolt": "charging_handle", "travel": 0.075},
}


func _initialize() -> void:
	var ammo := _ammo()
	for id: String in GUNS:
		var scene_path := _build_model(id, GUNS[id])
		if id == "ak47":
			# Same rifle as before: just its new look.
			var ak: WeaponData = load("res://content/weapons/ak47.tres")
			ak.model_scene = load(scene_path)
			save(ak, "res://content/weapons/ak47.tres")
		else:
			_weapon(id, load(scene_path), ammo)
	print("build_psx_weapons: done")
	quit()


func save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_error("save %s: %s" % [path, error_string(err)])
	res.take_over_path(path)


# --- Models -------------------------------------------------------------------------

## Vertices of every mesh under `root`, in root space, by node name.
func _vertices(root: Node3D) -> Dictionary:
	var out := {}
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != root:
			xf = (cur as Node3D).transform * xf
			cur = cur.get_parent()
		var pts := PackedVector3Array()
		for i in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]:
				pts.append(xf * v)
		out[String(mi.name)] = pts
	return out


static func _box(pts: PackedVector3Array) -> AABB:
	var b := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		b = b.expand(p)
	return b


func _build_model(id: String, spec: Dictionary) -> String:
	var glb: PackedScene = load(SRC + id + ".glb")
	var probe := glb.instantiate() as Node3D
	var parts := _vertices(probe)
	probe.free()
	var all := PackedVector3Array()
	for k: String in parts:
		all.append_array(parts[k])
	var box := _box(all)
	var length: float = spec["length"]
	var s := length / box.size.z  # metres per model unit
	var front := box.position.z  # barrel along -Z
	var mag: AABB = _box(parts[spec["mag"]]) if spec["mag"] != "" else AABB()
	var bolt: AABB = _box(parts[spec["bolt"]])
	# Bore height: the barrel part, or the very tip of the gun.
	var bore := 0.0
	if parts.has("barrel"):
		bore = _box(parts["barrel"]).get_center().y
	else:
		var lo := INF
		var hi := -INF
		for p in all:
			if p.z < front + box.size.z * 0.012:
				lo = minf(lo, p.y)
				hi = maxf(hi, p.y)
		bore = (lo + hi) * 0.5
	# Front sight: the highest point near the muzzle.
	var sight_y := -INF
	var reach := (0.06 if spec["kind"] == "pistol" else 0.14) * box.size.z
	for p in all:
		if p.z < front + reach:
			sight_y = maxf(sight_y, p.y)
	var grip: Vector3
	var support: Vector3
	var origin_z: float
	var m := 1.0 / s  # model units per metre
	if spec["kind"] == "pistol":
		grip = Vector3(0, mag.end.y - mag.size.y * 0.3, mag.get_center().z)
		origin_z = bolt.end.z  # rear of the slide
		support = grip + Vector3(-0.024, -0.01, -0.008) * m
	else:
		# The hand sits behind the magazine (or the receiver), below the bore.
		var z0 := (mag.end.z if spec["mag"] != "" else bolt.end.z) + 0.03 * m
		var z1 := z0 + 0.13 * m
		var sum := Vector3.ZERO
		var n := 0
		for p in all:
			if p.z > z0 and p.z < z1 and p.y < bore - 0.05 * m:
				sum += p
				n += 1
		grip = sum / maxi(n, 1) if n > 0 else Vector3(0, bore - 0.09 * m, (z0 + z1) * 0.5)
		grip.x = 0.0
		origin_z = grip.z + 0.035 * m  # grip 3.5 cm ahead of the receiver rear
		var hand_z := (mag.position.z if spec["mag"] != "" else bolt.position.z) - 0.12 * m
		support = Vector3(0, bore - 0.03 * m, hand_z)
	var origin := Vector3(0, bore, origin_z)
	var to_m := func(p: Vector3) -> Vector3: return (p - origin) * s

	var root := Node3D.new()
	root.name = id.capitalize().replace(" ", "")
	root.set_script(load("res://weapons/weapon_model.gd"))
	var model := glb.instantiate() as Node3D
	model.name = "Model"
	model.transform = Transform3D(Basis.from_scale(Vector3.ONE * s), -origin * s)
	root.add_child(model)
	model.owner = root
	if spec["mag"] != "":
		root.set(&"magazine_path", NodePath("Model/" + spec["mag"]))
		root.set(&"magazine_drop", Vector3(0, -0.16, 0.0) if spec["kind"] == "pistol" else Vector3(0, -0.24, 0.03))
	root.set(&"bolt_path", NodePath("Model/" + spec["bolt"]))
	root.set(&"bolt_travel", Vector3(0, 0, spec["travel"]))
	var grip_m: Vector3 = to_m.call(grip)
	var support_m: Vector3 = to_m.call(support)
	if spec["kind"] == "pistol":
		# Same hand placement as the M1911: web of the hand under the slide
		# tang (the magazine centre sat the hand over the slide).
		grip_m = Vector3(0, -0.066, 0.01)
		support_m = grip_m + Vector3(-0.024, -0.01, -0.008)
	var ads_z: float = -0.012 if spec["kind"] == "pistol" else grip_m.z - 0.21
	var eject: Vector3
	var front_m: Vector3 = to_m.call(Vector3(0, bore, front))
	var mag_rear_m: Vector3 = to_m.call(Vector3(0, bore, mag.end.z))
	var bolt_m: Vector3 = to_m.call(bolt.get_center())
	var sight_m: Vector3 = to_m.call(Vector3(0, sight_y, 0))
	if spec["kind"] == "pistol":
		eject = Vector3(0.013, 0.008, front_m.z * 0.3)
	elif spec["mag"] != "":
		eject = Vector3(0.022, 0.006, mag_rear_m.z + 0.01)
	else:
		eject = Vector3(0.022, 0.01, bolt_m.z)
	var markers := {
		"Muzzle": front_m,
		"Eject": eject,
		"ADS": Vector3(0, sight_m.y - 0.002, ads_z),
		"Grip_R": grip_m,
		"Grip_L": support_m,
	}
	for name: String in markers:
		var mk := Marker3D.new()
		mk.name = name
		mk.gizmo_extents = 0.02
		mk.position = markers[name]
		root.add_child(mk)
		mk.owner = root
	print("%s: scale %.4f, markers %s" % [id, s, markers])
	var dir := OUT + id + "_psx/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var packed := PackedScene.new()
	packed.pack(root)
	var path := dir + id + "_psx.tscn"
	save(packed, path)
	root.free()
	return path


# --- Data ---------------------------------------------------------------------------

func _ammo() -> Dictionary:
	var out := {}
	for spec: Array in [
		["9x18_pm", &"9x18", 26.0, "9x18mm Makarov", "Soviet pistol round, a little weaker than 9x19.", 0.01],
		["762x25_p", &"7.62x25", 30.0, "7.62x25mm Tokarev", "Small, very fast pistol round. Goes through soft cover.", 0.011],
	]:
		var a := AmmoData.new()
		a.id = StringName(spec[0])
		a.caliber = spec[1]
		a.damage = spec[2]
		a.display_name = spec[3]
		a.description = spec[4]
		a.weight_kg = spec[5]
		save(a, "res://content/ammo/%s.tres" % spec[0])
		out[spec[1]] = a
	out[&"7.62x39"] = load("res://content/ammo/762x39_ps.tres")
	return out


## Real-world numbers. Handling values follow the closest existing weapon.
func _weapon(id: String, scene: PackedScene, ammo: Dictionary) -> void:
	var w := WeaponData.new()
	var like: WeaponData
	match id:
		"makarov":
			like = load("res://content/weapons/m1911.tres")
			w.display_name = "Makarov PM"
			w.description = "Soviet service pistol. Eight rounds of 9x18, blowback, simple and soft-shooting."
			w.caliber = &"9x18"
			w.magazine_size = 8
			w.fire_modes = [WeaponData.FireMode.SEMI]
			w.rounds_per_minute = 450.0
			w.muzzle_velocity = 315.0
			w.weight_kg = 0.73
			w.length = 0.4
			w.recoil_vertical = 1.9
			w.recoil_horizontal = 0.7
			w.loudness = 100.0
		"tokarev":
			like = load("res://content/weapons/m1911.tres")
			w.display_name = "TT-33"
			w.description = "Tokarev pistol. Eight rounds of hot 7.62x25 that punch through cover; no safety to speak of."
			w.caliber = &"7.62x25"
			w.magazine_size = 8
			w.fire_modes = [WeaponData.FireMode.SEMI]
			w.rounds_per_minute = 450.0
			w.muzzle_velocity = 420.0
			w.weight_kg = 0.85
			w.length = 0.42
			w.recoil_vertical = 2.2
			w.recoil_horizontal = 0.8
			w.loudness = 112.0
		"ppsh41":
			like = load("res://content/weapons/mp5.tres")
			w.display_name = "PPSh-41"
			w.description = "Wartime submachine gun. 35-round box of 7.62x25, about a thousand rounds a minute."
			w.caliber = &"7.62x25"
			w.magazine_size = 35
			w.fire_modes = [WeaponData.FireMode.AUTO, WeaponData.FireMode.SEMI]
			w.rounds_per_minute = 1000.0
			w.muzzle_velocity = 488.0
			w.weight_kg = 3.6
			w.length = 0.84
			w.recoil_vertical = 1.0
			w.recoil_horizontal = 0.55
			w.loudness = 120.0
		"sks":
			like = load("res://content/weapons/ak47.tres")
			w.display_name = "SKS"
			w.description = "Semi-automatic carbine. Ten rounds of 7.62x39 in a fixed magazine, loaded through the top."
			w.caliber = &"7.62x39"
			w.feed = WeaponData.Feed.INTERNAL
			w.magazine_size = 10
			w.insert_time = 0.32
			w.fire_modes = [WeaponData.FireMode.SEMI]
			w.rounds_per_minute = 400.0
			w.muzzle_velocity = 735.0
			w.weight_kg = 3.85
			w.length = 1.02
			w.recoil_vertical = 1.6
			w.recoil_horizontal = 0.5
			w.spread_hip = 2.4
			w.spread_ads = 0.09
			w.loudness = 130.0
	w.id = StringName(id)
	w.model_scene = scene
	w.default_ammo = ammo[w.caliber]
	for prop in ["spread_moving", "recoil_recovery", "kick_back", "kick_rotation", "ads_time", "ads_fov", "hip_offset",
			"ads_eye_distance", "sway", "reload_time", "reload_empty_time", "cycle_time", "equip_time", "shot_sounds",
			"distant_shot_sound", "dry_fire_sound", "mag_out_sound", "mag_in_sound", "charge_sound", "fire_select_sound",
			"muzzle_flash_scale", "casing_scale"]:
		w.set(prop, like.get(prop))
	if id in ["ppsh41", "sks"]:
		w.ads_eye_distance = 0.17  # the blocky receivers crowd the view any closer
	if id != "sks":
		w.spread_hip = like.spread_hip
		w.spread_ads = like.spread_ads
	save(w, "res://content/weapons/%s.tres" % id)
