class_name AIDirector
extends Node
## What the NPCs of a level share: who has seen the player where, callouts
## passed on to mates in earshot (with a moment's delay, never instantly), who
## is engaged and in what role (most hold and fight from cover, one in a few
## flanks), which cover spots are taken, and the openings a real opponent
## would notice: the player reloading within earshot, or just hit.
##
## Nothing here is cheating: an NPC only learns where the player is from its
## own senses or a mate's callout, and callouts carry what that mate knew.

const ROLE_FIGHT := &"fight"
const ROLE_FLANK := &"flank"
const ROLE_HOLD := &"hold"

var npcs: Array[NPC] = []
var roles: Dictionary = {}  # NPC -> StringName
var engaged: Dictionary = {}  # NPC -> engaged since (s)
var _reserved: Dictionary = {}  # NPC -> Vector3
var _deaths: Array = []  # [position, time]
var _reloading_until: float = -100.0
var _player_hit_time: float = -100.0


static var _current: AIDirector


## The director for the level `node` is in (made on first use; it goes with
## the level).
static func of(node: Node) -> AIDirector:
	if is_instance_valid(_current) and not _current.is_queued_for_deletion():
		return _current
	var d := AIDirector.new()
	d.name = "AIDirector"
	d.add_to_group(&"ai_director")
	node.get_parent().add_child.call_deferred(d)
	# Usable straight away; it joins the tree at the end of the frame.
	d._init_signals()
	_current = d
	return d


func _init_signals() -> void:
	if not Events.actor_reloading.is_connected(_on_reloading):
		Events.actor_reloading.connect(_on_reloading)
		Events.actor_damaged.connect(_on_damaged)


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func register(npc: NPC) -> void:
	if npc not in npcs:
		npcs.append(npc)


func alive_npcs() -> Array[NPC]:
	var out: Array[NPC] = []
	for n in npcs:
		if is_instance_valid(n) and n.alive:
			out.append(n)
	return out


# --- Knowledge ----------------------------------------------------------------

## `from` saw (or heard for sure) the player at `pos`: mates within earshot get
## it a moment later, as long as they're not already better informed.
func report_contact(from: NPC, pos: Vector3, kind: StringName = &"contact") -> void:
	for n in alive_npcs():
		if n == from:
			continue
		var d := n.global_position.distance_to(from.global_position)
		if d > from.data.callout_range:
			continue
		var delay := randf_range(0.4, 1.2) + d * 0.02
		(Engine.get_main_loop() as SceneTree).create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(n) and n.alive:
				n.perception.receive_report(pos, from.perception.last_known_time))
	Events.ai_callout.emit(from, kind)


## A mate went down near `pos` (killed from `killer_pos` if known).
func report_death(npc: NPC, killer_pos: Vector3) -> void:
	_deaths.append([npc.global_position, now()])
	roles.erase(npc)
	engaged.erase(npc)
	_reserved.erase(npc)
	for n in alive_npcs():
		var d := n.global_position.distance_to(npc.global_position)
		if d < 22.0 and (d < 8.0 or n.perception.line_of_sight(npc.global_position + Vector3.UP * 1.0)):
			n.perception.receive_report(killer_pos if killer_pos != Vector3.INF else npc.global_position, now())
	Events.ai_callout.emit(npc, &"man_down")


## Mates down within `radius` of `pos` in the last `seconds`.
func recent_deaths(pos: Vector3, radius: float = 20.0, seconds: float = 30.0) -> int:
	var c := 0
	for e in _deaths:
		if now() - float(e[1]) < seconds and pos.distance_to(e[0]) < radius:
			c += 1
	return c


# --- Roles and cover ------------------------------------------------------------

func set_engaged(npc: NPC, on: bool) -> void:
	if on:
		if not engaged.has(npc):
			engaged[npc] = now()
		_assign_roles()
	else:
		engaged.erase(npc)
		roles.erase(npc)
		_reserved.erase(npc)


func engaged_count() -> int:
	var c := 0
	for n: NPC in engaged.keys():
		if is_instance_valid(n) and n.alive:
			c += 1
	return c


func role_of(npc: NPC) -> StringName:
	return roles.get(npc, ROLE_FIGHT)


## About one in three engaged flanks (the boldest), one holds the angle,
## the rest fight from cover. Re-dealt as people join, die or leave.
func _assign_roles() -> void:
	var list: Array = []
	for n: NPC in engaged.keys():
		if is_instance_valid(n) and n.alive:
			list.append(n)
	list.sort_custom(func(a: NPC, b: NPC) -> bool: return a.aggression > b.aggression)
	roles.clear()
	var flankers := int(list.size() / 3.0 + 0.34) if list.size() >= 2 else 0
	for i in list.size():
		var n: NPC = list[i]
		if i < flankers and n.aggression > 0.25:
			roles[n] = ROLE_FLANK
		elif i == list.size() - 1 and list.size() >= 3:
			roles[n] = ROLE_HOLD
		else:
			roles[n] = ROLE_FIGHT


func reserve(npc: NPC, point: Vector3) -> void:
	_reserved[npc] = point


func release(npc: NPC) -> void:
	_reserved.erase(npc)


## How crowded a spot is: mates standing or headed within `radius` of it.
func crowding(point: Vector3, by: NPC, radius: float = 2.6) -> int:
	var c := 0
	for n in alive_npcs():
		if n == by:
			continue
		if n.global_position.distance_to(point) < radius:
			c += 1
		elif _reserved.has(n) and (_reserved[n] as Vector3).distance_to(point) < radius:
			c += 1
	return c


# --- Openings -------------------------------------------------------------------

## The player is reloading where someone could hear it, or was just hit.
func player_vulnerable() -> bool:
	return now() < _reloading_until or now() - _player_hit_time < 1.5


func _on_reloading(actor: Node) -> void:
	if not actor is Player:
		return
	var p := actor as Player
	var heard := false
	for n in alive_npcs():
		if engaged.has(n) and n.global_position.distance_to(p.global_position) < 18.0 * n.data.hearing_multiplier:
			# The rattle of a magazine gives away where they are, too.
			n.perception.receive_report(p.global_position, now())
			heard = true
	if heard:
		_reloading_until = now() + 2.2
		Events.ai_callout.emit(alive_npcs()[0], &"reloading")


func _on_damaged(victim: Node, _hit: HitInfo) -> void:
	if victim is Player:
		_player_hit_time = now()
