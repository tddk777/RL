extends SceneTree
## Writes the starting content definitions into res://content/. After this
## bootstrap, edit the .tres files in the Godot Inspector; re-running this
## script overwrites them.
##
##   godot --headless --path . --script res://dev/generators/build_content.gd

const AUDIO := "res://assets/audio/"
const FX := "res://assets/textures/fx/"


func _initialize() -> void:
	for dir in ["surfaces", "ammo", "weapons", "attachments", "enemies", "levels"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://content/" + dir))
	_surfaces()
	var ammo := _ammo()
	var attachments := _attachments()
	_weapons(ammo, attachments)
	_enemies()
	_levels()
	print("build_content: done")
	quit()


func save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_error("save %s: %s" % [path, error_string(err)])
	res.take_over_path(path)


func sounds(prefix: String, count: int) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for i in count:
		var path := AUDIO + "%s_%d.wav" % [prefix, i + 1]
		if ResourceLoader.exists(path):
			out.append(load(path))
	return out


func sound(path: String) -> AudioStream:
	return load(AUDIO + path) if ResourceLoader.exists(AUDIO + path) else null


func tex(name: String) -> Texture2D:
	return load(FX + name) if ResourceLoader.exists(FX + name) else null


# --- Surfaces -----------------------------------------------------------------------

func _surfaces() -> void:
	var defs := {
		"concrete": {"impact": "impacts/concrete", "steps": "footsteps/concrete", "land": "footsteps/land_concrete.wav",
			"casings": "casings/brass_concrete", "decal": "bullet_hole_concrete.png", "particle": "dust_puff.png",
			"color": Color(0.62, 0.6, 0.56), "amount": 12, "speed": 2.5, "size": 0.14},
		"metal": {"impact": "impacts/metal", "steps": "footsteps/metal", "land": "footsteps/land_metal.wav",
			"casings": "casings/brass_metal", "decal": "bullet_hole_metal.png", "particle": "smoke_puff.png",
			"color": Color(0.35, 0.34, 0.33), "amount": 5, "speed": 1.5, "size": 0.1, "sparks": true, "ricochet": 0.25},
		"wood": {"impact": "impacts/wood", "steps": "footsteps/wood", "land": "footsteps/land_concrete.wav",
			"casings": "casings/brass_concrete", "decal": "bullet_hole_wood.png", "particle": "dust_puff.png",
			"color": Color(0.5, 0.4, 0.3), "amount": 10, "speed": 2.2, "size": 0.1},
		"flesh": {"impact": "impacts/flesh", "steps": "footsteps/concrete", "land": "footsteps/land_concrete.wav",
			"casings": "casings/brass_concrete", "decal": "", "particle": "blood_puff.png",
			"color": Color(0.38, 0.04, 0.03), "amount": 9, "speed": 1.8, "size": 0.16},
	}
	for id: String in defs:
		var d: Dictionary = defs[id]
		var s := SurfaceData.new()
		s.id = StringName(id)
		s.impact_sounds = sounds(d["impact"], 3)
		s.footstep_sounds = sounds(d["steps"], 4)
		s.land_sound = sound(d["land"])
		s.casing_sounds = sounds(d["casings"], 3)
		if d.get("ricochet", 0.0) > 0.0:
			s.ricochet_sounds = sounds("impacts/ricochet", 2)
			s.ricochet_chance = d["ricochet"]
		var decals: Array[Texture2D] = []
		if d["decal"] != "":
			decals.append(tex(d["decal"]))
		s.decal_textures = decals
		s.particle_texture = tex(d["particle"])
		s.particle_color = d["color"]
		s.particle_amount = d["amount"]
		s.particle_speed = d["speed"]
		s.particle_size = d["size"]
		s.sparks = d.get("sparks", false)
		save(s, "res://content/surfaces/%s.tres" % id)


# --- Ammo ------------------------------------------------------------------------------

func _ammo() -> Dictionary:
	var defs := [
		["762x39_ps", "7.62x39mm PS", "7.62x39", 50.0, "Steel-core rifle round."],
		["556x45_m855", "5.56x45mm M855", "5.56x45", 42.0, "Green-tip NATO rifle round."],
		["9x19_fmj", "9x19mm FMJ", "9x19", 30.0, "Full metal jacket pistol round."],
		["762x51_m118", "7.62x51mm M118", "7.62x51", 105.0, "Match-grade long-range rifle round."],
		["45acp_fmj", ".45 ACP FMJ", ".45ACP", 38.0, "Heavy, slow, subsonic pistol round."],
	]
	var out := {}
	for d in defs:
		var a := AmmoData.new()
		a.id = StringName(d[0])
		a.display_name = d[1]
		a.caliber = StringName(d[2])
		a.damage = d[3]
		a.description = d[4]
		a.weight_kg = 0.012
		save(a, "res://content/ammo/%s.tres" % d[0])
		out[d[2]] = a
	return out


# --- Attachments --------------------------------------------------------------------

func _attachments() -> Dictionary:
	var scope := AttachmentData.new()
	scope.id = &"scope_m40"
	scope.display_name = "10x sniper scope"
	scope.description = "Fixed-power rifle scope with duplex reticle."
	scope.slot = &"optic"
	scope.mount_type = &"m40_base"
	scope.model_scene = load("res://assets/models/attachments/scope_m40/scope_m40.tscn")
	scope.ads_fov = 8.0
	scope.ads_time_multiplier = 1.25
	scope.ads_overlay = tex("scope_overlay.png")
	scope.weight_kg = 0.6
	save(scope, "res://content/attachments/scope_m40.tres")
	return {"scope_m40": scope}


# --- Weapons -----------------------------------------------------------------------------

func _weapons(ammo: Dictionary, attachments: Dictionary) -> void:
	var F := WeaponData.FireMode
	_weapon({
		"id": "ak47", "name": "AK-47", "caliber": "7.62x39", "desc": "Soviet assault rifle. Heavy round, heavy recoil, runs on anything.",
		"modes": [F.SEMI, F.AUTO], "rpm": 600.0, "velocity": 715.0, "mag": 30,
		"spread": [2.6, 0.13, 1.6], "recoil": [1.45, 0.6, 0.55, 0.05, 4.5],
		"ads": [0.28, 55.0, 0.13], "hip": Vector3(0.155, -0.175, -0.31), "length": 0.95,
		"reload": [2.5, 3.2], "cycle": 0.9, "weight": 3.5, "loudness": 130.0, "sway": 1.1,
	}, ammo)
	_weapon({
		"id": "m16", "name": "M16A2", "caliber": "5.56x45", "desc": "US service rifle. Fast, flat round with a three-round burst.",
		"modes": [F.SEMI, F.BURST], "rpm": 800.0, "velocity": 948.0, "mag": 30,
		"spread": [2.4, 0.1, 1.5], "recoil": [1.05, 0.35, 0.6, 0.04, 3.5],
		"ads": [0.3, 52.0, 0.16], "hip": Vector3(0.155, -0.16, -0.30), "length": 1.1,
		"reload": [2.3, 2.9], "cycle": 0.8, "weight": 3.6, "loudness": 125.0, "sway": 1.15,
	}, ammo)
	_weapon({
		"id": "mp5", "name": "MP5", "caliber": "9x19", "desc": "Roller-delayed submachine gun. Quiet, controllable, short range.",
		"modes": [F.SEMI, F.AUTO], "rpm": 800.0, "velocity": 400.0, "mag": 30,
		"spread": [2.2, 0.18, 1.0], "recoil": [0.65, 0.35, 0.7, 0.03, 2.6],
		"ads": [0.2, 58.0, 0.16], "hip": Vector3(0.15, -0.165, -0.27), "length": 0.72,
		"reload": [2.2, 2.8], "cycle": 0.7, "weight": 2.5, "loudness": 90.0, "sway": 0.8,
	}, ammo)
	_weapon({
		"id": "m40", "name": "M40", "caliber": "7.62x51", "desc": "Bolt-action sniper rifle with a fixed 10x scope.",
		"modes": [F.BOLT], "rpm": 60.0, "velocity": 790.0, "mag": 5, "feed": WeaponData.Feed.INTERNAL,
		"spread": [3.2, 0.02, 2.0], "recoil": [3.4, 0.7, 0.35, 0.08, 7.0],
		"ads": [0.4, 30.0, 0.06], "hip": Vector3(0.16, -0.17, -0.36), "length": 1.2,
		"reload": [0.0, 0.0], "cycle": 1.0, "insert": 0.6, "weight": 6.6, "loudness": 160.0, "sway": 1.4,
		"mounts": {"optic": ["m40_base"]}, "attachments": [attachments["scope_m40"]],
	}, ammo)
	_weapon({
		"id": "m1911", "name": "M1911", "caliber": ".45ACP", "desc": "Single-action .45 pistol. Seven rounds, heavy kick, very old.",
		"modes": [F.SEMI], "rpm": 450.0, "velocity": 253.0, "mag": 7,
		"spread": [2.8, 0.35, 1.2], "recoil": [2.4, 0.9, 0.7, 0.045, 9.0],
		"ads": [0.18, 62.0, 0.42], "hip": Vector3(0.12, -0.15, -0.36), "length": 0.45,
		"reload": [1.7, 2.1], "cycle": 0.45, "weight": 1.1, "loudness": 105.0, "sway": 0.9,
	}, ammo)


func _weapon(d: Dictionary, ammo: Dictionary) -> void:
	var id: String = d["id"]
	var w := WeaponData.new()
	w.id = StringName(id)
	w.display_name = d["name"]
	w.description = d["desc"]
	w.weight_kg = d["weight"]
	w.model_scene = load("res://assets/models/weapons/%s/%s.tscn" % [id, id])
	w.caliber = StringName(d["caliber"])
	w.default_ammo = ammo[d["caliber"]]
	w.feed = d.get("feed", WeaponData.Feed.MAGAZINE)
	w.magazine_size = d["mag"]
	var modes: Array[WeaponData.FireMode] = []
	for mode in d["modes"]:
		modes.append(mode)
	w.fire_modes = modes
	w.rounds_per_minute = d["rpm"]
	w.muzzle_velocity = d["velocity"]
	w.spread_hip = d["spread"][0]
	w.spread_ads = d["spread"][1]
	w.spread_moving = d["spread"][2]
	w.recoil_vertical = d["recoil"][0]
	w.recoil_horizontal = d["recoil"][1]
	w.recoil_recovery = d["recoil"][2]
	w.kick_back = d["recoil"][3]
	w.kick_rotation = d["recoil"][4]
	w.ads_time = d["ads"][0]
	w.ads_fov = d["ads"][1]
	w.ads_eye_distance = d["ads"][2]
	w.hip_offset = d["hip"]
	w.length = d["length"]
	w.reload_time = d["reload"][0]
	w.reload_empty_time = d["reload"][1]
	w.cycle_time = d["cycle"]
	w.insert_time = d.get("insert", 0.55)
	w.loudness = d["loudness"]
	w.sway = d["sway"]
	w.mount_types = d.get("mounts", {})
	var atts: Array[AttachmentData] = []
	for a in d.get("attachments", []):
		atts.append(a)
	w.default_attachments = atts
	var base := "weapons/%s/" % id
	w.shot_sounds = sounds(base + "shot", 3)
	w.distant_shot_sound = sound(base + "shot_distant.wav")
	w.dry_fire_sound = sound(base + "dry_fire.wav")
	w.mag_out_sound = sound(base + "mag_out.wav")
	w.mag_in_sound = sound(base + "mag_in.wav")
	w.charge_sound = sound(base + "charge.wav")
	w.fire_select_sound = sound(base + "fire_select.wav")
	w.muzzle_flash_scale = {"m40": 1.3, "mp5": 0.7, "m1911": 0.6}.get(id, 1.0)
	w.casing_scale = {"mp5": 0.75, "m40": 1.3, "m1911": 0.8}.get(id, 1.0)
	w.equip_time = 0.35 if id == "m1911" else 0.5
	save(w, "res://content/weapons/%s.tres" % id)


# --- Enemies ---------------------------------------------------------------------------

func _enemies() -> void:
	var e := EnemyData.new()
	e.id = &"scavenger"
	e.display_name = "Scavenger"
	e.scene = load("res://ai/human_npc.tscn")
	e.max_health = 100.0
	e.weapon = load("res://content/weapons/ak47.tres")
	e.sight_range = 40.0
	e.sight_fov_degrees = 110.0
	e.detection_time = 0.9
	e.aim_error = 3.2
	e.reaction_time = 0.7
	# Scavengers: rough, mixed bunch. Some reckless, most so-so shots.
	e.aggression = 0.5
	e.aggression_spread = 0.3
	e.skill = 0.4
	e.skill_spread = 0.25
	e.burst_min = 2
	e.burst_max = 5
	e.burst_pause = 0.8
	save(e, "res://content/enemies/scavenger.tres")


# --- Levels ------------------------------------------------------------------------------

func _levels() -> void:
	var l := LevelData.new()
	l.id = &"l1_industrial"
	l.display_name = "The Works"
	l.subtitle = "Level 1  \u00b7  Abandoned industrial complex"
	l.order = 1
	l.scene_path = "res://levels/l1_industrial/l1_industrial.tscn"
	save(l, "res://content/levels/l1_industrial.tres")
