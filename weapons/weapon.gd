class_name Weapon
extends Node3D
## Runtime state of one firearm: chamber and magazine, fire modes, cycling,
## reloading, attachments, and firing through Ballistics. The holder (Player or
## NPC) sets the trigger, aiming flag and aim source; the weapon does the rest.
##
## Ammo model: a round must be chambered to fire. After a shot, semi/auto
## weapons chamber the next round from the magazine; bolt actions need a manual
## cycle, which happens automatically shortly after the shot.

signal fired(weapon: Weapon)
signal ammo_changed(weapon: Weapon)
signal action_started(kind: StringName, duration: float)
signal action_finished(kind: StringName)
signal fire_mode_changed(mode: WeaponData.FireMode)

const DISTANT_SOUND_RANGE := 40.0

var data: WeaponData
var model: WeaponModel
var ammo: AmmoData
var attachments: Array[AttachmentData] = []
## The actor holding the weapon; credited with damage.
var user: Node
## Bullets leave from this node's origin along its -Z axis.
var aim_source: Node3D
## Object with take_ammo(caliber: StringName, count: int) -> int and
## count_ammo(caliber: StringName) -> int. Null means unlimited reserve.
var ammo_provider: Object
## Colliders bullets ignore (the holder's own body and hitboxes).
var exclude: Array[RID] = []
## Extra cone half-angle in degrees from the holder (movement, AI aim error).
var spread_bonus: float = 0.0
var aiming: bool = false

var mag_ammo: int = 0
var chambered: bool = false
var mode_index: int = 0

var _trigger: bool = false
var _trigger_handled: bool = false
var _cooldown: float = 0.0
var _burst_left: int = 0
var _action: ActionTimeline
var _action_kind: StringName = &""
var _flash: MuzzleFlash
var _mods := {
	"recoil": 1.0, "spread": 1.0, "ads_time": 1.0, "loudness": 1.0, "flash": 1.0,
	"ads_fov": 0.0, "overlay": null, "shot_sounds": [],
}


static func create(weapon_data: WeaponData, holder: Node) -> Weapon:
	var weapon := Weapon.new()
	weapon.data = weapon_data
	weapon.user = holder
	weapon.ammo = weapon_data.default_ammo
	weapon.name = String(weapon_data.id).to_pascal_case()
	return weapon


func _ready() -> void:
	model = data.model_scene.instantiate() as WeaponModel
	add_child(model)
	for attachment in data.default_attachments:
		attach(attachment)
	if model.muzzle:
		_flash = MuzzleFlash.new()
		model.muzzle.add_child(_flash)
	mag_ammo = data.magazine_size
	chambered = true


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _action and _action.tick(delta):
		var kind := _action_kind
		_action = null
		_action_kind = &""
		action_finished.emit(kind)
	_update_trigger()


# --- Holder API -----------------------------------------------------------------

func set_trigger(pressed: bool) -> void:
	if pressed and not _trigger:
		_trigger_handled = false
	_trigger = pressed


func current_mode() -> WeaponData.FireMode:
	return data.fire_modes[mode_index] if not data.fire_modes.is_empty() else WeaponData.FireMode.SEMI


func cycle_fire_mode() -> void:
	if data.fire_modes.size() < 2 or is_busy():
		return
	mode_index = (mode_index + 1) % data.fire_modes.size()
	_play_local(data.fire_select_sound, -6.0)
	fire_mode_changed.emit(current_mode())


func is_busy() -> bool:
	return _action != null


func busy_kind() -> StringName:
	return _action_kind


func can_reload() -> bool:
	if is_busy():
		return false
	if mag_ammo >= data.magazine_size:
		return false
	return _reserve() > 0


func reload() -> void:
	if not can_reload():
		return
	_trigger_handled = true
	if data.feed == WeaponData.Feed.INTERNAL:
		_start_insert()
	else:
		_start_magazine_reload()


## Rounds in the gun (magazine + chamber).
func loaded_rounds() -> int:
	return mag_ammo + (1 if chambered else 0)


func reserve_rounds() -> int:
	return _reserve()


func ads_fov() -> float:
	return _mods["ads_fov"] if _mods["ads_fov"] > 0.0 else data.ads_fov


func ads_time() -> float:
	return data.ads_time * _mods["ads_time"]


func ads_overlay() -> Texture2D:
	return _mods["overlay"]


func recoil_multiplier() -> float:
	return _mods["recoil"]


func cancel_action() -> void:
	if _action:
		var kind := _action_kind
		_action = null
		_action_kind = &""
		model.reset_pose()
		action_finished.emit(kind)


## Mounts an attachment if the weapon accepts it. Returns success.
func attach(attachment: AttachmentData) -> bool:
	if not data.accepts(attachment) or attachment.model_scene == null:
		return false
	var mount := model.mount(attachment.slot)
	if mount == null:
		return false
	var inst := attachment.model_scene.instantiate() as Node3D
	inst.name = String(attachment.id).to_pascal_case()
	mount.add_child(inst)
	var ads := inst.get_node_or_null(^"ADS") as Node3D
	if ads:
		model.set_ads_override(ads)
	attachments.append(attachment)
	_recompute_mods()
	return true


# --- Firing ---------------------------------------------------------------------

func _update_trigger() -> void:
	var mode := current_mode()
	if _burst_left > 0:
		if _cooldown <= 0.0:
			if not _fire_once():
				_burst_left = 0
			else:
				_burst_left -= 1
		return
	if not _trigger:
		return
	# Firing interrupts single-round loading so the player can shoot.
	if _action_kind == &"insert" and not _trigger_handled:
		cancel_action()
	if is_busy() or _cooldown > 0.0:
		return
	match mode:
		WeaponData.FireMode.AUTO:
			if not chambered:
				if not _trigger_handled:
					_dry_fire()
				return
			_fire_once()
		WeaponData.FireMode.BURST:
			if not _trigger_handled:
				_trigger_handled = true
				_burst_left = data.burst_count - 1
				if not _fire_once():
					_burst_left = 0
		_:
			if not _trigger_handled:
				_trigger_handled = true
				_fire_once()


func _fire_once() -> bool:
	if not chambered:
		_dry_fire()
		return false
	chambered = false
	_cooldown = data.time_between_shots()
	var spread: float = (data.spread_ads if aiming else data.spread_hip) * _mods["spread"] + spread_bonus
	var source := aim_source if aim_source else (model.muzzle if model.muzzle else self)
	var direction := cone(-source.global_basis.z, spread)
	Ballistics.fire(source.global_position, direction, data.muzzle_velocity * ammo.velocity_multiplier,
		ammo.damage * data.damage_multiplier, ammo, user, exclude)
	if _flash:
		_flash.flash(data.muzzle_flash_scale * _mods["flash"])
	_play_shot()
	Events.noise_emitted.emit(global_position, data.loudness * _mods["loudness"], user)
	if current_mode() == WeaponData.FireMode.BOLT:
		_start_cycle(0.18)
	else:
		model.cycle_bolt(minf(data.time_between_shots() * 0.9, 0.08))
		_eject_casing()
		_chamber_from_magazine()
	fired.emit(self)
	ammo_changed.emit(self)
	return true


func _dry_fire() -> void:
	_trigger_handled = true
	_play_local(data.dry_fire_sound, -4.0)


func _chamber_from_magazine() -> void:
	if not chambered and mag_ammo > 0:
		mag_ammo -= 1
		chambered = true


func _eject_casing() -> void:
	if model.eject == null:
		return
	var basis := model.eject.global_basis
	var velocity := basis.x * randf_range(2.2, 3.2) + basis.y * randf_range(1.0, 2.0) - basis.z * randf_range(-0.3, 0.6)
	if user is Node3D and (user as Node3D).has_method(&"get_real_velocity"):
		velocity += (user as CharacterBody3D).get_real_velocity()
	Effects.eject_casing(model.eject, velocity, data.casing_scale)


# --- Actions --------------------------------------------------------------------

func _start_action(kind: StringName, timeline: ActionTimeline) -> void:
	_action = timeline
	_action_kind = kind
	_burst_left = 0
	action_started.emit(kind, timeline.duration)


## Bolt-action cycle (also used after an empty reload on any weapon).
func _start_cycle(delay: float) -> void:
	var t := ActionTimeline.new()
	var cycle := data.cycle_time
	t.at(delay, func() -> void:
		model.manual_cycle(cycle)
		_play_local(data.charge_sound, -3.0))
	t.at(delay + cycle * 0.45, _eject_casing)
	t.at(delay + cycle * 0.75, func() -> void:
		_chamber_from_magazine()
		ammo_changed.emit(self))
	t.at(delay + cycle, func() -> void: pass)
	_start_action(&"cycle", t)


func _start_magazine_reload() -> void:
	var empty := not chambered
	var duration := data.reload_empty_time if empty else data.reload_time
	var t := ActionTimeline.new()
	t.at(duration * 0.12, func() -> void:
		model.magazine_out(duration * 0.18)
		_play_local(data.mag_out_sound, -2.0))
	t.at(duration * 0.55, func() -> void:
		model.magazine_in(duration * 0.12)
		_play_local(data.mag_in_sound, -2.0)
		var wanted := data.magazine_size - mag_ammo
		mag_ammo += _take(wanted)
		ammo_changed.emit(self))
	if empty:
		t.at(duration * 0.78, func() -> void:
			model.manual_cycle(duration * 0.18)
			_play_local(data.charge_sound, -2.0))
		t.at(duration * 0.9, func() -> void:
			_chamber_from_magazine()
			ammo_changed.emit(self))
	t.at(duration, func() -> void: pass)
	_start_action(&"reload", t)


## Internal magazines load one round at a time until full or interrupted.
func _start_insert() -> void:
	var t := ActionTimeline.new()
	var step := data.insert_time
	var time := 0.25
	var rounds := mini(data.magazine_size - mag_ammo, _reserve())
	for i in rounds:
		time += step
		t.at(time, func() -> void:
			if _take(1) == 1:
				mag_ammo += 1
				_play_local(data.mag_in_sound, -3.0)
				ammo_changed.emit(self))
	if not chambered:
		t.at(time + 0.1, func() -> void:
			model.manual_cycle(data.cycle_time)
			_play_local(data.charge_sound, -3.0))
		t.at(time + 0.1 + data.cycle_time * 0.75, func() -> void:
			_chamber_from_magazine()
			ammo_changed.emit(self))
		time += 0.1 + data.cycle_time
	t.at(time + 0.15, func() -> void: pass)
	_start_action(&"insert", t)


func _reserve() -> int:
	if ammo_provider == null:
		return 9999
	return ammo_provider.call(&"count_ammo", data.caliber)


func _take(count: int) -> int:
	if ammo_provider == null:
		return count
	return ammo_provider.call(&"take_ammo", data.caliber, count)


# --- Sound ----------------------------------------------------------------------

func _play_shot() -> void:
	var sounds: Array = _mods["shot_sounds"] if not (_mods["shot_sounds"] as Array).is_empty() else data.shot_sounds
	var position := model.muzzle.global_position if model.muzzle else global_position
	var listener := get_viewport().get_camera_3d()
	var distance := listener.global_position.distance_to(position) if listener else 0.0
	if distance > DISTANT_SOUND_RANGE and data.distant_shot_sound:
		Audio.play_3d(data.distant_shot_sound, position, &"Weapons", 0.0, 60.0, 0.06)
	else:
		Audio.play_3d(Audio.pick(sounds), position, &"Weapons", 0.0, 30.0, 0.04)


func _play_local(stream: AudioStream, volume_db: float) -> void:
	Audio.play_3d(stream, global_position, &"Weapons", volume_db, 4.0, 0.04)


func _recompute_mods() -> void:
	_mods = {"recoil": 1.0, "spread": 1.0, "ads_time": 1.0, "loudness": 1.0, "flash": 1.0,
		"ads_fov": 0.0, "overlay": null, "shot_sounds": []}
	for a in attachments:
		_mods["recoil"] *= a.recoil_multiplier
		_mods["spread"] *= a.spread_multiplier
		_mods["ads_time"] *= a.ads_time_multiplier
		_mods["loudness"] *= a.loudness_multiplier
		_mods["flash"] *= a.flash_multiplier
		if a.ads_fov > 0.0:
			_mods["ads_fov"] = a.ads_fov
		if a.ads_overlay:
			_mods["overlay"] = a.ads_overlay
		if not a.shot_sounds.is_empty():
			_mods["shot_sounds"] = a.shot_sounds


## Random direction inside a cone of `degrees` half-angle around `dir`.
static func cone(dir: Vector3, degrees: float) -> Vector3:
	if degrees <= 0.0:
		return dir.normalized()
	var angle := deg_to_rad(degrees) * sqrt(randf())
	var phi := randf() * TAU
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT).normalized()
	var up := side.cross(dir).normalized()
	return (dir * cos(angle) + (side * cos(phi) + up * sin(phi)) * sin(angle)).normalized()
