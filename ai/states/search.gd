extends AIState
## Lost the player mid-fight: go where they were last known, weapon up,
## then check a few spots round it, then give up and go back, edgier than
## before. Careful ones creep crouched; bold ones walk it fast. A sighting or
## a noise on the way changes everything.

var _points: Array[Vector3] = []
var _look: float = 0.0
var _looking: bool = false
var _sweep: float = 0.0


func enter(_from: StringName) -> void:
	var p := npc.perception
	_points.clear()
	_points.append(p.last_known_position)
	# Where they might have gone: round the last known spot, and on along
	# the way they were heading.
	var ahead := p.last_known_position + Vector3(p.last_seen_velocity.x, 0.0, p.last_seen_velocity.z).limit_length(1.0) * 6.0
	_points.append(Tactics.random_near(npc, ahead, 4.0))
	for i in randi_range(1, 2):
		_points.append(Tactics.random_near(npc, p.last_known_position, 9.0))
	npc.set_crouch(npc.aggression < 0.3)
	_next()
	Events.ai_callout.emit(npc, &"lost")


func exit() -> void:
	npc.set_crouch(false)
	npc.clear_face()


func update(delta: float) -> void:
	var p := npc.perception
	if p.is_alerted() and p.can_see_target:
		brain.change(&"combat")
		return
	if p.has_heard:
		p.has_heard = false
		_points.push_front(p.heard_position)
		_next()
		return
	if p.seconds_since_known() < 1.0 and p.is_alerted():
		# A mate just called them in.
		brain.change(&"combat")
		return
	if _looking:
		_look -= delta
		_sweep -= delta
		if _sweep <= 0.0:
			_sweep = randf_range(0.9, 1.8)
			var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
			npc.face(npc.global_position + dir)
			npc.aim_at(npc.global_position + dir * 6.0 + Vector3.UP * 1.3, true)
		if _look <= 0.0:
			_next()
		return
	# Walking it: gun up the way they're going.
	var fwd := -npc.global_basis.z
	npc.aim_at(npc.global_position + fwd * 6.0 + Vector3.UP * 1.3, true)
	if npc.arrived():
		_looking = true
		_look = randf_range(1.5, 3.5)
		_sweep = 0.0


func _next() -> void:
	_looking = false
	npc.clear_face()
	if _points.is_empty():
		npc.perception.awareness = 0.25
		npc.perception.alertness = maxf(npc.perception.alertness, 0.6)
		brain.change(&"patrol" if not npc.patrol_points.is_empty() else &"idle")
		return
	npc.move_to(_points.pop_front(), npc.aggression > 0.6)
