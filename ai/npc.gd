class_name NPC
extends CharacterBody3D
## An AI-controlled human. Numbers come from `data` (EnemyData); behaviour
## comes from the AIState nodes under Brain; the look and hitboxes come from
## the Body node (an NPCBody: Mannequin, Humanoid or another rigged model).
##
## Each one rolls a temperament (aggression) and a hand (skill) around the
## EnemyData values. Fire close by pins them (`suppression`): the aim goes,
## they keep their heads down longer. The aim starts wild on a new target and
## settles the longer they track it, and opens up again when they move, are
## hit or pinned. They can be heard: footsteps by surface, louder running.

@export var data: EnemyData
## World positions to walk between (set by the EnemySpawn that created us).
var patrol_points: Array[Vector3] = []

@onready var body: NPCBody = $Body
@onready var health: HealthComponent = $HealthComponent
@onready var perception: Perception = $Perception
@onready var brain: AIBrain = $Brain
@onready var nav: NavigationAgent3D = $NavigationAgent3D

var weapon: Weapon
var alive: bool = true
var hitboxes: Array[Hitbox] = []
var aggression: float = 0.5
var skill: float = 0.5
## 0..1: how pinned down they are.
var suppression: float = 0.0
var crouched: bool = false
var director: AIDirector

var _aim: Node3D
var _move_target := Vector3.ZERO
var _moving: bool = false
var _running: bool = false
var _face_target := Vector3.ZERO
var _has_face_target: bool = false
var _settle: float = 0.0  # 0 = first wild shots .. 1 = settled
var _step: float = 0.0
var _stuck: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	collision_layer = Layers.NPC
	collision_mask = Layers.WORLD | Layers.PLAYER | Layers.NPC | Layers.CLIP
	health.max_health = data.max_health
	health.current = data.max_health
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	hitboxes = body.setup(health)
	aggression = clampf(data.aggression + randf_range(-1.0, 1.0) * data.aggression_spread, 0.0, 1.0)
	skill = clampf(data.skill + randf_range(-1.0, 1.0) * data.skill_spread, 0.0, 1.0)
	_aim = Node3D.new()
	_aim.name = "Aim"
	add_child(_aim)
	if data.weapon:
		weapon = Weapon.create(data.weapon, self)
		weapon.aim_source = _aim
		weapon.spread_bonus = data.aim_error
		weapon.exclude = exclude_rids()
		body.hold_weapon(weapon)
	# Close enough to step exactly into and out of cover.
	nav.target_desired_distance = 0.45
	perception.npc = self
	director = AIDirector.of(self)
	director.register(self)
	brain.setup(self)


func exclude_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	for box in hitboxes:
		rids.append(box.get_rid())
	return rids


func eye_position() -> Vector3:
	return body.eye.global_position


# --- Commands used by AI states ------------------------------------------------

func move_to(target: Vector3, run: bool = false) -> void:
	_move_target = target
	_moving = true
	_running = run
	nav.target_position = target


func stop() -> void:
	_moving = false


func arrived() -> bool:
	return not _moving or nav.is_navigation_finished()


## Where the current move is headed.
func move_target() -> Vector3:
	return _move_target


func is_moving() -> bool:
	return _moving and not nav.is_navigation_finished()


func set_crouch(on: bool) -> void:
	crouched = on
	body.set_crouch(on)


## Turn toward a point (overrides facing the walk direction; walking away
## from it, they back off facing it).
func face(point: Vector3) -> void:
	_face_target = point
	_has_face_target = true


func clear_face() -> void:
	_has_face_target = false


## Aim the weapon at a point. The weapon's spread carries the aim error.
func aim_at(point: Vector3, aiming: bool = true) -> void:
	var from := eye_position()
	_aim.global_position = from
	if from.distance_to(point) > 0.1:
		_aim.look_at(point, Vector3.UP)
	body.set_aim(point, aiming)


func lower_weapon() -> void:
	body.set_aim(global_position - global_basis.z * 5.0, false)


## Called each frame while tracking the target; `steady` false resets the settle.
func track(delta: float, steady: bool) -> void:
	if steady:
		_settle = minf(_settle + delta / maxf(data.aim_settle_time * lerpf(1.4, 0.6, skill), 0.1), 1.0)
	else:
		_settle = maxf(_settle - delta * 2.0, 0.0)


## Lost sight: next time they see you, the first shots go wide again.
func unsettle(amount: float = 1.0) -> void:
	_settle = maxf(_settle - amount, 0.0)


## Degrees of aim error right now (on top of the weapon's spread).
func aim_error() -> float:
	var e := data.aim_error * lerpf(1.35, 0.7, skill)
	e *= lerpf(data.first_shot_error, 1.0, smoothstep(0.0, 1.0, _settle))
	e *= 1.0 + suppression * 2.2
	if is_moving():
		e *= 1.8 if _running else 1.3
	return e


## Fire passed close by (from Ballistics): `amount` 0..1 by how close.
func suppress(amount: float, from: Vector3) -> void:
	if not alive:
		return
	suppression = minf(suppression + amount / maxf(data.suppression_tolerance, 0.1), 1.0)
	unsettle(amount * 0.5)
	if not perception.is_alerted():
		perception.alert_to(from)


# --- Simulation -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not alive:
		velocity = Vector3(0, velocity.y - _gravity * delta, 0)
		move_and_slide()
		return
	suppression = maxf(suppression - delta * 0.28, 0.0)
	brain.update(delta)
	if weapon:
		weapon.spread_bonus = aim_error()
	var horizontal := Vector3.ZERO
	if _moving and not nav.is_navigation_finished():
		var next := nav.get_next_path_position()
		var dir := next - global_position
		dir.y = 0.0
		if dir.length() > 0.05:
			var speed := data.crouch_speed if crouched else (data.run_speed if _running else data.walk_speed)
			if _backing_off(dir):
				speed = minf(speed, data.walk_speed * 1.2)
			horizontal = dir.normalized() * speed
	elif _moving:
		_moving = false
	# Pressed against the wall beside the spot (bodies are wider than the
	# navmesh margin): close enough counts as there.
	if _moving and Vector2(velocity.x, velocity.z).length() < 0.25:
		_stuck += delta
		if _stuck > 0.6 and Vector2(global_position.x - _move_target.x, global_position.z - _move_target.z).length() < 1.4:
			_moving = false
	else:
		_stuck = 0.0
	velocity.x = lerpf(velocity.x, horizontal.x, clampf(8.0 * delta, 0, 1))
	velocity.z = lerpf(velocity.z, horizontal.z, clampf(8.0 * delta, 0, 1))
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()
	_turn(delta, horizontal)
	var speed := Vector2(velocity.x, velocity.z).length()
	body.set_backward(_backing_off(horizontal))
	body.set_motion(speed, _running)
	_footsteps(delta, speed)


## Moving away from what they're facing: they back off, eyes front.
func _backing_off(move: Vector3) -> bool:
	if not _has_face_target or move.length() < 0.1:
		return false
	var look := _face_target - global_position
	look.y = 0.0
	return look.length() > 0.1 and move.normalized().dot(look.normalized()) < -0.3


func _turn(delta: float, horizontal: Vector3) -> void:
	var look := Vector3.ZERO
	if _has_face_target:
		look = _face_target - global_position
		look.y = 0.0
		# Strafing: the hips follow the walk, the chest twists to the aim.
		if horizontal.length() > 0.1 and look.length() > 0.1:
			var angle := absf(horizontal.normalized().signed_angle_to(look.normalized(), Vector3.UP))
			if angle < deg_to_rad(65.0):
				look = horizontal
			elif angle < deg_to_rad(115.0):
				look = (horizontal.normalized() + look.normalized()).normalized()
	elif horizontal.length() > 0.1:
		look = horizontal
	look.y = 0.0
	if look.length() < 0.01:
		return
	var target_yaw := atan2(-look.x, -look.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(7.0 * delta, 0, 1))


## Footsteps the player can hear: by surface, louder and longer-strided running.
func _footsteps(delta: float, speed: float) -> void:
	if speed < 0.4 or not is_on_floor():
		_step = 0.0
		return
	_step += speed * delta
	var stride := 1.0 if _running else (0.6 if crouched else 0.75)
	if _step < stride:
		return
	_step = 0.0
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.2, global_position + Vector3.DOWN * 0.4, Layers.WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var surface := Registry.surface(Surface.of(hit.collider) if hit else Surface.DEFAULT)
	if surface and not surface.footstep_sounds.is_empty():
		var volume := -3.0 if _running else (-17.0 if crouched else -10.0)
		Audio.play_3d(Audio.pick(surface.footstep_sounds), global_position, &"World", volume, 4.0 if _running else 2.5, 0.08)


func _on_damaged(hit: HitInfo) -> void:
	suppression = minf(suppression + 0.5, 1.0)
	unsettle(0.6)
	body.flinch(hit.position.y > eye_position().y - 0.2)
	if hit.source is Node3D:
		perception.alert_to((hit.source as Node3D).global_position)


func _on_died(hit: HitInfo) -> void:
	alive = false
	brain.change(&"dead")
	if weapon:
		weapon.set_trigger(false)
		weapon.cancel_action()
	for box in hitboxes:
		box.set_enabled(false)
	collision_layer = 0
	body.die(hit.direction)
	var killer := (hit.source as Node3D).global_position if hit.source is Node3D else Vector3.INF
	director.report_death(self, killer)
