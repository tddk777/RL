class_name Tactics
extends RefCounted
## Picks where an NPC should go: cover from a threat, a flanking spot, a way
## back. Spots are sampled in rings round the NPC, snapped to the navmesh and
## tested with rays from where the threat's eyes are:
##   low cover   hidden crouched, can stand up to shoot over it
##   side cover  hidden standing, a step to the side clears it to shoot
##   deep cover  hidden, no shot from it (for reloading, hiding, falling back)
## and scored on protection, distance to walk, range to the threat, crowding
## (mates and their reserved spots), how exposed the walk there is, and for a
## flank how far round the threat's side it gets.

const LOW := &"low"
const SIDE := &"side"
const DEEP := &"deep"


class Spot:
	var point: Vector3
	var kind: StringName
	## Where to stand to shoot (the spot itself for low cover).
	var peek: Vector3
	var score: float


## opts: min_r, max_r (from the NPC), want_range (to the threat), flank_dir
## (unit vector from the threat toward where to get round to; ZERO for none),
## away (retreat: further from the threat is better), need_shot (must be
## able to shoot from it).
static func find(npc: NPC, threat_eye: Vector3, opts: Dictionary) -> Spot:
	var space := npc.get_world_3d().direct_space_state
	var map := npc.get_world_3d().navigation_map
	var origin := npc.global_position
	var min_r: float = opts.get("min_r", 1.5)
	var max_r: float = opts.get("max_r", npc.data.cover_radius)
	var want: float = opts.get("want_range", npc.fight_range())
	var flank: Vector3 = opts.get("flank_dir", Vector3.ZERO)
	var away: bool = opts.get("away", false)
	var need_shot: bool = opts.get("need_shot", true)
	var director := AIDirector.of(npc)
	var threat := Vector3(threat_eye.x, threat_eye.y - 1.5, threat_eye.z)
	var best: Spot = null
	var rings: Array[float] = []
	var r := maxf(min_r, 2.0)
	while r <= max_r + 0.01:
		rings.append(r)
		r += 2.6
	var turn := randf() * TAU  # not always the same spots in the same order
	for ring in rings:
		var count := 10 if ring < 6.0 else 14
		for i in count:
			var a := turn + TAU * i / count
			var want_p := origin + Vector3(cos(a), 0.0, sin(a)) * ring
			var p := NavigationServer3D.map_get_closest_point(map, want_p + Vector3.UP * 0.5)
			if p.distance_to(want_p) > 1.6 or absf(p.y - origin.y) > 1.2:
				continue
			var spot := _classify(space, npc, threat_eye, p)
			if spot == null or (need_shot and spot.kind == DEEP):
				continue
			var to_threat := Vector3(threat.x - p.x, 0.0, threat.z - p.z).length()
			if to_threat < 4.0:
				continue
			var s := 0.0
			s -= origin.distance_to(p) * 0.35
			if away:
				s += (to_threat - origin.distance_to(threat)) * 0.5
			else:
				s -= absf(to_threat - want) * 0.25
			s += {LOW: 2.0, SIDE: 2.5, DEEP: 0.5}[spot.kind]
			s -= director.crowding(p, npc) * 6.0
			if flank != Vector3.ZERO:
				var dir := Vector3(p.x - threat.x, 0.0, p.z - threat.z).normalized()
				s += dir.dot(flank) * 10.0
			# The walk there: penalise crossing open ground in the threat's view.
			var mid := origin.lerp(p, 0.5) + Vector3.UP * 1.2
			if _clear(space, npc, threat_eye, mid):
				s -= 2.0 if not away else 3.5
			s += randf_range(-0.6, 0.6)
			spot.score = s
			if best == null or s > best.score:
				best = spot
	return best


## A spot's kind of cover from the threat, or null if it has none.
static func _classify(space: PhysicsDirectSpaceState3D, npc: NPC, threat_eye: Vector3, p: Vector3) -> Spot:
	var head := p + Vector3.UP * 1.55
	var low := p + Vector3.UP * 0.85
	var head_clear := _clear(space, npc, threat_eye, head)
	var low_clear := _clear(space, npc, threat_eye, low)
	if low_clear:
		return null  # crouching doesn't hide you there
	var spot := Spot.new()
	spot.point = p
	if head_clear:
		spot.kind = LOW
		spot.peek = p
		return spot
	# Hidden standing: a step to either side to get a shot?
	var to := Vector3(threat_eye.x - p.x, 0.0, threat_eye.z - p.z).normalized()
	var side := to.cross(Vector3.UP)
	for e: float in [1.0, -1.0, 1.5, -1.5]:
		var q := p + side * e
		var ray := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.0, q + Vector3.UP * 1.0, Layers.WORLD)
		if not space.intersect_ray(ray).is_empty():
			continue
		if _clear(space, npc, threat_eye, q + Vector3.UP * 1.55):
			spot.kind = SIDE
			spot.peek = q
			return spot
	spot.kind = DEEP
	spot.peek = p
	return spot


static func _clear(space: PhysicsDirectSpaceState3D, npc: NPC, from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.SIGHT_MASK, npc.exclude_rids())
	return space.intersect_ray(q).is_empty()


## Is `point` hidden from the threat (for "is my cover still cover")?
static func hidden(npc: NPC, threat_eye: Vector3, point: Vector3) -> bool:
	return not _clear(npc.get_world_3d().direct_space_state, npc, threat_eye, point)


## A walkable point near `centre` (for searching), or `centre` if none.
static func random_near(npc: NPC, centre: Vector3, radius: float) -> Vector3:
	var map := npc.get_world_3d().navigation_map
	for i in 6:
		var a := randf() * TAU
		var want := centre + Vector3(cos(a), 0.0, sin(a)) * randf_range(radius * 0.4, radius)
		var p := NavigationServer3D.map_get_closest_point(map, want + Vector3.UP * 0.5)
		if p.distance_to(want) < 2.0 and absf(p.y - centre.y) < 1.5:
			return p
	return centre
