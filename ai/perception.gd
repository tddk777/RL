class_name Perception
extends Node
## Sight and hearing for an NPC. Builds `awareness` (0..1) while the player is
## visible: faster up close, slower when the player is crouched or far away.
## Hearing listens to Events.noise_emitted.

signal heard(position: Vector3)

const CHECK_INTERVAL := 0.1
const PROXIMITY := 2.5

var npc: NPC
var awareness: float = 0.0
var can_see_target: bool = false
var last_seen_position := Vector3.ZERO
var last_seen_time: float = -1000.0
var has_heard: bool = false
var heard_position := Vector3.ZERO

var _timer: float = 0.0
var _visible_raw: bool = false


func _ready() -> void:
	Events.noise_emitted.connect(_on_noise)


func target() -> Player:
	var p := Game.player
	return p if is_instance_valid(p) and p.alive else null


func seconds_since_seen() -> float:
	return Time.get_ticks_msec() / 1000.0 - last_seen_time


func is_alerted() -> bool:
	return awareness >= 1.0


func alert_to(position: Vector3) -> void:
	awareness = 1.0
	last_seen_position = position
	last_seen_time = Time.get_ticks_msec() / 1000.0


func _physics_process(delta: float) -> void:
	if npc == null or not npc.alive:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = CHECK_INTERVAL
		_visible_raw = _check_sight()
	var player := target()
	can_see_target = _visible_raw and player != null
	if can_see_target:
		var distance := npc.eye_position().distance_to(player.head.global_position)
		var rate := clampf(1.0 - distance / npc.data.sight_range, 0.15, 1.0) * 1.6
		if player.is_crouching:
			rate *= 0.5
		if Vector2(player.velocity.x, player.velocity.z).length() > 2.0:
			rate *= 1.5
		if distance < PROXIMITY * 2.0:
			rate *= 3.0
		awareness = minf(awareness + delta * rate / maxf(npc.data.detection_time, 0.05), 1.0)
		if awareness > 0.3:
			last_seen_position = player.global_position
			last_seen_time = Time.get_ticks_msec() / 1000.0
	else:
		var decay := 0.04 if awareness >= 1.0 and seconds_since_seen() < 20.0 else 0.25
		awareness = maxf(awareness - delta * decay, 0.0)


func _check_sight() -> bool:
	var player := target()
	if player == null:
		return false
	var eye := npc.eye_position()
	var head := player.head.global_position
	var to_target := head - eye
	var distance := to_target.length()
	if distance > npc.data.sight_range:
		return false
	if distance > PROXIMITY:
		var forward := -npc.global_basis.z
		var flat := Vector3(to_target.x, 0.0, to_target.z).normalized()
		if rad_to_deg(forward.angle_to(flat)) > npc.data.sight_fov_degrees * 0.5:
			return false
	# Visible if the head or chest has a clear line.
	for point in [head, player.global_position + Vector3.UP * (0.9 if not player.is_crouching else 0.6)]:
		var query := PhysicsRayQueryParameters3D.create(eye, point, Layers.SIGHT_MASK, npc.exclude_rids())
		if npc.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			return true
	return false


func _on_noise(position: Vector3, radius: float, source: Node) -> void:
	if npc == null or not npc.alive or source == npc:
		return
	if source is NPC:
		return  # allies' own gunfire doesn't count as finding the player
	if npc.global_position.distance_to(position) <= radius * npc.data.hearing_multiplier:
		has_heard = true
		heard_position = position
		heard.emit(position)
