extends AIState
## Something's off (a noise, a glimpse, a mate's shout): stop and turn toward
## it with the weapon up, stare while unsure, then go and look, carefully, and
## search round there for a while.

const ORIENT_TIME := 1.2

var _orient: float = 0.0
var _search: float = 0.0
var _arrived: bool = false
var _look_timer: float = 0.0
var _where := Vector3.ZERO


func enter(_from: StringName) -> void:
	_begin(_source())


func exit() -> void:
	npc.set_crouch(false)


func update(delta: float) -> void:
	var p := npc.perception
	if p.is_alerted():
		brain.change(&"combat")
		return
	if p.has_heard:
		p.has_heard = false
		_begin(p.heard_position)
	var target := p.target()
	# Half seen: stop and stare at the shape until sure (or it's gone).
	if p.can_see_target and p.is_suspicious() and target:
		npc.stop()
		npc.face(target.global_position)
		npc.aim_at(target.center_mass(), true)
		_where = p.last_seen_position
		_orient = maxf(_orient, 0.6)
		return
	if _orient > 0.0:
		_orient -= delta
		if _orient <= 0.0:
			npc.clear_face()
			# The careful ones creep up on it.
			npc.set_crouch(npc.aggression < 0.35)
			npc.move_to(_where, false)
		return
	if not _arrived and npc.arrived():
		_arrived = true
		npc.set_crouch(false)
	if not _arrived:
		npc.aim_at(npc.global_position - npc.global_basis.z * 6.0 + Vector3.UP * 1.3, true)
		return
	_search -= delta
	_look_timer -= delta
	if _look_timer <= 0.0:
		_look_timer = randf_range(1.2, 2.5)
		var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		npc.face(npc.global_position + dir)
		npc.aim_at(npc.global_position + dir * 5.0 + Vector3.UP * 1.3, p.alertness > 0.3)
	if _search <= 0.0:
		p.awareness = minf(p.awareness, 0.2)
		brain.change(&"patrol" if not npc.patrol_points.is_empty() else &"idle")


func _source() -> Vector3:
	var p := npc.perception
	if p.has_heard:
		p.has_heard = false
		return p.heard_position
	return p.last_seen_position if p.seconds_since_seen() < 5.0 else p.last_known_position


func _begin(where: Vector3) -> void:
	_where = where
	_arrived = false
	_search = randf_range(5.0, 9.0)
	_orient = ORIENT_TIME * randf_range(0.8, 1.3)
	npc.stop()
	npc.face(where)
	npc.aim_at(where + Vector3.UP * 1.2, true)
