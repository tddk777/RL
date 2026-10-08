class_name Acoustics
extends Node
## How the space round the listener sounds, measured live and fed to the
## buses (Audio owns one of these):
##
##   - Rays from the listener's head (all round, up the diagonals, straight
##     up) say how big the space is, how enclosed, whether there's sky.
##   - World reverb: small rooms short and fairly dry, halls long and wet,
##     outdoors almost dry.
##   - Weapons bus: a bigger, wetter reverb for the gunshot tails, and two
##     echo taps timed from the nearest big surfaces beyond 12 m (the
##     slap-back of a shot off a facade, the far wall of a hall).
##
## Per sound (`Audio.play_3d`): `occlusion()` muffles and quietens what comes
## through walls, and `arrival_delay()` holds far sounds back by the time
## they take to get here (343 m/s).

const SPEED_OF_SOUND := 343.0
const RANGE := 70.0
const INTERVAL := 0.2

## The ears: set by Ballistics.listener / the camera.
var listener: Node3D
## 0..1 how big / how enclosed / sky overhead (for anything else that wants it).
var size: float = 0.5
var enclosure: float = 0.5
var outdoors: bool = false

var _timer: float = 0.0
var _world_reverb: AudioEffectReverb
var _weapon_reverb: AudioEffectReverb
var _echo: AudioEffectDelay
var _target := {}
var _dirs: Array[Vector3] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_world_reverb = _effect(&"World", "AudioEffectReverb") as AudioEffectReverb
	_weapon_reverb = _effect(&"Weapons", "AudioEffectReverb") as AudioEffectReverb
	_echo = _effect(&"Weapons", "AudioEffectDelay") as AudioEffectDelay
	for i in 10:
		var a := TAU * i / 10.0
		_dirs.append(Vector3(cos(a), 0.0, sin(a)))
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0
		_dirs.append(Vector3(cos(a) * 0.7, 0.7, sin(a) * 0.7).normalized())
	_dirs.append(Vector3.UP)


static func _effect(bus_name: StringName, cls: String) -> AudioEffect:
	var bus := AudioServer.get_bus_index(bus_name)
	if bus < 0:
		return null
	for i in AudioServer.get_bus_effect_count(bus):
		var e := AudioServer.get_bus_effect(bus, i)
		if e.is_class(cls):
			return e
	return null


func _process(delta: float) -> void:
	var ears := _ears()
	if ears == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = INTERVAL
		_measure(ears)
	_apply(delta)


func _ears() -> Node3D:
	if is_instance_valid(listener):
		return listener
	var cam := get_viewport().get_camera_3d()
	return cam


func _measure(ears: Node3D) -> void:
	var space := ears.get_world_3d().direct_space_state
	var from := ears.global_position
	var dists: Array[float] = []
	var misses := 0
	var sky := true
	var echoes: Array[float] = []
	for i in _dirs.size():
		var dir := _dirs[i]
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * RANGE, Layers.WORLD)
		var hit := space.intersect_ray(q)
		var d := RANGE
		if hit:
			d = from.distance_to(hit.position)
		else:
			misses += 1
		if dir == Vector3.UP:
			sky = hit.is_empty() or d > 30.0
		else:
			dists.append(d)
			if i < 10 and hit and d > 12.0:
				echoes.append(d)
	var mean := 0.0
	for d in dists:
		mean += d
	mean /= maxf(dists.size(), 1.0)
	size = clampf(mean / 35.0, 0.05, 1.0)
	enclosure = 1.0 - float(misses) / _dirs.size()
	outdoors = sky and enclosure < 0.75
	echoes.sort()
	var room := lerpf(0.25, 0.95, size)
	if outdoors:
		_target = {
			"w_room": 0.35, "w_wet": 0.04, "w_damp": 0.6,
			"g_room": 0.55, "g_wet": 0.07, "g_damp": 0.55,
		}
	else:
		_target = {
			"w_room": room, "w_wet": lerpf(0.08, 0.26, size) * lerpf(0.6, 1.0, enclosure), "w_damp": lerpf(0.5, 0.25, size),
			"g_room": minf(room + 0.1, 1.0), "g_wet": lerpf(0.16, 0.45, size) * lerpf(0.6, 1.0, enclosure), "g_damp": lerpf(0.45, 0.2, size),
		}
	# Echo taps off the nearest big surfaces: there and back.
	var t1 := echoes[0] if echoes.size() > 0 else -1.0
	var t2 := echoes[mini(2, echoes.size() - 1)] if echoes.size() > 1 else -1.0
	var echo_gain := 1.0 if outdoors else (0.6 if size > 0.4 else 0.0)
	_target["e1_ms"] = clampf(t1 * 2.0 / SPEED_OF_SOUND * 1000.0, 60.0, 1400.0) if t1 > 0.0 else 300.0
	_target["e2_ms"] = clampf(t2 * 2.0 / SPEED_OF_SOUND * 1000.0, 90.0, 1500.0) if t2 > 0.0 else 600.0
	_target["e1_db"] = (-12.0 - t1 * 0.12) if t1 > 0.0 and echo_gain > 0.0 else -60.0
	_target["e2_db"] = (-17.0 - t2 * 0.12) if t2 > 0.0 and echo_gain > 0.0 else -60.0
	if echo_gain < 1.0 and echo_gain > 0.0:
		_target["e1_db"] -= 4.0
		_target["e2_db"] -= 4.0


func _apply(delta: float) -> void:
	if _target.is_empty():
		return
	var k := clampf(delta * 2.5, 0.0, 1.0)
	if _world_reverb:
		_world_reverb.room_size = lerpf(_world_reverb.room_size, _target["w_room"], k)
		_world_reverb.wet = lerpf(_world_reverb.wet, _target["w_wet"], k)
		_world_reverb.damping = lerpf(_world_reverb.damping, _target["w_damp"], k)
	if _weapon_reverb:
		_weapon_reverb.room_size = lerpf(_weapon_reverb.room_size, _target["g_room"], k)
		_weapon_reverb.wet = lerpf(_weapon_reverb.wet, _target["g_wet"], k)
		_weapon_reverb.damping = lerpf(_weapon_reverb.damping, _target["g_damp"], k)
	if _echo:
		# Delay times jump (sliding them would pitch-bend the tail); levels glide.
		_echo.tap1_delay_ms = _target["e1_ms"]
		_echo.tap2_delay_ms = _target["e2_ms"]
		_echo.tap1_level_db = lerpf(_echo.tap1_level_db, _target["e1_db"], k)
		_echo.tap2_level_db = lerpf(_echo.tap2_level_db, _target["e2_db"], k)


## How much of a sound at `source` gets through to the listener: walls in
## between each take ~7 dB and push the cutoff down. Returns [volume_db,
## cutoff_hz] (0 dB and 20 kHz when clear).
func occlusion(source: Vector3) -> Vector2:
	var ears := _ears()
	if ears == null:
		return Vector2(0.0, 20500.0)
	var space := ears.get_world_3d().direct_space_state
	var from := ears.global_position
	# Your own gun and kit: never "behind a wall" even when it's pushed into one.
	if from.distance_to(source) < 1.5:
		return Vector2(0.0, 20500.0)
	var walls := 0
	var p := from
	for i in 3:
		var q := PhysicsRayQueryParameters3D.create(p, source, Layers.WORLD)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		walls += 1
		# Step through: the next wall along, if any.
		p = (hit.position as Vector3) + (source - from).normalized() * 0.6
		if p.distance_to(from) >= source.distance_to(from):
			break
	if walls == 0:
		return Vector2(0.0, 20500.0)
	return Vector2(-7.0 * walls, [2200.0, 900.0, 450.0][mini(walls, 3) - 1])


## Seconds a sound from `source` takes to reach the listener.
func arrival_delay(source: Vector3) -> float:
	var ears := _ears()
	return ears.global_position.distance_to(source) / SPEED_OF_SOUND if ears else 0.0
