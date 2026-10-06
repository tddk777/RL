extends AIState
## React to a noise: stop and turn toward it with the weapon up, then move to
## where it came from and search for a while.

const ORIENT_TIME := 1.4

var _orient: float = 0.0
var _search: float = 0.0
var _arrived: bool = false
var _look_timer: float = 0.0


func enter(_from: StringName) -> void:
	_begin()


func update(delta: float) -> void:
	if npc.perception.is_alerted():
		brain.change(&"combat")
		return
	if npc.perception.has_heard:
		npc.perception.has_heard = false
		_begin()
	var target := npc.perception.target()
	# Partially spotted: stop and stare at the player until sure.
	if npc.perception.awareness > 0.25 and target:
		npc.stop()
		npc.face(target.global_position)
		npc.aim_at(target.head.global_position, true)
		return
	if _orient > 0.0:
		_orient -= delta
		if _orient <= 0.0:
			npc.clear_face()
			npc.move_to(npc.perception.heard_position, false)
		return
	if not _arrived and npc.arrived():
		_arrived = true
	if _arrived:
		_search -= delta
		_look_timer -= delta
		if _look_timer <= 0.0:
			_look_timer = randf_range(1.2, 2.5)
			var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
			npc.face(npc.global_position + dir)
			npc.aim_at(npc.global_position + dir * 5.0 + Vector3.UP * 1.3, false)
		if _search <= 0.0:
			brain.change(&"patrol" if not npc.patrol_points.is_empty() else &"idle")


func _begin() -> void:
	_arrived = false
	_search = randf_range(5.0, 8.0)
	_orient = ORIENT_TIME * randf_range(0.8, 1.2)
	npc.stop()
	npc.face(npc.perception.heard_position)
	npc.aim_at(npc.perception.heard_position + Vector3.UP * 1.2, true)
