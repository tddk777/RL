class_name Player
extends CharacterBody3D
## First-person player: movement, look, footsteps, interaction, health and the
## weapons it carries. Weapon presentation (sway, ADS, recoil kick, arms) is
## handled by the WeaponHolder under the camera.

signal weapon_changed(weapon: Weapon)
signal interaction_prompt(text: String)

@export_group("Movement")
@export var walk_speed: float = 3.2
@export var sprint_speed: float = 5.6
@export var crouch_speed: float = 1.5
@export var aim_speed_multiplier: float = 0.6
@export var ground_accel: float = 11.0
@export var air_accel: float = 2.0
@export var jump_velocity: float = 4.2
@export var stand_height: float = 1.8
@export var crouch_height: float = 1.15
@export var eye_below_top: float = 0.12

@export_group("Loadout")
## Placeholder until an inventory exists: weapon ids for slots 1-4.
@export var starting_weapon_ids: PackedStringArray = []
## Placeholder reserve ammo per caliber.
@export var starting_ammo: Dictionary = {}

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var holder: WeaponHolder = $Head/Camera3D/WeaponHolder
@onready var health: HealthComponent = $HealthComponent
@onready var hitbox: Hitbox = $Hitbox
@onready var collision: CollisionShape3D = $CollisionShape3D

var weapons: Array[Weapon] = []
var current_weapon: Weapon
var ammo_reserve: Dictionary = {}
var is_crouching: bool = false
var is_sprinting: bool = false
var is_aiming: bool = false
var alive: bool = true

var _pitch: float = 0.0
var _recoil_pool: float = 0.0
var _look_delta := Vector2.ZERO
var _step_distance: float = 0.0
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _shake: float = 0.0
var _interact_target: Interactable
var _heartbeat: AudioStreamPlayer
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

const HEARTBEAT := "res://assets/audio/player/heartbeat_loop.wav"
const HURT_SOUNDS := ["res://assets/audio/player/hurt_impact_1.wav", "res://assets/audio/player/hurt_impact_2.wav"]


func _ready() -> void:
	collision_layer = Layers.PLAYER
	collision_mask = Layers.WORLD | Layers.NPC | Layers.CLIP
	ammo_reserve = starting_ammo.duplicate()
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	Ballistics.listener = head
	Ballistics.listener_owner = self
	Events.settings_changed.connect(_apply_settings)
	_apply_settings()
	for id in starting_weapon_ids:
		var data := Registry.weapon(StringName(id))
		if data:
			add_weapon(data)
	if not weapons.is_empty():
		equip(0)
	if ResourceLoader.exists(HEARTBEAT):
		_heartbeat = AudioStreamPlayer.new()
		_heartbeat.stream = load(HEARTBEAT)
		_heartbeat.bus = &"SFX"
		_heartbeat.volume_db = -80.0
		add_child(_heartbeat)


func _unhandled_input(event: InputEvent) -> void:
	if not alive or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var sens: float = Settings.get_value("controls", "mouse_sensitivity") * 0.01
		if is_aiming:
			sens *= Settings.get_value("controls", "ads_sensitivity") * (camera.fov / _base_fov())
		var invert := -1.0 if Settings.get_value("controls", "invert_y") else 1.0
		rotate_y(-motion.relative.x * sens)
		_pitch = clampf(_pitch - motion.relative.y * sens * invert, deg_to_rad(-88.0), deg_to_rad(88.0))
		_look_delta += motion.relative
	for i in 4:
		if event.is_action_pressed(StringName("weapon_%d" % (i + 1))):
			equip(i)
	if current_weapon:
		if event.is_action_pressed(&"reload"):
			current_weapon.reload()
		elif event.is_action_pressed(&"fire_mode"):
			current_weapon.cycle_fire_mode()
	if event.is_action_pressed(&"interact") and _interact_target:
		_interact_target.interact(self)


func _physics_process(delta: float) -> void:
	if not alive:
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		velocity.y -= _gravity * delta
		move_and_slide()
		return
	_update_stance(delta)
	_move(delta)
	_update_look(delta)
	_update_weapon_input()
	_update_footsteps(delta)
	_update_interaction()


func _process(delta: float) -> void:
	holder.look_delta = _look_delta
	_look_delta = Vector2.ZERO
	_update_heartbeat(delta)


# --- Weapons --------------------------------------------------------------------

func add_weapon(data: WeaponData) -> Weapon:
	var weapon := Weapon.create(data, self)
	weapon.ammo_provider = self
	weapon.aim_source = camera
	weapon.exclude = [get_rid(), hitbox.get_rid()]
	weapon.fired.connect(_on_weapon_fired)
	holder.add_weapon(weapon)
	weapons.append(weapon)
	return weapon


func equip(index: int) -> void:
	if index < 0 or index >= weapons.size() or weapons[index] == current_weapon:
		return
	if current_weapon:
		current_weapon.set_trigger(false)
		current_weapon.cancel_action()
	current_weapon = weapons[index]
	holder.equip(current_weapon)
	weapon_changed.emit(current_weapon)


## Ammo provider API used by Weapon.
func count_ammo(caliber: StringName) -> int:
	return ammo_reserve.get(String(caliber), 0)


func take_ammo(caliber: StringName, count: int) -> int:
	var have: int = ammo_reserve.get(String(caliber), 0)
	var taken := mini(have, count)
	ammo_reserve[String(caliber)] = have - taken
	return taken


func _update_weapon_input() -> void:
	is_aiming = Input.is_action_pressed(&"aim") and not is_sprinting and current_weapon != null
	if current_weapon == null:
		return
	var blocked := holder.is_blocked() or is_sprinting or holder.is_switching()
	current_weapon.set_trigger(Input.is_action_pressed(&"fire") and not blocked)
	current_weapon.aiming = is_aiming and holder.ads_blend > 0.8
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	current_weapon.spread_bonus = current_weapon.data.spread_moving * clampf(horizontal_speed / sprint_speed, 0.0, 1.0) \
		+ (1.5 if not is_on_floor() else 0.0)


func _on_weapon_fired(weapon: Weapon) -> void:
	var mult := weapon.recoil_multiplier() * (0.75 if is_crouching else 1.0) * (0.85 if is_aiming else 1.0)
	var kick := deg_to_rad(weapon.data.recoil_vertical * mult * randf_range(0.85, 1.15))
	_pitch = clampf(_pitch + kick, deg_to_rad(-88.0), deg_to_rad(88.0))
	_recoil_pool += kick * weapon.data.recoil_recovery
	rotate_y(deg_to_rad(randf_range(-1.0, 1.0) * weapon.data.recoil_horizontal * mult))
	holder.kick(weapon.data.kick_back * mult, weapon.data.kick_rotation * mult)
	_shake = maxf(_shake, 0.12 * mult)


# --- Movement -------------------------------------------------------------------

func _move(delta: float) -> void:
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	is_sprinting = Input.is_action_pressed(&"sprint") and input.y < -0.1 and not is_crouching and is_on_floor() \
		and not Input.is_action_pressed(&"aim")
	var speed := crouch_speed if is_crouching else (sprint_speed if is_sprinting else walk_speed)
	if is_aiming:
		speed *= aim_speed_multiplier
	var accel := ground_accel if is_on_floor() else air_accel
	velocity.x = lerpf(velocity.x, direction.x * speed, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, direction.z * speed, clampf(accel * delta, 0.0, 1.0))
	if not is_on_floor():
		velocity.y -= _gravity * delta
		_fall_speed = maxf(_fall_speed, -velocity.y)
	elif Input.is_action_just_pressed(&"jump") and not is_crouching:
		velocity.y = jump_velocity
	move_and_slide()
	if is_on_floor() and not _was_on_floor and _fall_speed > 3.0:
		_land()
	if is_on_floor():
		_fall_speed = 0.0
	_was_on_floor = is_on_floor()


func _update_stance(delta: float) -> void:
	var want_crouch := Input.is_action_pressed(&"crouch")
	if not want_crouch and is_crouching and _ceiling_blocked():
		want_crouch = true
	is_crouching = want_crouch
	var capsule := collision.shape as CapsuleShape3D
	var target := crouch_height if is_crouching else stand_height
	capsule.height = move_toward(capsule.height, target, 4.0 * delta)
	collision.position.y = capsule.height * 0.5
	hitbox.position.y = capsule.height * 0.5
	(hitbox.get_child(0) as CollisionShape3D).shape.set(&"height", capsule.height)
	head.position.y = lerpf(head.position.y, capsule.height - eye_below_top, clampf(14.0 * delta, 0.0, 1.0))


func _ceiling_blocked() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var probe := SphereShape3D.new()
	probe.radius = 0.3
	query.shape = probe
	query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3.UP * (stand_height - 0.3))
	query.collision_mask = Layers.WORLD
	return not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _update_look(delta: float) -> void:
	# Recoil recovery: return part of the kick when not firing.
	if _recoil_pool > 0.0 and (current_weapon == null or not Input.is_action_pressed(&"fire")):
		var recover := minf(_recoil_pool, _recoil_pool * 6.0 * delta + 0.0005)
		_pitch -= recover
		_recoil_pool -= recover
	_shake = move_toward(_shake, 0.0, delta * 1.5)
	var shake_offset := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0.0) * _shake * 0.02
	head.rotation = Vector3(_pitch, 0.0, 0.0) + shake_offset
	var target_fov := _base_fov()
	if current_weapon and is_aiming:
		target_fov = lerpf(_base_fov(), current_weapon.ads_fov(), holder.ads_blend)
	elif is_sprinting:
		target_fov = _base_fov() + 4.0
	camera.fov = lerpf(camera.fov, target_fov, clampf(18.0 * delta, 0.0, 1.0))


func _base_fov() -> float:
	return Settings.get_value("graphics", "fov")


# --- Footsteps & interaction ------------------------------------------------------

func _update_footsteps(delta: float) -> void:
	if not is_on_floor():
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.4:
		_step_distance = 0.0
		return
	_step_distance += speed * delta
	var stride := 0.95 if is_sprinting else (0.55 if is_crouching else 0.75)
	if _step_distance >= stride:
		_step_distance = 0.0
		var surface := _floor_surface()
		if surface:
			var volume := -4.0 if is_sprinting else (-16.0 if is_crouching else -9.0)
			Audio.play_3d(Audio.pick(surface.footstep_sounds), global_position, &"World", volume, 3.0, 0.08)
		Events.noise_emitted.emit(global_position, 16.0 if is_sprinting else (2.5 if is_crouching else 7.0), self)


func _land() -> void:
	var surface := _floor_surface()
	if surface:
		Audio.play_3d(surface.land_sound, global_position, &"World", -4.0, 3.0, 0.05)
	Events.noise_emitted.emit(global_position, 10.0, self)
	holder.kick(0.02, -4.0)


func _floor_surface() -> SurfaceData:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.2, global_position + Vector3.DOWN * 0.4, Layers.WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return Registry.surface(Surface.of(hit.collider) if hit else Surface.DEFAULT)


func _update_interaction() -> void:
	var from := camera.global_position
	var to := from - camera.global_basis.z * 2.2
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD | Layers.INTERACT, [get_rid()])
	query.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var target: Interactable = null
	if hit and hit.collider is Interactable and (hit.collider as Interactable).can_interact(self):
		target = hit.collider
	if target != _interact_target:
		_interact_target = target
		interaction_prompt.emit(target.get_prompt() if target else "")


# --- Health -----------------------------------------------------------------------

func _on_damaged(hit: HitInfo) -> void:
	_shake = maxf(_shake, 0.6)
	var paths: Array = HURT_SOUNDS.filter(func(p: String) -> bool: return ResourceLoader.exists(p))
	if not paths.is_empty():
		Audio.play_2d(load(paths.pick_random()), &"SFX", -2.0, 0.05)
	# Flinch the view away from the hit direction.
	_pitch += deg_to_rad(randf_range(1.0, 3.0))
	rotate_y(deg_to_rad(randf_range(-2.0, 2.0)))


func _on_died(_hit: HitInfo) -> void:
	alive = false
	if current_weapon:
		current_weapon.set_trigger(false)
	holder.drop_out_of_view()
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(head, "position:y", 0.25, 0.8)
	tween.parallel().tween_property(head, "rotation:z", deg_to_rad(70.0), 0.8)
	if _heartbeat:
		_heartbeat.stop()
	Events.player_died.emit(self)


func _update_heartbeat(delta: float) -> void:
	if _heartbeat == null or not alive:
		return
	var danger := clampf(1.0 - health.ratio() / 0.4, 0.0, 1.0)
	if danger > 0.0 and not _heartbeat.playing:
		_heartbeat.play()
	_heartbeat.volume_db = lerpf(_heartbeat.volume_db, linear_to_db(maxf(danger, 0.0001)) - 2.0, clampf(3.0 * delta, 0.0, 1.0))
	if danger <= 0.0 and _heartbeat.volume_db < -60.0:
		_heartbeat.stop()


func _apply_settings() -> void:
	if camera:
		camera.fov = _base_fov()
