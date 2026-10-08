class_name Perception
extends Node
## Sight, hearing and what the NPC believes about the player.
##
## Sight builds `awareness` (0 unaware .. 1 sure) while any of the player's
## head or body is in view: faster close up, in the middle of the view, when
## the player is lit (lamps, daylight, their own flashlight) or moving fast or
## has just fired; slower crouched, slower still prone, in the dark, at the
## edge of vision. Hearing: noises carry their radius, halved through walls
## and floors; what's heard is placed only roughly (worse the fainter), so a
## shot heard round a corner sends them looking, not straight to you.
##
## `last_known_position` is the only place the AI ever goes for the player:
## updated by its own sight, by loud nearby sounds, and by mates' callouts.

signal heard(position: Vector3)

const CHECK_INTERVAL := 0.1
const PROXIMITY := 2.5
## Awareness above which the NPC is suspicious (stops, looks, investigates).
const SUSPICIOUS := 0.3
## Awareness from which the NPC is sure (fights rather than investigates).
const ALERTED := 0.9

var npc: NPC
var awareness: float = 0.0
var can_see_target: bool = false
## How much of the player was in view at the last check (0..1).
var exposure: float = 0.0
var last_seen_position := Vector3.ZERO
var last_seen_time: float = -1000.0
var last_known_position := Vector3.ZERO
var last_known_time: float = -1000.0
var last_seen_velocity := Vector3.ZERO
var has_heard: bool = false
var heard_position := Vector3.ZERO
var heard_loud: bool = false
## Raised for a while after a fight or a scare: looks harder, reacts quicker.
var alertness: float = 0.0

var _timer: float = 0.0
var _visible_raw: float = 0.0


func _ready() -> void:
	Events.noise_emitted.connect(_on_noise)
	_timer = randf() * CHECK_INTERVAL  # spread the ray casts over frames


func target() -> Player:
	var p := Game.player
	return p if is_instance_valid(p) and p.alive else null


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func seconds_since_seen() -> float:
	return now() - last_seen_time


func seconds_since_known() -> float:
	return now() - last_known_time


## Sure there's an enemy (awareness takes a few quiet seconds to drop below this).
func is_alerted() -> bool:
	return awareness >= ALERTED


func is_suspicious() -> bool:
	return awareness >= SUSPICIOUS


## Shot at or hit: they know roughly where from.
func alert_to(position: Vector3) -> void:
	awareness = 1.0
	alertness = 1.0
	_know(position + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5)), now())


## A mate's callout: what they knew and when.
func receive_report(position: Vector3, when: float) -> void:
	if when <= last_known_time:
		return
	awareness = maxf(awareness, 1.0 if awareness >= SUSPICIOUS else 0.85)
	alertness = maxf(alertness, 0.7)
	_know(position, when)
	if not is_alerted():
		has_heard = true
		heard_position = position
		heard_loud = true


func _know(position: Vector3, when: float) -> void:
	last_known_position = position
	last_known_time = when


func line_of_sight(point: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(npc.eye_position(), point, Layers.SIGHT_MASK, npc.exclude_rids())
	return npc.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _physics_process(delta: float) -> void:
	if npc == null or not npc.alive:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = CHECK_INTERVAL
		_visible_raw = _check_sight()
	var player := target()
	exposure = _visible_raw if player != null else 0.0
	can_see_target = exposure > 0.0
	alertness = maxf(alertness - delta * 0.01, 0.0)
	if can_see_target:
		awareness = minf(awareness + delta * _detect_rate(player), 1.0)
		if awareness > SUSPICIOUS:
			# Not sure yet: they have a rough idea where.
			var fuzz := (1.0 - awareness) * 2.5
			last_seen_position = player.global_position + Vector3(randf_range(-fuzz, fuzz), 0.0, randf_range(-fuzz, fuzz))
			last_seen_time = now()
			if awareness >= 0.7:
				last_seen_position = player.global_position
				last_seen_velocity = player.velocity
				_know(player.global_position, now())
	else:
		# Once they know there's someone, it takes a long quiet to forget.
		var decay := 0.03 if awareness >= 0.5 and seconds_since_known() < 25.0 else 0.18
		awareness = maxf(awareness - delta * decay, 0.0)


func _detect_rate(player: Player) -> float:
	var data := npc.data
	var distance := npc.eye_position().distance_to(player.head.global_position)
	var rate := clampf(1.0 - distance / data.sight_range, 0.08, 1.0) * 1.6
	rate *= [1.0, 0.55, 0.28][player.stance] as float
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	rate *= 1.7 if speed > 3.5 else (1.2 if speed > 1.0 else 0.65)
	rate *= lerpf(0.25, 1.15, player.light_exposure)
	if player.seconds_since_shot() < 0.4:
		rate *= 4.0  # a muzzle flash gives anyone away
	if player.flashlight and player.flashlight.on:
		# A torch pointed their way is a beacon.
		var to_npc := (npc.eye_position() - player.camera.global_position).normalized()
		if (-player.camera.global_basis.z).dot(to_npc) > 0.9:
			rate *= 3.0
	rate *= exposure
	if distance < PROXIMITY * 2.0:
		rate *= 3.0
	rate *= 1.0 + alertness * 0.8 + (0.6 if awareness >= SUSPICIOUS else 0.0)
	if awareness >= 0.5 and seconds_since_known() < 20.0:
		rate *= 4.0  # already hunting someone: any glimpse is them
	return rate / maxf(data.detection_time, 0.05)


## 0..1: how much of the player is in view, weighted by where in the field of
## view (the middle sees best).
func _check_sight() -> float:
	var player := target()
	if player == null:
		return 0.0
	var eye := npc.eye_position()
	var head := player.head.global_position
	var to_target := head - eye
	var distance := to_target.length()
	if distance > npc.data.sight_range:
		return 0.0
	var view := 1.0
	if distance > PROXIMITY:
		var forward := -npc.global_basis.z
		var flat := Vector3(to_target.x, 0.0, to_target.z).normalized()
		var angle := rad_to_deg(forward.angle_to(flat))
		var half := npc.data.sight_fov_degrees * 0.5
		if angle > half:
			return 0.0
		view = lerpf(1.0, 0.3, smoothstep(25.0, half, angle))
	var seen := 0.0
	var space := npc.get_world_3d().direct_space_state
	for pair: Array in [[head, 0.4], [player.center_mass(), 0.6]]:
		var query := PhysicsRayQueryParameters3D.create(eye, pair[0], Layers.SIGHT_MASK, npc.exclude_rids())
		if space.intersect_ray(query).is_empty():
			seen += pair[1]
	return seen * view


func _on_noise(position: Vector3, radius: float, source: Node) -> void:
	if npc == null or not npc.alive or source == npc or source is NPC:
		return
	var eye := npc.eye_position()
	var reach := radius * npc.data.hearing_multiplier
	var distance := eye.distance_to(position)
	if distance > reach:
		return
	# Through walls and floors a sound carries about half as far.
	if not line_of_sight(position + Vector3.UP * 0.6):
		reach *= 0.5
		if distance > reach:
			return
	var clarity := 1.0 - distance / reach
	var loud := radius >= 30.0
	var fuzz := distance * 0.18 * (1.0 - clarity)
	heard_position = position + Vector3(randf_range(-fuzz, fuzz), 0.0, randf_range(-fuzz, fuzz))
	heard_loud = loud
	has_heard = true
	if loud:
		awareness = maxf(awareness, 0.6 + clarity * 0.35)
		alertness = maxf(alertness, 0.6)
		if clarity > 0.55:
			_know(heard_position, now())
	else:
		awareness = minf(maxf(awareness, awareness + 0.22 * clarity), 0.9)
	heard.emit(heard_position)
