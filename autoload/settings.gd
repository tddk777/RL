extends Node
## Player-facing settings: input bindings, graphics presets, audio volumes and
## gameplay options. Saved to user://settings.cfg.

const PATH := "user://settings.cfg"

enum Quality { LOW, MEDIUM, HIGH, ULTRA }

const DEFAULTS := {
	"graphics": {
		"quality": Quality.HIGH,
		"fullscreen": false,
		"vsync": true,
		"render_scale": 1.0,
		"fov": 75.0,
	},
	"controls": {
		"mouse_sensitivity": 0.12,
		"ads_sensitivity": 0.8,
		"invert_y": false,
	},
	"audio": {
		"Master": 0.9,
		"SFX": 1.0,
		"Ambience": 0.8,
		"Music": 0.6,
		"UI": 0.8,
	},
	"interface": {
		"crosshair": false,
		"ammo_counter": true,
	},
}

## action -> list of keys (Key) or mouse buttons (MouseButton as negative ints).
const DEFAULT_BINDINGS := {
	"move_forward": [KEY_W],
	"move_back": [KEY_S],
	"move_left": [KEY_A],
	"move_right": [KEY_D],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"crouch": [KEY_CTRL, KEY_C],
	"fire": [-MOUSE_BUTTON_LEFT],
	"aim": [-MOUSE_BUTTON_RIGHT],
	"reload": [KEY_R],
	"fire_mode": [KEY_B],
	"interact": [KEY_F],
	"flashlight": [KEY_T],
	"weapon_1": [KEY_1],
	"weapon_2": [KEY_2],
	"weapon_3": [KEY_3],
	"weapon_4": [KEY_4],
	"weapon_5": [KEY_5],
	"pause": [KEY_ESCAPE],
}

var _config := ConfigFile.new()


func _ready() -> void:
	_register_bindings()
	_config.load(PATH)  # missing file is fine; defaults fill in
	apply()


func get_value(section: String, key: String) -> Variant:
	return _config.get_value(section, key, DEFAULTS[section][key])


func set_value(section: String, key: String, value: Variant) -> void:
	_config.set_value(section, key, value)


func save() -> void:
	_config.save(PATH)


func apply() -> void:
	_apply_display()
	_apply_audio()
	Events.settings_changed.emit()


## Graphics options that live on a level's Environment. Levels call this when
## they load and again on settings_changed. Quality caps the effects; it never
## turns on one the level's Environment left off (an enclosed level may skip
## SDFGI because it replaces the flat ambient light).
func apply_environment(env: Environment) -> void:
	if not env.has_meta(&"authored"):
		env.set_meta(&"authored", {"ssao": env.ssao_enabled, "ssil": env.ssil_enabled,
			"sdfgi": env.sdfgi_enabled, "ssr": env.ssr_enabled})
	var authored: Dictionary = env.get_meta(&"authored")
	var q: int = get_value("graphics", "quality")
	env.ssao_enabled = authored["ssao"] and q >= Quality.MEDIUM
	env.ssil_enabled = authored["ssil"] and q >= Quality.HIGH
	env.sdfgi_enabled = authored["sdfgi"] and q >= Quality.HIGH
	env.volumetric_fog_enabled = true  # core to the look; cost scaled below
	env.glow_enabled = true
	env.ssr_enabled = authored["ssr"] and q >= Quality.ULTRA


func _apply_display() -> void:
	var q: int = get_value("graphics", "quality")
	var fullscreen: bool = get_value("graphics", "fullscreen")
	var mode := DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(mode)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if get_value("graphics", "vsync") else DisplayServer.VSYNC_DISABLED)

	var viewport := get_viewport()
	var scale: float = get_value("graphics", "render_scale")
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR if is_equal_approx(scale, 1.0) else Viewport.SCALING_3D_MODE_FSR2
	viewport.scaling_3d_scale = scale
	viewport.use_taa = q >= Quality.MEDIUM and is_equal_approx(scale, 1.0)
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q == Quality.LOW else Viewport.SCREEN_SPACE_AA_DISABLED

	var shadow_size: int = [2048, 4096, 4096, 8192][q]
	RenderingServer.directional_shadow_atlas_set_size(shadow_size, true)
	viewport.positional_shadow_atlas_size = shadow_size
	var soft: int = [RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH][q]
	RenderingServer.directional_soft_shadow_filter_set_quality(soft)
	RenderingServer.positional_soft_shadow_filter_set_quality(soft)
	RenderingServer.environment_set_ssao_quality([RenderingServer.ENV_SSAO_QUALITY_LOW, RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		RenderingServer.ENV_SSAO_QUALITY_HIGH, RenderingServer.ENV_SSAO_QUALITY_ULTRA][q], true, 0.5, 2, 50, 300)
	RenderingServer.environment_set_volumetric_fog_volume_size([64, 96, 128, 160][q], [64, 96, 128, 160][q])
	RenderingServer.environment_set_sdfgi_ray_count([RenderingServer.ENV_SDFGI_RAY_COUNT_16, RenderingServer.ENV_SDFGI_RAY_COUNT_32,
		RenderingServer.ENV_SDFGI_RAY_COUNT_64, RenderingServer.ENV_SDFGI_RAY_COUNT_96][q])


func _apply_audio() -> void:
	for bus_name: String in DEFAULTS["audio"]:
		var index := AudioServer.get_bus_index(bus_name)
		if index >= 0:
			var linear: float = get_value("audio", bus_name)
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, 0.0001)))


func _register_bindings() -> void:
	for action: String in DEFAULT_BINDINGS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for code: int in DEFAULT_BINDINGS[action]:
			var event: InputEvent
			if code < 0:
				var mouse := InputEventMouseButton.new()
				mouse.button_index = -code as MouseButton
				event = mouse
			else:
				var key := InputEventKey.new()
				key.physical_keycode = code as Key
				event = key
			InputMap.action_add_event(action, event)
