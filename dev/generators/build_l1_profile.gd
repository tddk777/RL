extends SceneTree
## Writes res://levels/l1_industrial/l1_profile.tres: the procedural recipe for
## Level 1 (abandoned industrial complex). Edit the .tres in the Inspector
## afterwards; re-running this overwrites it.
##
##   godot --headless --path . --script res://dev/generators/build_l1_profile.gd

const OUT := "res://levels/l1_industrial/"
const AUDIO := "res://assets/audio/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var p := LevelProfile.new()
	p.grid_size = Vector2i(25, 25)
	p.storeys = 3
	p.cell_size = 8.0
	p.storey_height = 4.5
	p.chunk_cells = 5
	p.max_block = 8
	p.min_block = 3
	p.districts = 3
	p.blend_chance = 0.4
	p.enemy_count = 8
	p.exits_min = 2
	p.exits_max = 3
	p.ammo_pickups = 12
	p.corpses = 4
	p.symbols = 3
	p.odd_corpses = 2
	p.odd_containers = 1

	var sodium := Color(1.0, 0.72, 0.42)
	var tube := Color(0.84, 0.92, 1.0)
	var bulb := Color(1.0, 0.8, 0.55)

	# --- Corridors, one per district ---
	var c_factory := _style(&"corridor", &"factory", 1.0, Vector2i(0, 0), {
		"wall_material": &"concrete_wall", "upper_wall_material": &"brick", "ceiling_material": &"concrete_dark",
		"door_width": 2.4, "ground_door_width": 3.2, "ground_door_height": 3.4,
		"light_kind": &"cage", "light_chance": 0.6, "light_working": 0.6, "flicker_chance": 0.2,
		"light_color": bulb, "light_energy": 1.4,
		"props": {"crate_small": 2.0, "barrel_rust": 2.0, "rubble": 1.0, "electrical_cabinet": 1.0, "pallet": 1.0},
		"prop_density": 0.18, "pipe_chance": 0.8, "leak_chance": 0.15, "collapse_chance": 0.03, "roof_hole_chance": 0.03,
	})
	var c_interior := _style(&"corridor", &"interior", 1.0, Vector2i(0, 0), {
		"floor_material": &"floor_tile", "upper_floor_material": &"floor_tile",
		"wall_material": &"plaster_green", "upper_wall_material": &"plaster", "ceiling_material": &"concrete_dark",
		"narrow": true, "passage_width": 2.2, "drop_ceiling": 2.7,
		"door_width": 1.4, "door_height": 2.2, "ground_door_width": 1.4, "ground_door_height": 2.2,
		"light_kind": &"fluorescent", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.35,
		"light_color": tube, "light_energy": 1.0,
		"props": {"locker": 1.0, "filing_cabinet": 1.0, "crate_small": 1.0},
		"prop_density": 0.2, "pipe_chance": 0.5, "leak_chance": 0.2,
	})
	var c_storage := _style(&"corridor", &"storage", 1.0, Vector2i(0, 0), {
		"wall_material": &"corrugated_metal", "upper_wall_material": &"corrugated_metal", "ceiling_material": &"corrugated_metal",
		"door_width": 2.4, "ground_door_width": 3.6, "ground_door_height": 3.6,
		"light_kind": &"cage", "light_chance": 0.6, "light_working": 0.6, "flicker_chance": 0.2,
		"light_color": sodium, "light_energy": 1.5,
		"props": {"pallet": 2.0, "crate_wood": 1.5, "crate_small": 1.5, "barrel_orange": 1.0},
		"prop_density": 0.22, "pipe_chance": 0.35, "leak_chance": 0.1, "roof_hole_chance": 0.03,
	})
	var corridors: Array[ZoneStyle] = [c_factory, c_interior, c_storage]
	p.corridors = corridors

	# --- Factory district ---
	var hall := _style(&"hall", &"factory", 2.2, Vector2i(1, 2), {
		"wall_material": &"concrete_wall", "upper_wall_material": &"brick", "ceiling_material": &"corrugated_metal",
		"door_width": 2.4, "ground_door_width": 4.2, "ground_door_height": 4.0, "windows": true,
		"light_kind": &"hanging", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.25,
		"light_color": sodium, "light_energy": 6.0,
		"props": {"crate_wood": 2.0, "barrel_rust": 2.0, "barrel_blue": 1.0, "pallet": 1.5, "electrical_cabinet": 0.6},
		"prop_density": 0.25, "roof_hole_chance": 0.1, "leak_chance": 0.1,
	})
	var foundry := _style(&"foundry", &"factory", 0.8, Vector2i(1, 2), {
		"wall_material": &"brick", "upper_wall_material": &"soot", "ceiling_material": &"corrugated_metal",
		"door_width": 2.4, "ground_door_width": 4.2, "ground_door_height": 4.0, "windows": true,
		"light_kind": &"hanging", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.3,
		"light_color": Color(1.0, 0.62, 0.35), "light_energy": 6.0,
		"props": {"barrel_rust": 2.0, "crate_wood": 1.0, "pallet": 1.0},
		"prop_density": 0.15, "roof_hole_chance": 0.12,
	})
	var processing := _style(&"processing", &"factory", 0.8, Vector2i(0, 2), {
		"wall_material": &"painted_steel", "upper_wall_material": &"painted_steel_green", "ceiling_material": &"concrete_dark",
		"door_width": 1.8, "ground_door_width": 2.4, "ground_door_height": 3.0,
		"light_kind": &"fluorescent", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.3,
		"light_color": tube, "light_energy": 1.3,
		"props": {"electrical_cabinet": 2.0, "barrel_blue": 1.0, "barrel_orange": 1.0, "crate_small": 1.0},
		"prop_density": 0.3, "pipe_chance": 0.6, "leak_chance": 0.2, "collapse_chance": 0.05,
	})

	# --- Interior district ---
	var office := _style(&"office", &"interior", 1.0, Vector2i(1, 2), {
		"floor_material": &"floor_tile", "upper_floor_material": &"wood_planks",
		"wall_material": &"plaster", "upper_wall_material": &"plaster", "ceiling_material": &"concrete_dark",
		"passage_width": 2.2, "drop_ceiling": 2.8,
		"door_width": 1.4, "door_height": 2.2, "ground_door_width": 1.5, "ground_door_height": 2.4,
		"light_kind": &"fluorescent", "light_chance": 0.7, "light_working": 0.65, "flicker_chance": 0.3,
		"light_color": tube, "light_energy": 1.1,
		"props": {"filing_cabinet": 2.0, "locker": 1.0, "crate_small": 0.5},
		"prop_density": 0.35, "collapse_chance": 0.05, "leak_chance": 0.1,
	})
	var maintenance := _style(&"maintenance", &"interior", 0.9, Vector2i(0, 2), {
		"wall_material": &"concrete_wall", "upper_wall_material": &"plaster_green", "ceiling_material": &"concrete_dark",
		"passage_width": 2.0, "drop_ceiling": 2.7,
		"door_width": 1.4, "door_height": 2.2, "ground_door_width": 1.4, "ground_door_height": 2.2,
		"light_kind": &"cage", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.35,
		"light_color": bulb, "light_energy": 1.2,
		"props": {"electrical_cabinet": 2.0, "locker": 1.5, "barrel_rust": 1.0, "crate_small": 1.0},
		"prop_density": 0.3, "pipe_chance": 0.7, "leak_chance": 0.25, "collapse_chance": 0.04,
	})

	# --- Storage district ---
	var warehouse := _style(&"warehouse", &"storage", 1.0, Vector2i(1, 2), {
		"wall_material": &"corrugated_metal", "upper_wall_material": &"corrugated_metal", "ceiling_material": &"corrugated_metal",
		"door_width": 2.4, "ground_door_width": 4.2, "ground_door_height": 4.0, "windows": true,
		"light_kind": &"hanging", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.2,
		"light_color": sodium, "light_energy": 5.5,
		"props": {"pallet": 2.0, "crate_wood": 2.0, "crate_small": 1.0, "barrel_orange": 1.0},
		"prop_density": 0.2, "roof_hole_chance": 0.07,
	})
	var storage := _style(&"storage", &"storage", 0.9, Vector2i(0, 2), {
		"wall_material": &"painted_steel_blue", "upper_wall_material": &"concrete_wall", "ceiling_material": &"concrete_dark",
		"door_width": 1.8, "ground_door_width": 2.4, "ground_door_height": 2.8,
		"light_kind": &"fluorescent", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.25,
		"light_color": tube, "light_energy": 1.3,
		"props": {"crate_small": 2.0, "crate_wood": 1.0, "barrel_blue": 1.0, "filing_cabinet": 0.5},
		"prop_density": 0.3, "pipe_chance": 0.3, "leak_chance": 0.12, "collapse_chance": 0.04,
	})
	var dock := _style(&"loading_dock", &"storage", 0.4, Vector2i(1, 1), {
		"wall_material": &"corrugated_metal", "upper_wall_material": &"corrugated_metal", "ceiling_material": &"corrugated_metal",
		"door_width": 2.4, "ground_door_width": 4.2, "ground_door_height": 4.0,
		"light_kind": &"hanging", "light_chance": 0.6, "light_working": 0.7, "flicker_chance": 0.2,
		"light_color": sodium, "light_energy": 6.0,
		"props": {"pallet": 3.0, "crate_wood": 3.0, "barrel_rust": 1.0, "crate_small": 1.0},
		"prop_density": 0.3, "roof_hole_chance": 0.05,
	})
	var buildings: Array[ZoneStyle] = [hall, foundry, processing, office, maintenance, warehouse, storage, dock]
	p.buildings = buildings
	p.environment = _environment()
	p.ambience = _audio("ambience/industrial_interior_loop.wav")
	var randoms: Array[AudioStream] = []
	for n in ["ambience/metal_groan_1.wav", "ambience/metal_groan_2.wav", "ambience/metal_groan_3.wav",
			"ambience/drip_1.wav", "ambience/drip_2.wav", "ambience/drip_3.wav"]:
		var s := _audio(n)
		if s:
			randoms.append(s)
	p.random_sounds = randoms
	var err := ResourceSaver.save(p, OUT + "l1_profile.tres")
	print("build_l1_profile: %s" % error_string(err))
	quit()


func _style(type: StringName, family: StringName, weight: float, extra: Vector2i, values: Dictionary) -> ZoneStyle:
	var s := ZoneStyle.new()
	s.type = type
	s.family = family
	s.weight = weight
	s.extra_storeys = extra
	for key: String in values:
		s.set(key, values[key])
	return s


func _environment() -> Environment:
	var env := Environment.new()
	# Interior level: the "outside" (seen through roof holes and windows) is an
	# overcast haze rather than open sky.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.3, 0.32, 0.34)
	# Interiors: light comes from fixtures and shafts, not the sky.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.48, 0.55)
	env.ambient_light_energy = 0.6
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.35
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.2
	env.ssil_enabled = true
	# No SDFGI: in enclosed spaces it replaces the ambient light, so every room a
	# lamp doesn't reach (and the haze outside) renders pitch black.
	env.sdfgi_enabled = false
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.fog_enabled = true
	# Soft exponential haze: distance fades gently instead of going black.
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.2, 0.21, 0.23)
	env.fog_density = 0.006
	env.fog_sky_affect = 0.5
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.022
	env.volumetric_fog_albedo = Color(0.72, 0.72, 0.7)
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 64.0
	env.volumetric_fog_ambient_inject = 0.2
	env.volumetric_fog_sky_affect = 0.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.78
	env.adjustment_contrast = 1.08
	return env


func _audio(path: String) -> AudioStream:
	return load(AUDIO + path) if ResourceLoader.exists(AUDIO + path) else null
