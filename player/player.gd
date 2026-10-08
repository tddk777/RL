class_name Player
extends CharacterBody3D
## First-person player: movement, look, footsteps, interaction, health and the
## weapons it carries. Weapon presentation (sway, ADS, recoil kick, arms) is
## handled by the WeaponHolder under the camera.

signal weapon_changed(weapon: Weapon)
signal interaction_prompt(text: String)

enum Stance { STAND, CROUCH, PRONE }

@export_group("Movement")
@export var walk_speed: float = 2.9
## A laden run, not a sprint: it builds up slowly and fades as stamina does.
@export var sprint_speed: float = 4.5
@export var crouch_speed: float = 1.4
@export var prone_speed: float = 0.5
@export var aim_speed_multiplier: float = 0.6
@export var lean_speed_multiplier: float = 0.7
@export var ground_accel: float = 9.0
## How quickly a run builds up (lower than ground_accel: you lean into it).
@export var sprint_accel: float = 2.6
@export var air_accel: float = 1.2
@export var jump_velocity: float = 3.6
@export var stand_height: float = 1.8
@export var crouch_height: float = 1.15
@export var prone_height: float = 0.6
@export var eye_below_top: float = 0.12
## Seconds to get down or up from prone (no shooting meanwhile).
@export var prone_time: float = 0.8

@export_group("Lean")
@export var lean_angle: float = 13.0
@export var lean_offset: float = 0.34

@export_group("Stamina")
## Seconds of running from full to empty.
@export var sprint_seconds: float = 9.0
## Recovery per second walking; more standing still, crouched or prone.
@export var stamina_regen: float = 0.09
@export var stamina_regen_still: float = 0.18
## Seconds after running before stamina starts coming back.
@export var stamina_regen_delay: float = 1.3
@export var jump_cost: float = 0.14
@export var vault_cost: float = 0.1
@export var mantle_cost: float = 0.2
## Once empty, no running until stamina is back to this.
@export var exhausted_until: float = 0.35
## Seconds the breath can be held while aiming (sprint key while aiming).
@export var hold_breath_seconds: float = 4.0

@export_group("Aim stability")
## Degrees the aim wanders while rested, and on top of that when winded.
@export var sway_rested: float = 0.35
@export var sway_winded: float = 3.2

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
var stance: Stance = Stance.STAND
## Kept for the AI and weapons: true while crouched (not prone).
var is_crouching: bool = false
var is_prone: bool = false
var flashlight: Flashlight
var is_sprinting: bool = false
var is_aiming: bool = false
var alive: bool = true
## 0..1. Running, jumping and climbing spend it; when low, the aim shakes.
var stamina: float = 1.0
var exhausted: bool = false
## -1 (left) .. 1 (right), eased.
var lean: float = 0.0
## Breath held while aiming (sprint key): the aim steadies until it runs out.
var holding_breath: bool = false
## 0..1: how lit the player is (lamps, daylight, their own flashlight). The AI
## spots a lit player far quicker than one in the dark.
var light_exposure: float = 0.5
## 0..1: near misses and impacts close by. The aim shakes, the edges darken.
var suppression: float = 0.0

var _pitch: float = 0.0
var _recoil_pool: float = 0.0
var _look_delta := Vector2.ZERO
var _step_distance: float = 0.0
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _shake: float = 0.0
var _interact_target: Interactable
var _prompt_text: String = ""
var _heartbeat: AudioStreamPlayer
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _since_run: float = 10.0
var _breath_left: float = 4.0
var _breath_debt: float = 0.0
var _sway_time: float = 0.0
var _sway := Vector2.ZERO
var _stance_busy: float = 0.0
var _lean_x: float = 0.0
var _vault_path: Array[Vector3] = []
var _vault_t: float = 0.0
var _vault_time: float = 0.0
var _aim: Node3D
var _breath: AudioStreamPlayer
var _last_shot: float = -100.0
var _light_timer: float = 0.0
var _lights: Array = []
var _lights_age: float = 100.0

const HEARTBEAT := "res://assets/audio/player/heartbeat_loop.wav"
const BREATH := "res://assets/audio/player/breath_heavy_loop.wav"
const HURT_SOUNDS := ["res://assets/audio/player/hurt_impact_1.wav", "res://assets/audio/player/hurt_impact_2.wav"]


func _ready() -> void:
	collision_layer = Layers.PLAYER
	collision_mask = Layers.WORLD | Layers.NPC | Layers.CLIP
	ammo_reserve = starting_ammo.duplicate()
	# Shots leave along the swaying aim, not the camera's centre line.
	_aim = Node3D.new()
	_aim.name = "Aim"
	camera.add_child(_aim)
	_breath_left = hold_breath_seconds
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	Ballistics.listener = head
	Audio.acoustics.listener = head
	Ballistics.listener_owner = self
	Events.settings_changed.connect(_apply_settings)
	_apply_settings()
	for id in starting_weapon_ids:
		var data := Registry.weapon(StringName(id))
		if data:
			add_weapon(data)
	if not weapons.is_empty():
		equip(0)
	flashlight = Flashlight.new()
	add_child(flashlight)
	flashlight.setup(camera)
	if ResourceLoader.exists(HEARTBEAT):
		_heartbeat = AudioStreamPlayer.new()
		_heartbeat.stream = load(HEARTBEAT)
		_heartbeat.bus = &"SFX"
		_heartbeat.volume_db = -80.0
		add_child(_heartbeat)
	if ResourceLoader.exists(BREATH):
		_breath = AudioStreamPlayer.new()
		_breath.stream = load(BREATH)
		_breath.bus = &"SFX"
		_breath.volume_db = -80.0
		add_child(_breath)


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
	for i in 5:
		if event.is_action_pressed(StringName("weapon_%d" % (i + 1))):
			equip(i)
	if current_weapon:
		if event.is_action_pressed(&"reload"):
			current_weapon.reload()
		elif event.is_action_pressed(&"fire_mode"):
			current_weapon.cycle_fire_mode()
	if event.is_action_pressed(&"flashlight"):
		flashlight.toggle()
	if event.is_action_pressed(&"interact") and is_instance_valid(_interact_target):
		var t := _interact_target
		_interact_target = null
		t.interact(self)


func _physics_process(delta: float) -> void:
	if not alive:
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
		velocity.y -= _gravity * delta
		move_and_slide()
		return
	if not _vault_path.is_empty():
		_update_vault(delta)
		_update_look(delta)
		_update_weapon_input()
		return
	_update_stance(delta)
	_move(delta)
	_update_stamina(delta)
	_update_lean(delta)
	_update_look(delta)
	_update_weapon_input()
	_update_footsteps(delta)
	_update_interaction()


func _process(delta: float) -> void:
	holder.look_delta = _look_delta
	_look_delta = Vector2.ZERO
	_update_heartbeat(delta)
	_update_breath_sound(delta)
	suppression = maxf(suppression - delta * 0.35, 0.0)
	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.25
		light_exposure = _measure_light()


# --- Weapons --------------------------------------------------------------------

func add_weapon(data: WeaponData) -> Weapon:
	var weapon := Weapon.create(data, self)
	weapon.ammo_provider = self
	weapon.aim_source = _aim
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
	is_aiming = Input.is_action_pressed(&"aim") and not is_sprinting and current_weapon != null and _vault_path.is_empty() \
		and _stance_busy <= 0.0
	if current_weapon == null:
		return
	var blocked := holder.is_blocked() or is_sprinting or holder.is_switching() or not _vault_path.is_empty() or _stance_busy > 0.0
	current_weapon.set_trigger(Input.is_action_pressed(&"fire") and not blocked)
	current_weapon.aiming = is_aiming and holder.ads_blend > 0.8
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	current_weapon.spread_bonus = current_weapon.data.spread_moving * clampf(horizontal_speed / sprint_speed, 0.0, 1.0) \
		+ (1.5 if not is_on_floor() else 0.0)


func seconds_since_shot() -> float:
	return Time.get_ticks_msec() / 1000.0 - _last_shot


## Rounds cracking past or hitting close (from Ballistics).
func suppress(amount: float) -> void:
	if alive:
		suppression = minf(suppression + amount, 1.0)
		_shake = maxf(_shake, amount * 0.3)


## Roughly how lit the player is: lamps in range with a clear line, daylight
## from an open sky, the flashlight.
func _measure_light() -> float:
	_lights_age += 0.25
	if _lights_age > 4.0:
		_lights_age = 0.0
		_lights = get_tree().get_nodes_in_group(&"world_lights")
	var chest := global_position + Vector3.UP * 1.0
	var space := get_world_3d().direct_space_state
	var total := 0.08
	var near: Array = []
	for node in _lights:
		if not is_instance_valid(node) or not (node as Light3D).is_visible_in_tree():
			continue
		var light := node as Light3D
		if light is DirectionalLight3D:
			var up := PhysicsRayQueryParameters3D.create(chest, chest - (light as DirectionalLight3D).global_basis.z * -40.0, Layers.WORLD)
			if space.intersect_ray(up).is_empty():
				total += 0.6 * clampf(light.light_energy, 0.0, 1.5)
			continue
		var reach: float = (light as OmniLight3D).omni_range if light is OmniLight3D else (light as SpotLight3D).spot_range
		var d := light.global_position.distance_to(chest)
		if d < reach:
			near.append([light.light_energy * pow(1.0 - d / reach, 2.0), light])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in mini(near.size(), 3):
		var light: Light3D = near[i][1]
		var q := PhysicsRayQueryParameters3D.create(light.global_position, chest, Layers.WORLD)
		if space.intersect_ray(q).is_empty():
			total += float(near[i][0]) * 0.3
	if flashlight and flashlight.on:
		total += 0.35
	return clampf(total, 0.0, 1.0)


func _on_weapon_fired(weapon: Weapon) -> void:
	_last_shot = Time.get_ticks_msec() / 1000.0
	var mult: float = weapon.recoil_multiplier() * ([1.0, 0.75, 0.5][stance] as float) * (0.85 if is_aiming else 1.0) \
		* lerpf(1.25, 1.0, stamina)
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
	var want_run := Input.is_action_pressed(&"sprint") and input.y < -0.1 and stance == Stance.STAND and is_on_floor() \
		and not Input.is_action_pressed(&"aim") and absf(lean) < 0.2 and _stance_busy <= 0.0
	is_sprinting = want_run and not exhausted and stamina > 0.0
	var speed: float = [walk_speed, crouch_speed, prone_speed][stance]
	if is_sprinting:
		# Fades toward a jog as the legs and lungs give out.
		speed = lerpf(walk_speed * 1.15, sprint_speed, smoothstep(0.0, 0.4, stamina))
	if is_aiming:
		speed *= aim_speed_multiplier
	if absf(lean) > 0.2:
		speed *= lean_speed_multiplier
	if _stance_busy > 0.0:
		speed *= 0.3
	if current_weapon and stance == Stance.STAND:
		speed *= clampf(1.04 - current_weapon.data.weight_kg * 0.012, 0.9, 1.0)
	var accel := ground_accel if is_on_floor() else air_accel
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	if is_sprinting and flat_speed > walk_speed * 0.9:
		accel = sprint_accel
	velocity.x = lerpf(velocity.x, direction.x * speed, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, direction.z * speed, clampf(accel * delta, 0.0, 1.0))
	if not is_on_floor():
		velocity.y -= _gravity * delta
		_fall_speed = maxf(_fall_speed, -velocity.y)
	if Input.is_action_just_pressed(&"jump"):
		if not _try_vault(input) and is_on_floor() and stance == Stance.STAND and stamina >= jump_cost * 0.5:
			velocity.y = jump_velocity * lerpf(0.75, 1.0, stamina)
			_spend(jump_cost)
		elif stance != Stance.STAND and _vault_path.is_empty():
			_set_stance(Stance.STAND)
	move_and_slide()
	if is_on_floor() and not _was_on_floor and _fall_speed > 3.0:
		_land()
	if is_on_floor():
		_fall_speed = 0.0
	_was_on_floor = is_on_floor()


func _update_stamina(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if is_sprinting and speed > walk_speed:
		var load := 1.0 + (current_weapon.data.weight_kg * 0.03 if current_weapon else 0.0)
		_spend(delta * load / sprint_seconds)
		_since_run = 0.0
	else:
		_since_run += delta
		if _since_run > stamina_regen_delay and not holding_breath:
			var still := speed < 0.3 or stance != Stance.STAND
			stamina = minf(stamina + delta * (stamina_regen_still if still else stamina_regen), 1.0)
	if exhausted and stamina >= exhausted_until:
		exhausted = false
	# Holding the breath: steadies the aim, then the lungs want it back.
	var want_hold := is_aiming and Input.is_action_pressed(&"sprint") and _breath_left > 0.0 and _breath_debt <= 0.0
	holding_breath = want_hold
	if holding_breath:
		_breath_left -= delta * lerpf(1.6, 1.0, stamina)
		if _breath_left <= 0.0:
			_breath_debt = 2.5
	else:
		_breath_debt = maxf(_breath_debt - delta, 0.0)
		_breath_left = minf(_breath_left + delta * 0.8, hold_breath_seconds)


func _spend(amount: float) -> void:
	stamina = maxf(stamina - amount, 0.0)
	if stamina <= 0.0:
		exhausted = true
	_since_run = 0.0


func _set_stance(want: Stance) -> void:
	if want == stance or not _vault_path.is_empty():
		return
	var height: float = [stand_height, crouch_height, prone_height][want]
	if height > _height() + 0.05 and _ceiling_blocked(height):
		if want == Stance.STAND and stance == Stance.PRONE and not _ceiling_blocked(crouch_height):
			want = Stance.CROUCH
		else:
			return
	if want == Stance.PRONE or stance == Stance.PRONE:
		_stance_busy = prone_time
		Events.noise_emitted.emit(global_position, 3.0, self)
	stance = want


func _height() -> float:
	return (collision.shape as CapsuleShape3D).height


func _update_stance(delta: float) -> void:
	_stance_busy = maxf(_stance_busy - delta, 0.0)
	if Input.is_action_just_pressed(&"prone"):
		_set_stance(Stance.STAND if stance == Stance.PRONE else Stance.PRONE)
	# Crouch is held; prone is toggled (crouch or jump gets up from it).
	if stance != Stance.PRONE:
		var want_crouch := Input.is_action_pressed(&"crouch")
		if not want_crouch and stance == Stance.CROUCH and _ceiling_blocked(stand_height):
			want_crouch = true
		stance = Stance.CROUCH if want_crouch else Stance.STAND
	elif Input.is_action_just_pressed(&"crouch"):
		_set_stance(Stance.CROUCH)
	is_crouching = stance == Stance.CROUCH
	is_prone = stance == Stance.PRONE
	var capsule := collision.shape as CapsuleShape3D
	var target: float = [stand_height, crouch_height, prone_height][stance]
	# Getting down to or up from the floor is slow; crouching is quick.
	var rate := 4.0 if minf(target, capsule.height) >= crouch_height - 0.01 else (stand_height - prone_height) / prone_time
	capsule.height = move_toward(capsule.height, target, rate * delta)
	_fit_body(capsule.height, delta)


## Collision, hitbox and eye follow the body's height.
func _fit_body(h: float, delta: float) -> void:
	collision.position.y = h * 0.5
	hitbox.position.y = h * 0.5
	(hitbox.get_child(0) as CollisionShape3D).shape.set(&"height", maxf(h, 0.62))
	var eye := h - eye_below_top
	if h < crouch_height - 0.05:
		eye = h - 0.22  # lying down: the head is forward and low
	head.position.y = lerpf(head.position.y, eye, clampf(14.0 * delta, 0.0, 1.0))


func _ceiling_blocked(height: float = stand_height) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var probe := SphereShape3D.new()
	probe.radius = 0.3
	query.shape = probe
	query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3.UP * (height - 0.3))
	query.collision_mask = Layers.WORLD
	return not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


# --- Lean ---------------------------------------------------------------------

func _update_lean(delta: float) -> void:
	var want := 0.0
	if stance != Stance.PRONE and not is_sprinting:
		want = Input.get_axis(&"lean_left", &"lean_right")
	lean = move_toward(lean, want, delta * 4.5)
	# The head shifts sideways only as far as the space beside it allows.
	var reach := lean_offset * (0.8 if stance == Stance.CROUCH else 1.0) * lean
	if absf(reach) > 0.01:
		var side := global_basis.x * signf(reach)
		var from := global_position + Vector3.UP * head.position.y
		var query := PhysicsRayQueryParameters3D.create(from, from + side * (absf(reach) + 0.2), Layers.WORLD, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit:
			reach = signf(reach) * maxf(from.distance_to(hit.position) - 0.2, 0.0)
	_lean_x = lerpf(_lean_x, reach, clampf(16.0 * delta, 0.0, 1.0))
	head.position.x = _lean_x
	# What can be hit leans with the body.
	hitbox.position.x = _lean_x * 0.55
	hitbox.rotation.z = -deg_to_rad(lean_angle) * lean * 0.8


## Where the body's mass is (the AI aims and looks here): lower when crouched
## or prone, out to the side when leaning.
func center_mass() -> Vector3:
	var y: float = [1.25, 0.8, 0.28][stance]
	return global_position + global_basis.x * (_lean_x * 0.5) + Vector3.UP * y


# --- Vault and mantle -----------------------------------------------------------

## Over waist-high cover and through windows; up onto ledges to chest height.
func _try_vault(input: Vector2) -> bool:
	if stance == Stance.PRONE or input.y > -0.3 or not _vault_path.is_empty() or stamina < vault_cost * 0.5:
		return false
	if not is_on_floor() and velocity.y < -2.5:
		return false
	var space := get_world_3d().direct_space_state
	var fwd := -global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var base := global_position
	var ex: Array[RID] = [get_rid()]
	var face: Dictionary = {}
	for h: float in [0.45, 0.9, 1.4]:
		var q := PhysicsRayQueryParameters3D.create(base + Vector3.UP * h, base + Vector3.UP * h + fwd * 1.05, Layers.WORLD | Layers.CLIP, ex)
		face = space.intersect_ray(q)
		if face:
			break
	if face.is_empty() or (face["normal"] as Vector3).y > 0.5:
		return false
	var wall: Vector3 = face["position"]
	# The top of the obstacle just past its face.
	var top := _ground_below(wall + fwd * 0.22, base.y + 2.05, base.y + 0.3)
	if top == Vector3.INF:
		return false
	var height := top.y - base.y
	if height < 0.35 or height > 1.95:
		return false
	# Room to pass over the top, crouched.
	if _blocked_capsule(Vector3(wall.x, top.y + 0.05, wall.z) + fwd * 0.22, 0.85):
		return false
	var path: Array[Vector3] = [base]
	var over := Vector3.INF
	if height <= 1.25:
		# Thin enough to go over? Find where the top ends within a metre.
		for d: float in [0.45, 0.7, 0.95, 1.2]:
			var probe := wall + fwd * d
			var g := _ground_below(probe, top.y + 0.1, top.y - 2.0)
			if g != Vector3.INF and g.y < top.y - 0.25:
				if not _blocked_capsule(g + fwd * 0.35, crouch_height):
					over = g + fwd * 0.35
				break
			if g == Vector3.INF:
				break
	var up := Vector3(base.x, top.y + 0.08, base.z) + fwd * (base.distance_to(Vector3(wall.x, base.y, wall.z)) - 0.15)
	if over != Vector3.INF:
		path.append(up)
		path.append(Vector3(over.x, maxf(over.y, top.y - 0.4), over.z))
		path.append(over)
		_vault_time = 0.45 + height * 0.25
		_spend(vault_cost)
	else:
		var land := top + fwd * 0.35
		if _blocked_capsule(land, crouch_height):
			return false
		path.append(Vector3(base.x, top.y - 0.35, base.z) + fwd * 0.05)
		path.append(up)
		path.append(land)
		_vault_time = 0.55 + height * 0.45 * lerpf(1.5, 1.0, stamina)
		_spend(mantle_cost if height > 1.1 else vault_cost)
	_vault_path = path
	_vault_t = 0.0
	velocity = Vector3.ZERO
	holder.kick(0.03, -10.0)
	Events.noise_emitted.emit(global_position, 6.0, self)
	return true


func _update_vault(delta: float) -> void:
	_vault_t += delta / maxf(_vault_time, 0.1)
	var capsule := collision.shape as CapsuleShape3D
	capsule.height = move_toward(capsule.height, crouch_height, 6.0 * delta)
	_fit_body(capsule.height, delta)
	var segs := _vault_path.size() - 1
	var t := clampf(_vault_t, 0.0, 1.0) * segs
	var i := mini(int(t), segs - 1)
	var f := smoothstep(0.0, 1.0, t - i)
	global_position = _vault_path[i].lerp(_vault_path[i + 1], f)
	head.rotation.z = sin(clampf(_vault_t, 0.0, 1.0) * PI) * deg_to_rad(4.0)
	if _vault_t >= 1.0:
		_vault_path.clear()
		head.rotation.z = 0.0
		stance = Stance.CROUCH if _ceiling_blocked(stand_height) else Stance.STAND
		_land()


## Highest walkable surface under `p` between y0 and y1 (INF if none).
func _ground_below(p: Vector3, y0: float, y1: float) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, y0, p.z), Vector3(p.x, y1, p.z), Layers.WORLD | Layers.CLIP, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7:
		return Vector3.INF
	return hit["position"]


func _blocked_capsule(feet: Vector3, height: float) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.28
	shape.height = height
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * (height * 0.5 + 0.04))
	query.collision_mask = Layers.WORLD | Layers.CLIP | Layers.NPC
	query.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


# --- Look and aim ---------------------------------------------------------------

func _update_look(delta: float) -> void:
	# Recoil recovery: return part of the kick when not firing.
	if _recoil_pool > 0.0 and (current_weapon == null or not Input.is_action_pressed(&"fire")):
		var recover := minf(_recoil_pool, _recoil_pool * 6.0 * delta + 0.0005)
		_pitch -= recover
		_recoil_pool -= recover
	_shake = move_toward(_shake, 0.0, delta * 1.5)
	var shake_offset := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0.0) * _shake * 0.02
	var roll := -deg_to_rad(lean_angle) * lean
	if not _vault_path.is_empty():
		roll = head.rotation.z
	head.rotation = Vector3(_pitch, 0.0, roll) + shake_offset
	_update_sway(delta)
	var target_fov := _base_fov()
	if current_weapon and is_aiming:
		target_fov = lerpf(_base_fov(), current_weapon.ads_fov(), holder.ads_blend)
	elif is_sprinting:
		target_fov = _base_fov() + 3.0
	camera.fov = lerpf(camera.fov, target_fov, clampf(18.0 * delta, 0.0, 1.0))


## The aim wanders: a slow figure-of-eight with the breath, much wider and
## quicker when winded, steadier crouched and prone, near still while the
## breath is held. Shots follow it (the Aim node) and so does the weapon.
func _update_sway(delta: float) -> void:
	var winded := 1.0 - smoothstep(0.15, 0.85, stamina)
	if _since_run < 2.0:
		winded = maxf(winded, 0.35 * (1.0 - _since_run / 2.0))
	if _breath_debt > 0.0:
		winded = maxf(winded, 0.8)
	var amp := sway_rested + sway_winded * winded
	amp *= [1.0, 0.7, 0.3][stance] as float
	if absf(lean) > 0.2:
		amp *= 1.15
	if current_weapon:
		amp *= clampf(0.6 + current_weapon.data.weight_kg * 0.12, 0.7, 1.6) * current_weapon.data.sway
	amp += suppression * 2.0
	if holding_breath:
		amp *= 0.15
	var speed := Vector2(velocity.x, velocity.z).length()
	amp += speed * 0.25
	_sway_time += delta * lerpf(0.8, 2.4, winded)
	var t := _sway_time
	var target := Vector2(sin(t * 0.9) + 0.35 * sin(t * 2.3 + 1.7), 0.55 * sin(t * 1.8 + 0.6) + 0.25 * sin(t * 3.1)) * deg_to_rad(amp)
	_sway = _sway.lerp(target, clampf(6.0 * delta, 0.0, 1.0))
	_aim.rotation = Vector3(_sway.y, _sway.x, 0.0)
	holder.rotation = _aim.rotation


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
	var stride := 0.95 if is_sprinting else ([0.75, 0.55, 0.45][stance] as float)
	if _step_distance >= stride:
		_step_distance = 0.0
		var surface := _floor_surface()
		if surface:
			var volume := -4.0 if is_sprinting else ([-9.0, -16.0, -24.0][stance] as float)
			Audio.play_3d(Audio.pick(surface.footstep_sounds), global_position, &"World", volume, 3.0, 0.08)
		Events.noise_emitted.emit(global_position, 16.0 if is_sprinting else ([7.0, 2.5, 1.0][stance] as float), self)


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
	# Compare the prompt text too: a target that was just taken (freed) or
	# whose prompt changed must clear or update the HUD.
	var text := target.get_prompt() if target else ""
	if target != _interact_target or text != _prompt_text or not is_instance_valid(_interact_target):
		_interact_target = target
		if text != _prompt_text:
			_prompt_text = text
			interaction_prompt.emit(text)


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


## Heavy breathing as the stamina runs low, and the gasp after a held breath.
func _update_breath_sound(delta: float) -> void:
	if _breath == null:
		return
	var level := clampf(1.0 - stamina / 0.6, 0.0, 1.0)
	if _breath_debt > 0.0:
		level = maxf(level, 0.7)
	if holding_breath or not alive:
		level = 0.0
	if level > 0.01 and not _breath.playing:
		_breath.play()
	_breath.volume_db = lerpf(_breath.volume_db, linear_to_db(maxf(level, 0.0001)) - 6.0, clampf(4.0 * delta, 0.0, 1.0))
	_breath.pitch_scale = lerpf(0.9, 1.15, level)
	if level <= 0.0 and _breath.volume_db < -60.0:
		_breath.stop()


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
