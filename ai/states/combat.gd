extends AIState
## Fight the player: face, react, fire in bursts while visible; chase the last
## known position when not; reload from cover when a cover point is nearby.

var _reaction: float = 0.0
var _burst_shots_left: int = 0
var _pause: float = 0.0
var _pulse: float = 0.0
var _aim_offset := Vector3.ZERO
var _seeking_cover: bool = false


func enter(_from: StringName) -> void:
	npc.stop()
	_reaction = npc.data.reaction_time * randf_range(0.8, 1.3)
	_pause = 0.0
	_burst_shots_left = 0


func exit() -> void:
	if npc.weapon:
		npc.weapon.set_trigger(false)


func update(delta: float) -> void:
	var perception := npc.perception
	var player := perception.target()
	var weapon := npc.weapon
	if player == null:
		if weapon:
			weapon.set_trigger(false)
		brain.change(&"patrol" if not npc.patrol_points.is_empty() else &"idle")
		return
	if weapon == null:
		return

	# Reload when empty; prefer to do it out of sight.
	if weapon.loaded_rounds() == 0 and not weapon.is_busy():
		weapon.set_trigger(false)
		weapon.reload()
		var cover := _find_cover(player)
		if cover != Vector3.INF:
			_seeking_cover = true
			npc.clear_face()
			npc.move_to(cover, true)
	if weapon.is_busy():
		weapon.set_trigger(false)
		if not _seeking_cover:
			npc.face(perception.last_seen_position)
		return
	if _seeking_cover:
		_seeking_cover = false
		npc.move_to(perception.last_seen_position, false)

	if perception.can_see_target:
		npc.stop()
		npc.face(player.global_position)
		var target := player.global_position + Vector3.UP * (0.85 if player.is_crouching else 1.25)
		npc.aim_at(target + _aim_offset, true)
		if _reaction > 0.0:
			_reaction -= delta
			return
		_fire(delta, weapon)
	else:
		weapon.set_trigger(false)
		_reaction = maxf(_reaction, npc.data.reaction_time * 0.5)
		npc.clear_face()
		if perception.seconds_since_seen() > 1.2:
			npc.move_to(perception.last_seen_position, true)
			npc.aim_at(perception.last_seen_position + Vector3.UP * 1.3, true)
		if perception.seconds_since_seen() > 14.0 and npc.arrived():
			perception.awareness = 0.6
			perception.heard_position = perception.last_seen_position
			brain.change(&"investigate")


func _fire(delta: float, weapon: Weapon) -> void:
	if _pause > 0.0:
		_pause -= delta
		weapon.set_trigger(false)
		return
	if _burst_shots_left <= 0:
		_burst_shots_left = randi_range(npc.data.burst_min, npc.data.burst_max)
		# New aim error each burst: misses walk in rather than spraying randomly.
		_aim_offset = Vector3(randf_range(-1, 1), randf_range(-0.6, 0.8), randf_range(-1, 1)) * 0.35
	var auto := weapon.current_mode() == WeaponData.FireMode.AUTO
	if auto:
		var before := weapon.loaded_rounds()
		weapon.set_trigger(true)
		if weapon.loaded_rounds() < before:
			_burst_shots_left -= 1
	else:
		# Semi / bolt: pulse the trigger.
		_pulse -= delta
		if _pulse <= 0.0:
			weapon.set_trigger(true)
			_pulse = maxf(weapon.data.time_between_shots(), 0.28)
			_burst_shots_left -= 1
		else:
			weapon.set_trigger(false)
	if _burst_shots_left <= 0:
		weapon.set_trigger(false)
		_pause = npc.data.burst_pause * randf_range(0.7, 1.4)
		_aim_offset *= 0.5


func _find_cover(player: Player) -> Vector3:
	var best := Vector3.INF
	var best_d := 14.0
	for node in npc.get_tree().get_nodes_in_group(&"cover"):
		var point := (node as Node3D).global_position
		var d := npc.global_position.distance_to(point)
		if d > best_d:
			continue
		var query := PhysicsRayQueryParameters3D.create(player.head.global_position, point + Vector3.UP * 1.2, Layers.SIGHT_MASK)
		if not npc.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			best = point
			best_d = d
	return best
