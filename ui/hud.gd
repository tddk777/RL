class_name HUD
extends Control
## In-game overlay: health, weapon and ammo, interaction prompt, optional
## crosshair dot, and a red vignette when hurt. Binds to the player on spawn.

@onready var _health_bar: ProgressBar = $Health/Bar
@onready var _weapon_label: Label = $Weapon/Name
@onready var _ammo_label: Label = $Weapon/Ammo
@onready var _prompt: Label = $Prompt
@onready var _crosshair: Control = $Crosshair
@onready var _vignette: ColorRect = $Vignette

var _player: Player
var _hurt: float = 0.0


func _ready() -> void:
	Events.player_spawned.connect(_bind)
	Events.settings_changed.connect(_apply_settings)
	_prompt.text = ""
	_apply_settings()


func _bind(player: Node) -> void:
	_player = player as Player
	_player.health.health_changed.connect(_on_health)
	_player.health.damaged.connect(func(_hit: HitInfo) -> void: _hurt = 1.0)
	_player.interaction_prompt.connect(_on_prompt)
	_on_health(_player.health.current, _player.health.max_health)
	_hurt = 0.0
	_prompt.text = ""


func _process(delta: float) -> void:
	_hurt = move_toward(_hurt, 0.0, delta * 0.8)
	var low := 0.0
	if is_instance_valid(_player):
		low = clampf(1.0 - _player.health.ratio() / 0.35, 0.0, 1.0) * 0.55
	(_vignette.material as ShaderMaterial).set_shader_parameter(&"intensity", maxf(_hurt, low))
	if not is_instance_valid(_player) or _player.current_weapon == null:
		_weapon_label.text = ""
		_ammo_label.text = ""
		return
	var weapon := _player.current_weapon
	var mode: String = ["SEMI", "BURST", "AUTO", "BOLT"][weapon.current_mode()]
	_weapon_label.text = "%s   %s" % [weapon.data.display_name.to_upper(), mode]
	if weapon.is_busy() and weapon.busy_kind() != &"cycle":
		_ammo_label.text = "reloading"
	else:
		_ammo_label.text = "%d  /  %d" % [weapon.loaded_rounds(), weapon.reserve_rounds()]


func _on_health(current: float, maximum: float) -> void:
	_health_bar.max_value = maximum
	_health_bar.value = current


func _on_prompt(text: String) -> void:
	var key := _binding_name(&"interact")
	_prompt.text = "[%s]  %s" % [key, text] if text != "" else ""


func _apply_settings() -> void:
	_crosshair.visible = Settings.get_value("interface", "crosshair")
	_ammo_label.visible = Settings.get_value("interface", "ammo_counter")


static func _binding_name(action: StringName) -> String:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return OS.get_keycode_string((event as InputEventKey).physical_keycode)
	return "?"
