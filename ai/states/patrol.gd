extends AIState
## Walk the patrol route, pausing and looking around at each point.

var _index: int = 0
var _wait: float = 0.0


func enter(_from: StringName) -> void:
	npc.clear_face()
	npc.lower_weapon()
	_index = _nearest_point()
	_go()


func update(delta: float) -> void:
	if check_threats():
		return
	if npc.patrol_points.is_empty():
		brain.change(&"idle")
		return
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			_index = (_index + 1) % npc.patrol_points.size()
			npc.clear_face()
			_go()
		return
	if npc.arrived():
		_wait = randf_range(2.0, 5.0)
		npc.face(npc.global_position - npc.global_basis.z.rotated(Vector3.UP, randf_range(-1.5, 1.5)))


func _go() -> void:
	npc.move_to(npc.patrol_points[_index], false)


func _nearest_point() -> int:
	var best := 0
	var best_d := INF
	for i in npc.patrol_points.size():
		var d := npc.global_position.distance_to(npc.patrol_points[i])
		if d < best_d:
			best_d = d
			best = i
	return best
