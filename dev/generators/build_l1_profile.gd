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
	p.grid_size = Vector2i(48, 48)
	p.storeys = 4
	p.cell_size = 8.0
	p.storey_height = 6.0
	p.chunk_cells = 4
	p.max_block = 12
	p.min_block = 4
	p.enemy_count = 26
	p.exits_min = 2
	p.exits_max = 3
	p.ammo_pickups = 40
	p.corpses = 9
	p.symbols = 4
	p.odd_corpses = 2
	p.odd_containers = 1

	var sodium := Color(1.0, 0.72, 0.42)
	var tube := Color(0.84, 0.92, 1.0)
	var bulb := Color(1.0, 0.8, 0.55)

	p.corridor = _style(&"corridor", 1.0, Vector2i(0, 0), {
		"wall_material": &"concrete_wall", "upper_wall_material": &"concrete_wall", "ceiling_material": &"concrete_dark",
		"light_kind": &"cage", "light_chance": 0.6, "light_working": 0.65, "flicker_chance": 0.2,
		"light_color": bulb, "light_energy": 1.3,
		"props": {"crate_small": 2.0, "barrel_rust": 2.0, "rubble": 1.0, "electrical_cabinet": 1.0, "pallet": 1.0},
		"prop_density": 0.16, "pipe_chance": 0.75, "leak_chance": 0.12, "collapse_chance": 0.035, "roof_hole_chance": 0.02,
	})
	var hall := _style(&"hall", 1.3, Vector2i(1, 3), {
		"wall_material": &"concrete_wall", "upper_wall_material": &"brick", "ceiling_material": &"corrugated_metal",
		"ground_door_width": 4.2, "ground_door_height": 4.4, "windows": true,
		"light_kind": &"hanging", "light_chance": 0.45, "light_working": 0.55, "flicker_chance": 0.25,
		"light_color": sodium, "light_energy": 7.0,
		"props": {"crate_wood": 2.0, "barrel_rust": 2.0, "barrel_blue": 1.0, "pallet": 1.5, "rubble": 1.0, "electrical_cabinet": 0.6},
		"prop_density": 0.3, "roof_hole_chance": 0.12,
	})
	var warehouse := _style(&"warehouse", 1.0, Vector2i(1, 2), {
		"wall_material": &"corrugated_metal", "upper_wall_material": &"corrugated_metal", "ceiling_material": &"corrugated_metal",
		"ground_door_width": 4.2, "ground_door_height": 4.4, "windows": true,
		"light_kind": &"hanging", "light_chance": 0.4, "light_working": 0.5, "flicker_chance": 0.2,
		"light_color": sodium, "light_energy": 6.0,
		"props": {"pallet": 2.0, "crate_wood": 2.0, "crate_small": 1.0, "barrel_orange": 1.0},
		"prop_density": 0.3, "roof_hole_chance": 0.07,
	})
	var processing := _style(&"processing", 1.0, Vector2i(0, 2), {
		"wall_material": &"painted_steel", "upper_wall_material": &"painted_steel", "ceiling_material": &"concrete_dark",
		"light_kind": &"fluorescent", "light_chance": 0.6, "light_working": 0.6, "flicker_chance": 0.3,
		"light_color": tube, "light_energy": 1.4,
		"props": {"electrical_cabinet": 2.0, "barrel_blue": 1.0, "barrel_orange": 1.0, "crate_small": 1.0, "filing_cabinet": 0.5},
		"prop_density": 0.4, "pipe_chance": 0.5, "leak_chance": 0.15, "collapse_chance": 0.06,
	})
	var office := _style(&"office", 1.0, Vector2i(1, 3), {
		"upper_floor_material": &"wood_planks", "wall_material": &"concrete_wall", "upper_wall_material": &"concrete_wall",
		"ceiling_material": &"concrete_dark",
		"light_kind": &"fluorescent", "light_chance": 0.7, "light_working": 0.6, "flicker_chance": 0.25,
		"light_color": tube, "light_energy": 1.3,
		"props": {"desk": 3.0, "filing_cabinet": 2.0, "locker": 2.0, "crate_small": 0.7, "rubble": 0.4},
		"prop_density": 0.75, "collapse_chance": 0.05,
	})
	var dock := _style(&"loading_dock", 0.3, Vector2i(1, 1), {
		"wall_material": &"corrugated_metal", "upper_wall_material": &"corrugated_metal", "ceiling_material": &"corrugated_metal",
		"ground_door_width": 4.2, "ground_door_height": 4.4,
		"light_kind": &"hanging", "light_chance": 0.5, "light_working": 0.7, "flicker_chance": 0.2,
		"light_color": sodium, "light_energy": 6.5,
		"props": {"pallet": 3.0, "crate_wood": 3.0, "barrel_rust": 1.0, "crate_small": 1.0},
		"prop_density": 0.35, "roof_hole_chance": 0.05,
	})
	var buildings: Array[ZoneStyle] = [hall, warehouse, processing, office, dock]
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


func _style(type: StringName, weight: float, extra: Vector2i, values: Dictionary) -> ZoneStyle:
	var s := ZoneStyle.new()
	s.type = type
	s.weight = weight
	s.extra_storeys = extra
	for key: String in values:
		s.set(key, values[key])
	return s


func _environment() -> Environment:
	var env := Environment.new()
	# Interior level: the "outside" (and anything not streamed in yet) is an
	# overcast haze rather than open sky.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.17, 0.18, 0.2)
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
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.17, 0.18, 0.2)
	env.fog_depth_begin = 25.0
	env.fog_depth_end = 88.0
	env.fog_sky_affect = 0.0
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
