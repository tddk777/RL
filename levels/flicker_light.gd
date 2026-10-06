class_name FlickerLight
extends Node
## Makes its parent Light3D flicker like a failing tube or a bad connection.
## Optional emissive mesh dims along with it; optional buzz plays near it.

@export var light: Light3D
@export var emissive_mesh: GeometryInstance3D
@export_range(0.0, 1.0) var flicker_amount: float = 0.6
## Average seconds between flicker bursts.
@export var burst_interval: float = 4.0
## Slow sine pulse instead of random flicker (emergency beacons).
@export var pulse: bool = false
@export var pulse_speed: float = 1.4

var _base_energy: float
var _timer: float = 0.0
var _burst: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	if light == null:
		light = get_parent() as Light3D
	_base_energy = light.light_energy if light else 1.0
	_timer = randf() * burst_interval


func _process(delta: float) -> void:
	if light == null:
		return
	_time += delta
	var level := 1.0
	if pulse:
		level = 0.35 + 0.65 * (0.5 + 0.5 * sin(_time * pulse_speed * TAU))
	else:
		_timer -= delta
		if _timer <= 0.0:
			_burst = randf_range(0.15, 0.9)
			_timer = randf_range(burst_interval * 0.4, burst_interval * 1.6)
		if _burst > 0.0:
			_burst -= delta
			level = 1.0 - flicker_amount * (1.0 if randf() < 0.45 else randf() * 0.5)
	light.light_energy = _base_energy * level
	if emissive_mesh and emissive_mesh.material_override is StandardMaterial3D:
		(emissive_mesh.material_override as StandardMaterial3D).emission_energy_multiplier = 3.5 * level
