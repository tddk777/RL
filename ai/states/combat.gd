extends AIState
## Fight the player the way a person in a firefight would, from what this NPC
## knows (its own senses and mates' callouts, never the player's real
## position when hidden).
##
## Tactics, re-chosen every couple of seconds or when something changes:
##   take_cover  run to the best cover with a shot (Tactics.find)
##   engage      from cover: hide (crouched behind low cover, back from the
##               edge of side cover), then peek and fire bursts, then hide;
##               longer heads-down when pinned, quicker peeks when bold;
##               while hidden or holding, the gun stays on where the player
##               was, so a re-peek there is met fast
##   flank       the director's flanker works round the player's side while
##               the others keep them busy
##   push        move in on an opening: the player heard reloading, just
##               hit, or gone quiet in front of a bold one
##   retreat     hurt, pinned or mates dead: fall back to cover further off
## Suppressive fire: with the player behind cover, holders and bold ones put
## bursts on the last known spot to pin them while others move.
## Mistakes: first shots go wide, reactions vary, the odd one stands in the
## open or reloads in view, and outdated information sends them to where
## you were, not where you are.

enum Tactic { TAKE_COVER, ENGAGE, FLANK, PUSH, RETREAT }

var tactic: Tactic = Tactic.TAKE_COVER
var spot: Tactics.Spot

var _reaction: float = 0.0
var _decide: float = 0.0
var _peeking: bool = false
var _phase: float = 0.0
var _burst_left: int = 0
var _pause: float = 0.0
var _pulse: float = 0.0
var _aim_offset := Vector3.ZERO
var _since_move: float = 0.0
var _check: float = 0.0
var _saw: bool = false
var _share: float = 0.0
var _last_health: float = 0.0
var _flanked: bool = false
var _going: bool = false
var _retreated_at: float = -100.0
var _suppressing: float = 0.0
var _open_ground: bool = false
var _entered: float = 0.0


func enter(from: StringName) -> void:
	npc.stop()
	_entered = AIDirector.now()
	npc.director.set_engaged(npc, true)
	var surprised := from in [&"idle", &"patrol", &""]
	_reaction = npc.data.reaction_time * randf_range(0.8, 1.4) * lerpf(1.3, 0.8, npc.skill) * (1.4 if surprised else 0.85)
	_burst_left = 0
	_pause = 0.0
	_flanked = false
	spot = null
	_last_health = npc.health.current
	_saw = false
	# Now and then one just stands and fights where they are.
	_open_ground = randf() < (1.0 - npc.skill) * 0.15
	npc.director.report_contact(npc, npc.perception.last_known_position)
	_decide_now()


func exit() -> void:
	if npc.weapon:
		npc.weapon.set_trigger(false)
	npc.director.set_engaged(npc, false)
	npc.set_crouch(false)
	npc.clear_face()


func update(delta: float) -> void:
	var p := npc.perception
	var player := p.target()
	var weapon := npc.weapon
	if player == null:
		if weapon:
			weapon.set_trigger(false)
		brain.change(&"patrol" if not npc.patrol_points.is_empty() else &"idle")
		return
	if weapon == null:
		return
	# In a fight any glimpse counts: they know someone's there.
	var sees := p.can_see_target
	var threat_eye := player.head.global_position if sees else p.last_known_position + Vector3.UP * 1.6
	var threat_aim := player.center_mass() if sees else p.last_known_position + Vector3.UP * 1.2

	# Seeing them again: a beat to react, wider first shots if the gun was
	# pointed elsewhere.
	if sees and not _saw:
		var aim_dir := -npc.global_basis.z
		var to := (player.global_position - npc.global_position).normalized()
		var off := rad_to_deg(aim_dir.angle_to(to))
		npc.unsettle(clampf(off / 40.0, 0.0, 1.0))
		_reaction = maxf(_reaction, npc.data.reaction_time * randf_range(0.3, 0.8) * clampf(off / 45.0, 0.3, 1.0))
	_saw = sees
	if sees:
		_share -= delta
		if _share <= 0.0:
			_share = randf_range(1.5, 3.0)
			npc.director.report_contact(npc, player.global_position)
	var holding := not npc.is_moving() and (tactic == Tactic.ENGAGE)
	var lateral := (player.velocity - player.velocity.project(player.global_position - npc.global_position)).length() if sees else 0.0
	npc.track(delta, (sees or holding) and not npc.is_moving() and lateral < 2.5)

	# Lost them for a while: go and look.
	if not sees and p.seconds_since_known() > lerpf(9.0, 5.0, npc.aggression):
		brain.change(&"search")
		return

	# Hit: get the head down.
	if npc.health.current < _last_health:
		_last_health = npc.health.current
		if _peeking and tactic == Tactic.ENGAGE:
			_hide()
		if npc.health.ratio() < npc.data.retreat_health:
			_decide = 0.0

	if _handle_reload(sees, weapon):
		return

	_decide -= delta
	if _decide <= 0.0:
		_decide_now()
		_decide = randf_range(1.6, 3.0)

	match tactic:
		Tactic.TAKE_COVER:
			_take_cover(delta, sees, threat_eye, threat_aim)
		Tactic.ENGAGE:
			_engage(delta, sees, threat_eye, threat_aim)
		Tactic.FLANK:
			_move_phase(delta, sees, threat_aim, false)
			if _going and npc.arrived():
				_flanked = true
				_arrive_at_cover()
		Tactic.PUSH:
			_move_phase(delta, sees, threat_aim, true)
			# Face to face in the open: stop and fight it out.
			if sees and npc.global_position.distance_to(player.global_position) < 10.0:
				npc.stop()
			if _going and npc.arrived():
				if sees:
					_arrive_at_cover()
				else:
					brain.change(&"search")
		Tactic.RETREAT:
			_move_phase(delta, sees, threat_aim, false)
			if _going and npc.arrived():
				_arrive_at_cover()


# --- Choosing ---------------------------------------------------------------------

func _decide_now() -> void:
	var p := npc.perception
	var player := p.target()
	if player == null:
		return
	var threat_eye := player.head.global_position if p.can_see_target else p.last_known_position + Vector3.UP * 1.6
	var hr := npc.health.ratio()
	var allies := npc.director.engaged_count() - 1
	var dist := npc.global_position.distance_to(p.last_known_position)
	var morale := hr * 0.7 + npc.aggression * 0.4 + mini(allies, 2) * 0.12 - npc.suppression * 0.35 \
		- npc.director.recent_deaths(npc.global_position) * 0.25
	var role := npc.director.role_of(npc)
	if (hr < npc.data.retreat_health and morale < 0.6 or morale < 0.2) and AIDirector.now() - _retreated_at > 12.0:
		_retreated_at = AIDirector.now()
		_start_move(Tactic.RETREAT, Tactics.find(npc, threat_eye, {"min_r": 6.0, "max_r": 20.0, "away": true, "need_shot": false}), true)
		Events.ai_callout.emit(npc, &"retreat")
		return
	if npc.director.player_vulnerable() and npc.aggression > 0.35 and dist < 25.0 and p.seconds_since_known() < 4.0:
		_push(threat_eye)
		return
	if role == AIDirector.ROLE_FLANK and not _flanked and allies >= 1 and tactic != Tactic.FLANK:
		var to := (npc.global_position - p.last_known_position)
		to.y = 0.0
		var side := to.normalized().cross(Vector3.UP) * (1.0 if randf() < 0.5 else -1.0)
		var s := Tactics.find(npc, threat_eye, {"min_r": 6.0, "max_r": 22.0, "want_range": 9.0, "flank_dir": side})
		if s:
			_start_move(Tactic.FLANK, s, true)
			Events.ai_callout.emit(npc, &"flanking")
			return
	if tactic in [Tactic.FLANK, Tactic.PUSH, Tactic.RETREAT] and _going and not npc.arrived():
		return  # carry on
	if _open_ground:
		spot = null
		tactic = Tactic.ENGAGE
		return
	var compromised := spot != null and not Tactics.hidden(npc, threat_eye, spot.point + Vector3.UP * 0.85)
	var far_from_spot := spot != null and npc.global_position.distance_to(spot.point) > 2.0 and tactic == Tactic.ENGAGE
	if spot == null or compromised or far_from_spot:
		_take_new_cover(threat_eye)
		return
	if p.seconds_since_seen() > 3.5 and p.seconds_since_known() > 3.5 and npc.aggression > 0.55 \
			and role != AIDirector.ROLE_HOLD and AIDirector.now() - _entered > 5.0:
		_push(threat_eye)
		return
	# Every so often, move to fresh cover rather than peek from the same spot.
	_since_move += 2.0
	if _since_move > randf_range(14.0, 22.0):
		_take_new_cover(threat_eye)


func _take_new_cover(threat_eye: Vector3) -> void:
	var want := npc.data.preferred_range * (0.8 if npc.weapon and npc.weapon.data.length < 0.6 else 1.0)
	var s := Tactics.find(npc, threat_eye, {"want_range": want})
	if s == null:
		s = Tactics.find(npc, threat_eye, {"want_range": want, "need_shot": false, "max_r": npc.data.cover_radius * 1.3})
	_start_move(Tactic.TAKE_COVER, s, true)


## Close in: to cover nearer the player if there is some, else straight up
## to a few metres short of where they were last known.
func _push(threat_eye: Vector3) -> void:
	var p := npc.perception
	var lk := p.last_known_position
	var here := npc.global_position.distance_to(lk)
	var s := Tactics.find(npc, threat_eye, {"want_range": 6.0, "max_r": 12.0})
	if s and s.point.distance_to(lk) < here - 3.0:
		_start_move(Tactic.PUSH, s, true)
		return
	if here < 9.0:
		_take_new_cover(threat_eye)
		return
	var t := Tactics.Spot.new()
	var map := npc.get_world_3d().navigation_map
	t.point = NavigationServer3D.map_get_closest_point(map, lk + (npc.global_position - lk).normalized() * 6.0)
	t.kind = Tactics.DEEP
	t.peek = t.point
	_start_move(Tactic.PUSH, t, true)


func _start_move(kind: Tactic, s: Tactics.Spot, run: bool) -> void:
	tactic = kind
	_since_move = 0.0
	if s == null:
		spot = null
		_going = false
		tactic = Tactic.ENGAGE
		npc.set_crouch(npc.aggression < 0.5)
		return
	spot = s
	npc.director.reserve(npc, s.point)
	npc.set_crouch(false)
	npc.move_to(s.point, run)
	_going = true
	_peeking = false


func _arrive_at_cover() -> void:
	tactic = Tactic.ENGAGE
	_going = false
	_hide()


# --- Doing ------------------------------------------------------------------------

func _take_cover(delta: float, sees: bool, threat_eye: Vector3, threat_aim: Vector3) -> void:
	if spot == null:
		tactic = Tactic.ENGAGE
		return
	_move_phase(delta, sees, threat_aim, npc.aggression > 0.55)
	if npc.arrived():
		_arrive_at_cover()


## On the move: bold ones face the player and fire as they go (badly); others
## run eyes front and only fire at close range.
func _move_phase(delta: float, sees: bool, threat_aim: Vector3, run_and_gun: bool) -> void:
	var close := sees and npc.global_position.distance_to(threat_aim) < 9.0
	if sees and (run_and_gun or close):
		npc.face(threat_aim)
		npc.aim_at(threat_aim + _aim_offset, true)
		_fire(delta)
	else:
		npc.clear_face()
		npc.weapon.set_trigger(false)
		npc.aim_at(npc.global_position - npc.global_basis.z * 6.0 + Vector3.UP * 1.3, sees)


func _engage(delta: float, sees: bool, threat_eye: Vector3, threat_aim: Vector3) -> void:
	npc.face(threat_aim)
	_phase -= delta
	_check -= delta
	if spot and _check <= 0.0:
		_check = 0.5
		var head := spot.point + Vector3.UP * (0.85 if spot.kind == Tactics.LOW else 1.55)
		if not _peeking and not Tactics.hidden(npc, threat_eye, head):
			_decide = 0.0  # flanked: this cover is no good now
	if spot == null:
		# In the open: fight from where they stand, crouched if cautious.
		npc.aim_at(threat_aim + _aim_offset, true)
		if sees:
			_fire(delta)
		else:
			_suppress(delta)
		return
	if not _peeking:
		npc.aim_at(threat_aim, spot.kind != Tactics.LOW)
		npc.weapon.set_trigger(false)
		if _phase <= 0.0:
			if spot.kind == Tactics.DEEP:
				_decide = 0.0  # no shot from here: find somewhere better
				_phase = 1.0
			else:
				_peek()
		return
	# Peeking.
	npc.aim_at(threat_aim + _aim_offset, true)
	if sees:
		_fire(delta)
	else:
		_suppress(delta)
	if _phase <= 0.0 or npc.suppression > 0.65:
		_hide()


func _hide() -> void:
	_peeking = false
	npc.weapon.set_trigger(false)
	_phase = randf_range(0.8, 2.0) + npc.suppression * 2.5 - npc.aggression * 0.5
	if spot == null:
		return
	if spot.kind == Tactics.SIDE:
		npc.set_crouch(false)
		npc.move_to(spot.point, false)
	else:
		npc.set_crouch(true)
	if npc.suppression > 0.6 and randf() < 0.3:
		Events.ai_callout.emit(npc, &"suppressed")


func _peek() -> void:
	_peeking = true
	_phase = randf_range(1.6, 3.4) + npc.aggression
	if spot.kind == Tactics.SIDE:
		npc.set_crouch(false)
		npc.move_to(spot.peek, false)
	else:
		# Low cover: some stand to shoot over it, the careful ones stay low and peek round.
		npc.set_crouch(false)


## Rounds on where the player was, to keep their head down while mates move.
func _suppress(delta: float) -> void:
	var p := npc.perception
	var role := npc.director.role_of(npc)
	var keen := role == AIDirector.ROLE_HOLD or npc.aggression > 0.6
	var weapon := npc.weapon
	var ammo_ok := weapon.loaded_rounds() > weapon.data.magazine_size * 0.35
	if keen and ammo_ok and p.seconds_since_seen() < 5.0 and p.seconds_since_seen() > 0.6 \
			and weapon.data.fire_modes.has(WeaponData.FireMode.AUTO):
		_suppressing -= delta
		if _suppressing <= 0.0:
			_suppressing = randf_range(2.0, 4.0)
			_aim_offset = Vector3(randf_range(-1, 1), randf_range(-0.3, 0.6), randf_range(-1, 1)) * 0.8
		if _suppressing > 1.5:
			_fire(delta)
			return
	weapon.set_trigger(false)


## Bursts: longer up close, single aimed shots far off; each burst picks a new
## aim offset that shrinks as the burst walks in.
func _fire(delta: float) -> void:
	var weapon := npc.weapon
	if _reaction > 0.0:
		_reaction -= delta
		weapon.set_trigger(false)
		return
	if _pause > 0.0:
		_pause -= delta
		weapon.set_trigger(false)
		return
	var player := npc.perception.target()
	var dist := npc.global_position.distance_to(player.global_position) if player else 20.0
	if _burst_left <= 0:
		var lo := npc.data.burst_min
		var hi := npc.data.burst_max
		if dist > 25.0:
			lo = 1
			hi = maxi(2, hi / 2)
		elif dist < 8.0:
			lo += 1
			hi += 2
		_burst_left = randi_range(lo, hi)
		_aim_offset = Vector3(randf_range(-1, 1), randf_range(-0.6, 0.8), randf_range(-1, 1)) * lerpf(0.5, 0.2, npc.skill)
	var auto := weapon.current_mode() == WeaponData.FireMode.AUTO
	if auto:
		var before := weapon.loaded_rounds()
		weapon.set_trigger(true)
		if weapon.loaded_rounds() < before:
			_burst_left -= 1
			_aim_offset *= 0.8
	else:
		_pulse -= delta
		if _pulse <= 0.0:
			weapon.set_trigger(true)
			_pulse = maxf(weapon.data.time_between_shots(), 0.25) * randf_range(1.0, 1.6)
			_burst_left -= 1
		else:
			weapon.set_trigger(false)
	if _burst_left <= 0:
		weapon.set_trigger(false)
		_pause = npc.data.burst_pause * randf_range(0.7, 1.4) * (1.5 if dist > 25.0 else 1.0)


## Empty: reload, in cover if there's time. Low and out of sight: top up.
## Returns true while busy with it.
func _handle_reload(sees: bool, weapon: Weapon) -> bool:
	if weapon.is_busy():
		weapon.set_trigger(false)
		return true
	var empty := weapon.loaded_rounds() == 0
	var low := weapon.loaded_rounds() < weapon.data.magazine_size * 0.3
	if empty or (low and not sees and not _peeking):
		weapon.set_trigger(false)
		if empty and _peeking and randf() > (1.0 - npc.skill) * 0.4:
			_hide()  # duck first, most of the time
		weapon.reload()
		Events.ai_callout.emit(npc, &"reloading")
		return true
	return false
