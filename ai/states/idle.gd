extends AIState
## Stand in place, glance around. Moves on to patrol if there is a route.

var _look_timer: float = 0.0


func enter(_from: StringName) -> void:
	npc.stop()
	npc.clear_face()
	npc.lower_weapon()
	_look_timer = randf_range(2.0, 5.0)


func update(delta: float) -> void:
	if check_threats():
		return
	if not npc.patrol_points.is_empty() and brain.has_state(&"patrol"):
		brain.change(&"patrol")
		return
	_look_timer -= delta
	if _look_timer <= 0.0:
		_look_timer = randf_range(3.0, 7.0)
		npc.face(npc.global_position + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)))
