class_name NPC
extends CharacterBody3D
## An AI-controlled human. Numbers come from `data` (EnemyData); behaviour
## comes from the AIState nodes under Brain; the look and hitboxes come from
## the Body node (an NPCBody: Mannequin, Humanoid or another rigged model).

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

var _aim: Node3D
var _move_target := Vector3.ZERO
var _moving: bool = false
var _running: bool = false
var _face_target := Vector3.ZERO
var _has_face_target: bool = false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	collision_layer = Layers.NPC
	collision_mask = Layers.WORLD | Layers.PLAYER | Layers.NPC | Layers.CLIP
	health.max_health = data.max_health
	health.current = data.max_health
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	hitboxes = body.setup(health)
	_aim = Node3D.new()
	_aim.name = "Aim"
	add_child(_aim)
	if data.weapon:
		weapon = Weapon.create(data.weapon, self)
		weapon.aim_source = _aim
		weapon.spread_bonus = data.aim_error
		weapon.exclude = exclude_rids()
		body.hold_weapon(weapon)
	perception.npc = self
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


## Turn the body toward a point (overrides facing the walk direction).
func face(point: Vector3) -> void:
	_face_target = point
	_has_face_target = true


func clear_face() -> void:
	_has_face_target = false


## Aim the weapon at a point. `error_deg` scatters the aim per call.
func aim_at(point: Vector3, aiming: bool = true) -> void:
	var from := eye_position()
	_aim.global_position = from
	if from.distance_to(point) > 0.1:
		_aim.look_at(point, Vector3.UP)
	body.set_aim(point, aiming)


func lower_weapon() -> void:
	body.set_aim(global_position - global_basis.z * 5.0, false)


# --- Simulation -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not alive:
		velocity = Vector3(0, velocity.y - _gravity * delta, 0)
		move_and_slide()
		return
	brain.update(delta)
	var horizontal := Vector3.ZERO
	if _moving and not nav.is_navigation_finished():
		var next := nav.get_next_path_position()
		var dir := next - global_position
		dir.y = 0.0
		if dir.length() > 0.05:
			horizontal = dir.normalized() * (data.run_speed if _running else data.walk_speed)
	elif _moving:
		_moving = false
	velocity.x = lerpf(velocity.x, horizontal.x, clampf(8.0 * delta, 0, 1))
	velocity.z = lerpf(velocity.z, horizontal.z, clampf(8.0 * delta, 0, 1))
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()
	_turn(delta, horizontal)
	body.set_motion(Vector2(velocity.x, velocity.z).length(), _running)


func _turn(delta: float, horizontal: Vector3) -> void:
	var look := Vector3.ZERO
	if _has_face_target:
		look = _face_target - global_position
	elif horizontal.length() > 0.1:
		look = horizontal
	look.y = 0.0
	if look.length() < 0.01:
		return
	var target_yaw := atan2(-look.x, -look.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(7.0 * delta, 0, 1))


func _on_damaged(hit: HitInfo) -> void:
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
