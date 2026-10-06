extends SceneTree
## Writes res://assets/materials/*.tres from the textures in
## res://assets/textures/<name>/ (albedo, normal, roughness, metallic).
## Missing textures fall back to flat values, so this can run before the
## texture generator has. Models and levels reference these files by path,
## so regenerating materials restyles everything without touching scenes.
##
##   godot --headless --path . --script res://dev/generators/build_materials.gd

const OUT := "res://assets/materials/"
const TEX := "res://assets/textures/"

## name: [texture folder, tint, roughness, metallic, triplanar scale, world-space triplanar, extra]
const DEFS := {
	# Environment (world-space triplanar: no UVs needed on level geometry)
	"concrete_floor": ["concrete_floor", Color(1, 1, 1), 0.9, 0.0, 0.35, true, {}],
	"concrete_wall": ["concrete_wall", Color(1, 1, 1), 0.92, 0.0, 0.35, true, {}],
	"concrete_dark": ["concrete_wall", Color(0.55, 0.55, 0.55), 0.95, 0.0, 0.35, true, {}],
	"rusted_metal": ["rusted_metal", Color(1, 1, 1), 0.8, 0.5, 0.5, true, {}],
	"painted_steel": ["painted_steel", Color(1, 1, 1), 0.7, 0.3, 0.5, true, {}],
	"painted_steel_yellow": ["painted_steel", Color(1.35, 1.1, 0.45), 0.7, 0.3, 0.5, true, {}],
	"painted_steel_red": ["painted_steel", Color(1.2, 0.45, 0.38), 0.7, 0.3, 0.5, true, {}],
	"corrugated_metal": ["corrugated_metal", Color(1, 1, 1), 0.6, 0.6, 0.5, true, {}],
	"steel_grate": ["steel_grate", Color(1, 1, 1), 0.65, 0.7, 1.0, true, {"alpha_scissor": true}],
	"wood_planks": ["wood_planks", Color(1, 1, 1), 0.85, 0.0, 0.5, true, {}],
	"brick": ["brick", Color(1, 1, 1), 0.9, 0.0, 0.5, true, {}],
	"tiles_dirty": ["tiles_dirty", Color(1, 1, 1), 0.35, 0.0, 0.6, true, {}],
	"glass_dirty": ["", Color(0.55, 0.6, 0.58, 0.35), 0.15, 0.0, 1.0, true, {"transparent": true}],
	# Props (object-space triplanar so props can be moved)
	"prop_wood": ["wood_planks", Color(1, 1, 1), 0.85, 0.0, 1.2, false, {}],
	"prop_rust": ["rusted_metal", Color(1, 1, 1), 0.8, 0.5, 1.2, false, {}],
	"prop_steel": ["painted_steel", Color(1, 1, 1), 0.7, 0.3, 1.2, false, {}],
	"prop_steel_blue": ["painted_steel", Color(0.55, 0.75, 1.05), 0.7, 0.3, 1.2, false, {}],
	"prop_steel_orange": ["painted_steel", Color(1.4, 0.75, 0.35), 0.7, 0.3, 1.2, false, {}],
	"prop_rubber": ["rubber", Color(1, 1, 1), 0.8, 0.0, 2.0, false, {}],
	"lamp_emissive": ["", Color(1.0, 0.95, 0.85), 0.5, 0.0, 1.0, false, {"emission": Color(1.0, 0.92, 0.78), "energy": 4.0}],
	"lamp_emissive_red": ["", Color(1.0, 0.2, 0.15), 0.5, 0.0, 1.0, false, {"emission": Color(1.0, 0.12, 0.08), "energy": 5.0}],
	"lamp_dead": ["", Color(0.6, 0.6, 0.58), 0.35, 0.0, 1.0, false, {}],
	# Weapons (object-space triplanar, small scale for fine detail)
	"gun_metal": ["gun_metal", Color(1, 1, 1), 0.45, 0.9, 5.0, false, {}],
	"gun_metal_grey": ["gun_metal", Color(1.5, 1.5, 1.55), 0.55, 0.7, 5.0, false, {}],
	"gun_polymer": ["gun_polymer", Color(1, 1, 1), 0.7, 0.0, 5.0, false, {}],
	"gun_polymer_olive": ["gun_polymer", Color(1.9, 2.0, 1.35), 0.75, 0.0, 5.0, false, {}],
	"gun_wood": ["gun_wood", Color(1, 1, 1), 0.45, 0.0, 4.0, false, {}],
	"gun_lens": ["", Color(0.04, 0.06, 0.08), 0.05, 0.6, 1.0, false, {}],
	# Characters
	"fabric_canvas": ["fabric_canvas", Color(1, 1, 1), 0.95, 0.0, 3.0, false, {}],
	"fabric_dark": ["fabric_dark", Color(1, 1, 1), 0.95, 0.0, 3.0, false, {}],
	"leather": ["leather", Color(1, 1, 1), 0.7, 0.0, 3.0, false, {}],
	"rubber": ["rubber", Color(1, 1, 1), 0.75, 0.0, 3.0, false, {}],
	"mask_glass": ["", Color(0.05, 0.07, 0.06), 0.08, 0.3, 1.0, false, {}],
}


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var made := 0
	for name: String in DEFS:
		var def: Array = DEFS[name]
		var mat := _build(def)
		var err := ResourceSaver.save(mat, OUT + name + ".tres")
		if err != OK:
			push_error("Could not save %s: %s" % [name, err])
		else:
			made += 1
	print("build_materials: wrote %d materials" % made)
	quit()


func _build(def: Array) -> StandardMaterial3D:
	var folder: String = def[0]
	var tint: Color = def[1]
	var extra: Dictionary = def[6]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = def[2]
	mat.metallic = def[3]
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = def[5]
	mat.uv1_triplanar_sharpness = 4.0
	mat.uv1_scale = Vector3.ONE * float(def[4])
	if folder != "":
		var albedo := _tex(folder, "albedo")
		if albedo:
			mat.albedo_texture = albedo
		var normal := _tex(folder, "normal")
		if normal:
			mat.normal_enabled = true
			mat.normal_texture = normal
			mat.normal_scale = 1.0
		var rough := _tex(folder, "roughness")
		if rough:
			mat.roughness_texture = rough
			mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			mat.roughness = 1.0
		var metal := _tex(folder, "metallic")
		if metal:
			mat.metallic_texture = metal
			mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			mat.metallic = 1.0
	if extra.get("alpha_scissor", false):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if extra.get("transparent", false):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if extra.has("emission"):
		mat.emission_enabled = true
		mat.emission = extra["emission"]
		mat.emission_energy_multiplier = extra.get("energy", 2.0)
	return mat


func _tex(folder: String, map: String) -> Texture2D:
	var path := TEX + folder + "/" + map + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null
