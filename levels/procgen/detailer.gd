class_name Detailer
extends RefCounted
## The second dressing pass, run on every dressed cell after its set pieces:
## details that follow from how the cell meets its neighbours, so they come
## out right whatever the layout does (the Townscaper / Tiny Glade idea).
##
## - Signs: plates naming the room behind each door, the sector letter and
##   name where one building opens into another, EXIT signs on the way out
##   (from the exit distance field), storey numbers in stairwells, hazard
##   labels at plant rooms.
## - Walls: every free run of wall is filled from the room's own kit, floor
##   pieces first, then things hung on the wall above them. No bare walls.
## - Corners: inside corners get a riser pipe or a drift of debris.
## - Services: pipes and cables run the length of every cramped passage, a
##   steady height and side so they join cell to cell, with risers where two
##   runs turn, and a conduit along the walls of plant rooms and workshops.
## - Floors: a sector-coloured line down each passage, walkway lines round
##   the factory floors.
##
## Reads only the layout and the chunk's own `taken` list; runs on worker
## threads like SetPieces.

const UP := Vector3.UP
const FACE := 0.15  # wall face, in from the edge line (half of ChunkBuilder.T)
## Hung things stand this far proud of where their numbers say, so their
## faces never land on the round depths the wall trim uses (flicker).
const NUDGE := 0.0037
const LETTERS := "ABCDEFGH"
## Zone types with a sector name decal (see dev/asset_gen/signs.py).
const SECTOR_TYPES: Array[StringName] = [&"hall", &"foundry", &"warehouse", &"loading_dock", &"processing", &"office",
	&"maintenance", &"storage"]
## Room uses with a door plate.
const PLATES: Array[StringName] = [&"offices", &"cubicles", &"meeting", &"archive", &"boiler", &"electrical", &"lockers",
	&"washroom", &"workshop", &"parts", &"cages", &"pumps", &"vats", &"lab", &"stairwell", &"closet"]
## Sector paint (stripes, bands) by sector index.
const PAINT: Array[StringName] = [&"painted_steel_yellow", &"painted_steel_blue", &"painted_steel_green",
	&"painted_steel_red", &"painted_steel"]
const POSTERS := 6

## Floor pieces against the wall, by room use or zone type: id -> weight.
const FLOOR_KITS := {
	&"parts": {"shelf": 5.0, "cabinet": 1.0, "crates": 1.0, "boxes": 1.5},
	&"cages": {"shelf": 3.0, "crates": 2.0, "drums": 1.0, "boxes": 1.0},
	&"archive": {"shelf": 3.0, "cabinet": 4.0, "boxes": 1.5},
	&"workshop": {"bench": 4.0, "shelf": 2.0, "cabinet": 1.0, "gas": 1.0, "drums": 0.5},
	&"closet": {"shelf": 3.0, "mop": 2.0, "boxes": 2.0},
	&"lockers": {"lockers": 5.0, "bench_seat": 2.0},
	&"boiler": {"manifold": 3.0, "drums": 1.0, "gas": 1.0, "electrical": 1.0},
	&"pumps": {"manifold": 3.0, "drums": 1.5, "electrical": 1.0},
	&"vats": {"manifold": 2.0, "drums": 2.0, "shelf": 1.0},
	&"electrical": {"electrical": 5.0, "cabinet": 1.0},
	&"lab": {"bench": 3.0, "cabinet": 2.0, "shelf": 1.0},
	&"offices": {"cabinet": 3.0, "desk": 2.0, "shelf": 1.0, "bin": 1.0},
	&"cubicles": {"cabinet": 3.0, "bin": 1.0, "shelf": 1.0},
	&"meeting": {"cabinet": 1.0, "bin": 1.0, "cooler": 1.0},
	&"washroom": {"bin": 1.0},
	&"stash": {"crates": 1.0, "boxes": 1.0},
	&"hall": {"bench": 2.0, "cabinet": 1.0, "drums": 2.0, "gas": 1.0, "shelf": 1.5, "pallet": 1.5, "electrical": 1.0},
	&"foundry": {"drums": 2.0, "pallet": 2.0, "gas": 1.0, "bench": 1.0},
	&"warehouse": {"pallet": 3.0, "crates": 2.0, "drums": 1.0},
	&"loading_dock": {"pallet": 3.0, "crates": 2.0, "drums": 1.0},
	&"processing": {"manifold": 2.0, "drums": 2.0, "electrical": 1.0, "bench": 1.0},
	&"corridor": {"bench_seat": 1.0, "bin": 1.0, "vending": 0.6, "cooler": 0.6, "electrical": 0.8},
}
## Fraction of each free wall run the floor pieces fill.
const FILL := {
	&"parts": 0.8, &"cages": 0.6, &"archive": 0.8, &"workshop": 0.7, &"closet": 0.8, &"lockers": 0.8,
	&"boiler": 0.6, &"pumps": 0.6, &"vats": 0.5, &"electrical": 0.8, &"lab": 0.7, &"offices": 0.5,
	&"cubicles": 0.35, &"meeting": 0.3, &"washroom": 0.15, &"stash": 0.4, &"hall": 0.55, &"foundry": 0.45,
	&"warehouse": 0.4, &"loading_dock": 0.4, &"processing": 0.55, &"corridor": 0.3,
}
## Things hung on the wall, by room use or zone type.
const HUNG_KITS := {
	&"parts": {"shelf_wall": 1.0, "fuse": 1.0, "notice": 0.5},
	&"cages": {"fuse": 1.0, "hazard": 0.5, "notice": 0.5},
	&"archive": {"notice": 1.0, "clock": 0.5, "poster": 0.5},
	&"workshop": {"pegboard": 3.0, "fuse": 1.0, "poster": 1.0, "first_aid": 0.5, "shelf_wall": 1.0},
	&"closet": {"shelf_wall": 2.0, "hooks": 1.0},
	&"lockers": {"hooks": 2.0, "notice": 1.0, "poster": 1.0, "mirror": 1.0},
	&"boiler": {"valve": 3.0, "gauges": 2.0, "fuse": 1.0, "hazard": 0.5},
	&"pumps": {"valve": 3.0, "gauges": 2.0, "fuse": 1.0},
	&"vats": {"valve": 2.0, "gauges": 2.0, "hazard": 0.5},
	&"electrical": {"fuse": 4.0, "hazard": 1.0},
	&"lab": {"whiteboard": 1.0, "shelf_wall": 2.0, "first_aid": 1.0, "clock": 0.5},
	&"offices": {"notice": 1.0, "whiteboard": 1.0, "clock": 1.0, "poster": 0.5, "shelf_wall": 1.0},
	&"cubicles": {"notice": 1.0, "clock": 1.0, "poster": 1.0, "whiteboard": 0.5},
	&"meeting": {"whiteboard": 2.0, "clock": 1.0, "notice": 0.5},
	&"washroom": {"mirror": 2.0},
	&"hall": {"fuse": 2.0, "poster": 1.0, "first_aid": 0.5, "pegboard": 0.5, "hazard": 0.5},
	&"foundry": {"fuse": 1.0, "hazard": 1.0, "valve": 1.0},
	&"warehouse": {"fuse": 1.0, "poster": 0.5},
	&"loading_dock": {"fuse": 1.0, "poster": 0.5},
	&"processing": {"valve": 2.0, "gauges": 2.0, "fuse": 1.0, "hazard": 0.5},
	&"corridor": {"notice": 1.0, "poster": 1.0, "first_aid": 0.5, "phone": 0.5, "fuse": 1.0, "clock": 0.3},
}
## Floor pieces: [width along the wall, depth].
const FLOOR_SIZES := {
	"shelf": [2.1, 0.65], "cabinet": [0.5, 0.65], "lockers": [1.56, 0.5], "electrical": [0.9, 0.4],
	"bench": [2.0, 0.8], "crates": [1.1, 1.0], "drums": [1.3, 0.65], "desk": [1.4, 1.2], "bench_seat": [1.6, 0.4],
	"bin": [0.45, 0.45], "vending": [0.9, 0.8], "cooler": [0.4, 0.4], "manifold": [1.4, 0.45], "gas": [1.1, 0.35],
	"pallet": [1.25, 1.05], "mop": [0.7, 0.5], "boxes": [0.9, 0.6],
}
## Hung things: [width, bottom, top, depth].
const HUNG_SIZES := {
	"notice": [1.2, 1.2, 2.0, 0.035], "whiteboard": [1.8, 0.97, 2.1, 0.04], "pegboard": [1.4, 1.1, 2.0, 0.03],
	"fuse": [0.45, 1.35, 1.95, 0.16], "first_aid": [0.42, 1.4, 1.85, 0.12], "clock": [0.36, 2.0, 2.36, 0.06],
	"poster": [0.55, 1.3, 2.07, 0.0], "hazard": [0.5, 1.5, 1.83, 0.0], "valve": [0.6, 1.03, 1.8, 0.35],
	"gauges": [0.9, 1.2, 1.9, 0.12], "hooks": [1.2, 1.5, 1.95, 0.12], "shelf_wall": [1.3, 1.55, 1.95, 0.32],
	"mirror": [0.7, 1.15, 1.85, 0.02], "phone": [0.3, 1.3, 1.6, 0.1], "radiator": [1.1, 0.15, 0.75, 0.12],
	"extinguisher": [0.32, 0.85, 1.95, 0.2], "hose": [0.75, 0.8, 1.6, 0.22],
}
## On the walls of cramped passages.
const PASSAGE_KIT := {"notice": 1.0, "poster": 1.0, "fuse": 1.5, "first_aid": 0.4, "phone": 0.4, "extinguisher": 0.8,
	"hose": 0.4, "hazard": 0.3}

var sp: SetPieces
var cb: ChunkBuilder
var L: LevelLayout
var C: float
var H: float


func _init(pieces: SetPieces) -> void:
	sp = pieces
	cb = pieces.cb
	L = pieces.L
	C = pieces.C
	H = pieces.H


func detail(k: SetPieces.Cell) -> void:
	if k.zn.type in [&"yard", &"connector"] or L.kind_at(k.x, k.z, k.s) != LevelLayout.Kind.FLOOR:
		return
	if k.flags & LevelLayout.NARROW:
		_passage_signs(k)
		_passage_walls(k)
		_passage_services(k)
		_passage_stripe(k)
		return
	_door_signs(k)
	_stairwell_number(k)
	_corners(k)
	_wall_runs(k)
	_conduit(k)
	_walkway_lines(k)


# --- Sectors ----------------------------------------------------------------------------------

## Sector index of a zone: buildings are lettered A, B, C... in zone order.
func sector(zn: LevelLayout.Zone) -> int:
	var i := 0
	for z in L.zones:
		if z == zn:
			return i
		if z.type in SECTOR_TYPES:
			i += 1
	return i


func paint(zn: LevelLayout.Zone) -> StringName:
	return PAINT[sector(zn) % PAINT.size()]


# --- Decals on walls ---------------------------------------------------------------------------

## A decal on a wall face: `p` on the face, `inward` the face normal (into
## the room); reads left to right for someone facing the wall.
func wall_decal(k: SetPieces.Cell, tex: String, p: Vector3, inward: Vector3, w: float, h: float) -> void:
	if not k.d.geo.visuals:
		return
	var right := (-inward).cross(UP).normalized()
	var basis := Basis(right, inward, right.cross(inward))
	k.d.decals.append(["signs/" + tex, Transform3D(basis, p), Vector3(w, 0.3, h)])


func _span_point(s: ChunkBuilder.Span, a: float, out: float, y: float) -> Vector3:
	return s.origin + s.u * a + s.m * out + UP * y


## Reserves a box hung on a wall if nothing solid is there yet.
func _hung_free(k: SetPieces.Cell, center: Vector3, size: Vector3) -> bool:
	var ab := AABB(center - size * 0.5, size).grow(0.03)
	for t in k.d.taken:
		if t.intersects(ab):
			return false
	k.d.taken.append(ab)
	return true


# --- Doors: what's through them ------------------------------------------------------------------

func _door_signs(k: SetPieces.Cell) -> void:
	var here := L.idx(k.x, k.z, k.s)
	for dir in 4:
		if not L.has_door(k.x, k.z, k.s, dir):
			continue
		var n := Vector2i(k.x, k.z) + LevelLayout.DIRS[dir]
		if not L.is_walkable(n.x, n.y, k.s):
			continue
		var span := cb.edge_span(k.o, dir)
		var door := cb.door_span(k.x, k.z, k.s, dir)
		var dh := cb.door_height(k.x, k.z, k.s, n, k.st)
		var mid := (door.x + door.y) * 0.5
		var head := minf(dh + 0.32, cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s) - 0.2)
		var other_zone := L.zone_of(n.x, n.y, k.s)
		var other_room := L.room_of(n.x, n.y, k.s)
		var labelled := false
		# Way out: the next cell is nearer an exit.
		var ed := cb.exit_dist[here]
		var en := cb.exit_dist[L.idx(n.x, n.y, k.s)]
		if en >= 0 and (ed < 0 or en < ed):
			wall_decal(k, "exit", _span_point(span, mid, FACE, head + 0.05), span.m, 0.62, 0.24)
			labelled = true
		# The room behind the door.
		if not labelled and other_room and other_room != k.room and other_room.use in PLATES:
			wall_decal(k, "room_" + String(other_room.use), _span_point(span, mid, FACE, head), span.m, 1.1, 0.28)
			labelled = true
		# Into another building: its letter and name beside the door.
		if other_zone and other_zone != k.zn and other_zone.type in SECTOR_TYPES and door.x > 2.4:
			var letter := LETTERS[sector(other_zone) % LETTERS.length()]
			var a := door.x - 1.1
			if _hung_free(k, _span_point(span, a, FACE + 0.1, 2.05), Vector3(0.9, 1.4, 0.9)):
				wall_decal(k, "sector_" + letter, _span_point(span, a, FACE, 2.35), span.m, 0.85, 0.85)
				wall_decal(k, "sector_name_" + String(other_zone.type), _span_point(span, a, FACE, 1.72), span.m, 1.9, 0.3)
		# Hazard labels at plant rooms.
		if other_room and other_room.use in [&"electrical", &"boiler", &"pumps", &"cages", &"lab"] and door.y < C - 1.2:
			var tex: String = {&"electrical": "hazard_danger_hv", &"boiler": "hazard_ear_protection",
				&"pumps": "hazard_ear_protection", &"cages": "hazard_authorised", &"lab": "hazard_authorised"}[other_room.use]
			var a := door.y + 0.55
			if _hung_free(k, _span_point(span, a, FACE + 0.02, 1.65), Vector3(0.5, 0.4, 0.5)):
				wall_decal(k, tex, _span_point(span, a, FACE, 1.65), span.m, 0.48, 0.32)


## A big stencilled storey number on a stairwell wall.
func _stairwell_number(k: SetPieces.Cell) -> void:
	if not k.room or k.room.use != &"stairwell" or Vector2i(k.x, k.z) != k.room.rect.position:
		return
	for dir in 4:
		if sp._wall_free(k, dir):
			var span := cb.edge_span(k.o, dir)
			wall_decal(k, "storey_%d" % mini(k.s + 1, 5), _span_point(span, C * 0.5, FACE, 2.0), span.m, 1.5, 1.5)
			return


# --- Corners ---------------------------------------------------------------------------------

## Inside corners (two walls of this cell meeting): a riser pipe floor to
## ceiling, or the dust and rubbish that collects there.
func _corners(k: SetPieces.Cell) -> void:
	var hc := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H)
	var technical := k.zn.type in [&"maintenance", &"processing", &"hall", &"foundry", &"storage"] or \
		(k.room and k.room.use in [&"boiler", &"pumps", &"workshop", &"electrical", &"vats"])
	for c in 4:
		var dirs: Array = LevelLayout.CORNER_DIRS[c]
		if not (L.has_wall(k.x, k.z, k.s, dirs[0]) and L.has_wall(k.x, k.z, k.s, dirs[1])) or L.has_chamfer(k.x, k.z, k.s, c):
			continue
		if L.has_drop(k.x, k.z, k.s) and L.drop_corner(k.x, k.z, k.s) == c:
			continue
		var corner := cb._corner_point(c)
		var inward := Vector2(1.0 if corner.x < C * 0.5 else -1.0, 1.0 if corner.y < C * 0.5 else -1.0)
		var r := cb.rng(k.x, k.z, k.s, 300 + c)
		var at := func(off: float) -> Vector3:
			return k.o + Vector3(corner.x + inward.x * off, 0, corner.y + inward.y * off)
		if technical and r.randf() < 0.55:
			var p: Vector3 = at.call(FACE + 0.14)
			if sp._free(k, Rect2(p.x - k.o.x - 0.2, p.z - k.o.z - 0.2, 0.4, 0.4)) and _hung_free(k, p + UP * hc * 0.5, Vector3(0.3, hc, 0.3)):
				var rad := r.randf_range(0.06, 0.1)
				k.d.geo.cylinder(p, p + UP * hc, rad, &"rusted_metal", 10, false)
				for y: float in [0.6, 1.9, hc - 0.6]:
					k.d.geo.cylinder(p + UP * (y - 0.03), p + UP * (y + 0.03), rad + 0.025, &"rusted_metal", 10)  # flanges
				if r.randf() < 0.5:
					var v: Vector3 = p + Vector3(inward.x, 0, inward.y).normalized() * 0.12 + UP * 1.2
					k.d.geo.cylinder(p + UP * 1.2, v, 0.025, &"gun_metal", 6, false)
					k.d.geo.cylinder(v - Vector3(inward.x, 0, 0) * 0.08, v + Vector3(inward.x, 0, 0) * 0.08, 0.06, &"painted_steel_red", 10)
				continue
		if r.randf() < 0.6:
			# Drift of rubbish: grit, a few scraps, a crumpled sheet.
			for i in r.randi_range(3, 7):
				var off := r.randf_range(FACE + 0.06, FACE + 0.7)
				var side := r.randf_range(0.0, 0.5)
				var p: Vector3 = k.o + Vector3(corner.x + inward.x * (off + side * r.randf()), 0, corner.y + inward.y * (off + (0.5 - side) * r.randf()))
				var size := Vector3(r.randf_range(0.05, 0.22), r.randf_range(0.02, 0.08), r.randf_range(0.05, 0.2))
				sp.box(k, p + UP * size.y * 0.45, size, [&"concrete_dark", &"paper", &"soot", &"prop_rust"][r.randi_range(0, 3)],
					false, Basis.from_euler(Vector3(r.randf_range(-0.3, 0.3), r.randf() * TAU, r.randf_range(-0.3, 0.3))))


# --- Wall runs --------------------------------------------------------------------------------

## Free stretches (cell-local `along`) of the wall on `dir`, clear of doors,
## gaps and cut corners.
func _free_runs(k: SetPieces.Cell, dir: int) -> Array[Vector2]:
	var lo := FACE + 0.15
	var hi := C - FACE - 0.15
	if L.chamfer_at(k.x, k.z, k.s, dir, false) >= 0:
		lo = LevelLayout.CHAMFER_CUT + 0.3
	if L.chamfer_at(k.x, k.z, k.s, dir, true) >= 0:
		hi = C - LevelLayout.CHAMFER_CUT - 0.3
	var runs: Array[Vector2] = [Vector2(lo, hi)]
	var cut := func(a: float, b: float) -> void:
		var next: Array[Vector2] = []
		for r in runs:
			if b <= r.x or a >= r.y:
				next.append(r)
				continue
			if a > r.x:
				next.append(Vector2(r.x, a))
			if b < r.y:
				next.append(Vector2(b, r.y))
		runs.assign(next)  # (a lambda's locals are copies: change the array, don't rebind it)
	# Openings in this wall, whichever side's flags hold them.
	var n := Vector2i(k.x, k.z) + LevelLayout.DIRS[dir]
	var back := (dir + 2) % 4
	if L.has_door(k.x, k.z, k.s, dir):
		var d := cb.door_span(k.x, k.z, k.s, dir)
		cut.call(d.x - 0.45, d.y + 0.45)
	if L.inside(n.x, n.y, k.s) and L.has_door(n.x, n.y, k.s, back):
		var d := cb.door_span(n.x, n.y, k.s, back)
		cut.call(d.x - 0.45, d.y + 0.45)
	if L.has_gap(k.x, k.z, k.s, dir):
		var g := cb.gap_span(k.x, k.z, k.s, dir)
		cut.call(g.x - 0.6, g.y + 0.6)
	if L.inside(n.x, n.y, k.s) and L.has_gap(n.x, n.y, k.s, back):
		var g := cb.gap_span(n.x, n.y, k.s, back)
		cut.call(g.x - 0.6, g.y + 0.6)
	# Exits, levers and wall anomalies keep their stretch of wall.
	for e in L.exits:
		if e["cell"] == Vector3i(k.x, k.z, k.s) and e["dir"] == dir:
			cut.call(C * 0.5 - 1.6, C * 0.5 + 1.6)
		var lever: Dictionary = e["lever"]
		if not lever.is_empty() and lever["cell"] == Vector3i(k.x, k.z, k.s) and lever["dir"] == dir:
			cut.call(0.0, C)
	for a in L.anomalies:
		if a["cell"] == Vector3i(k.x, k.z, k.s) and a.get("dir", -1) == dir:
			cut.call(0.0, C)
	return runs.filter(func(r: Vector2) -> bool: return r.y - r.x > 0.4)


func _kit_key(k: SetPieces.Cell) -> StringName:
	if k.room and FLOOR_KITS.has(k.room.use):
		return k.room.use
	return k.zn.type


func _wall_runs(k: SetPieces.Cell) -> void:
	if k.zn.type in ChunkBuilder.TALL and k.s > 0:
		return
	if k.room and k.room.use in [&"stairwell", &"hallway"]:
		return
	var key := _kit_key(k)
	var floor_kit: Dictionary = FLOOR_KITS.get(key, {})
	var hung_kit: Dictionary = HUNG_KITS.get(key, HUNG_KITS.get(k.zn.type, {}))
	var fill: float = FILL.get(key, 0.3)
	var posters := 0
	for dir in 4:
		if not L.has_wall(k.x, k.z, k.s, dir) or L.stair_sides(k.x, k.z, k.s) & (1 << dir) \
				or (L.has_flag(k.x, k.z, k.s, LevelLayout.DOCK) and L.is_outside(k.x, k.z, k.s, dir)):
			continue
		var r := cb.rng(k.x, k.z, k.s, 310 + dir)
		var span := cb.edge_span(k.o, dir)
		var nb := Vector2i(k.x, k.z) + LevelLayout.DIRS[dir]
		var window := L.has_window(k.x, k.z, k.s, dir) or (L.inside(nb.x, nb.y, k.s) and L.has_window(nb.x, nb.y, k.s, (dir + 2) % 4))
		for run in _free_runs(k, dir):
			# Floor pieces along the run, leaving gaps.
			if not floor_kit.is_empty():
				var a := run.x + r.randf_range(0.0, 0.6)
				while a < run.y - 0.4:
					if r.randf() > fill:
						a += r.randf_range(0.6, 1.6)
						continue
					var id := sp._weighted(r, floor_kit)
					if window and id in ["shelf", "lockers", "vending", "manifold", "electrical", "cabinet"]:
						id = "bin" if r.randf() < 0.3 else "boxes"
					var size: Array = FLOOR_SIZES[id]
					var w: float = size[0]
					if a + w > run.y:
						a += 0.5
						continue
					if _floor_piece(k, span, dir, id, a + w * 0.5, w, size[1], r):
						a += w + r.randf_range(0.05, 0.5)
					else:
						a += 0.5
			# Under a window: a radiator in offices and passages.
			if window and k.zn.district == 1 and run.y - run.x > 1.4:
				_hung_piece(k, span, dir, "radiator", (run.x + run.y) * 0.5, r)
			# Hung things in the gaps between the floor pieces.
			if hung_kit.is_empty() or window:
				continue
			var b := run.x + r.randf_range(0.1, 0.9)
			while b < run.y - 0.3:
				var id := sp._weighted(r, hung_kit)
				if id == "poster" and posters >= 1:
					b += 0.6
					continue
				var hs: Array = HUNG_SIZES[id]
				var w: float = hs[0]
				if b + w > run.y:
					break
				if _hung_piece(k, span, dir, id, b + w * 0.5, r):
					if id == "poster":
						posters += 1
					b += w + r.randf_range(0.4, 1.6)
				else:
					b += 0.45


func _floor_piece(k: SetPieces.Cell, span: ChunkBuilder.Span, dir: int, id: String, a: float, w: float, depth: float,
		r: RandomNumberGenerator) -> bool:
	var A := span.u
	var N := span.m
	var base := _span_point(span, a, FACE, 0.0)
	var c := base + N * (depth * 0.5 + 0.03)
	if not sp._room_for(k, c, A, w, depth):
		return false
	var yaw := SetPieces._face_from_wall(dir)
	match id:
		"shelf":
			cb.kit(k.d, "shelf", base + N * 0.36, yaw)
		"cabinet":
			cb.kit(k.d, "filing_cabinet", base + N * 0.36, yaw)
		"lockers":
			for i in 3:
				cb.kit(k.d, "locker", base + N * 0.28 + A * ((i - 1) * 0.52), yaw)
		"electrical":
			cb.kit(k.d, "electrical_cabinet", base + N * 0.23, yaw)
			k.d.geo.cylinder(base + N * 0.1 + UP * 1.8, base + N * 0.1 + UP * minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H),
				0.04, &"gun_metal", 6, false)
		"bench":
			sp._workbench(k, base + N * 0.45, A, N)
		"crates":
			cb.kit(k.d, "crate_wood", c, yaw + r.randf_range(-0.1, 0.1))
			if r.randf() < 0.4:
				cb.kit(k.d, "crate_small", c + UP * 0.8, r.randf() * TAU)
		"drums":
			for e: float in [-0.32, 0.32]:
				cb.kit(k.d, ["barrel_rust", "barrel_blue", "barrel_orange"][r.randi_range(0, 2)], c + A * e, r.randf() * TAU)
		"desk":
			cb.kit(k.d, "desk", base + N * 0.38, yaw)
			sp._chair(k, base + N * 1.0 + A * r.randf_range(-0.3, 0.3), yaw + PI + r.randf_range(-0.6, 0.6), r)
		"bench_seat":
			sp.box(k, c + UP * 0.43, SetPieces._sz(A, w, 0.05, 0.36), &"prop_wood")
			for e: float in [-0.65, 0.65]:
				sp.box(k, c + A * e + UP * 0.2, SetPieces._sz(A, 0.06, 0.4, 0.3), &"gun_metal")
		"bin":
			var p := c + A * r.randf_range(-0.05, 0.05)
			if r.randf() < 0.2:
				k.d.geo.cylinder(p + UP * 0.18 - A * 0.3, p + UP * 0.18 + A * 0.3, 0.17, &"painted_steel", 10)  # knocked over
			else:
				k.d.geo.cylinder(p, p + UP * 0.6, 0.18, &"painted_steel", 10, false)
				k.d.geo.cylinder(p + UP * 0.02, p + UP * 0.5, 0.17, &"paper", 8, true)
		"vending":
			var mat: StringName = [&"painted_steel_red", &"painted_steel_blue"][r.randi_range(0, 1)]
			sp.box(k, c + UP * 0.95, SetPieces._sz(A, 0.88, 1.9, 0.76), mat, true)
			sp.box(k, c + N * 0.385 + A * -0.12 + UP * 1.15, SetPieces._sz(A, 0.55, 1.2, 0.02), &"glass_dirty")
			sp.box(k, c + N * 0.385 + A * 0.32 + UP * 1.1, SetPieces._sz(A, 0.14, 0.5, 0.025), &"gun_metal")
		"cooler":
			sp.box(k, c + UP * 0.5, SetPieces._sz(A, 0.34, 1.0, 0.34), &"painted_steel")
			k.d.geo.cylinder(c + UP * 1.0, c + UP * 1.42, 0.14, &"glass_dirty", 10, true)
		"manifold":
			var top := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H)
			for i in 3:
				var p := base + N * 0.22 + A * ((i - 1) * 0.42)
				var rad: float = [0.09, 0.12, 0.07][i]
				k.d.geo.cylinder(p, p + UP * top, rad, &"rusted_metal", 10, false)
				k.d.geo.cylinder(p + UP * 1.05, p + UP * 1.12, rad + 0.04, &"rusted_metal", 10)
				var wheel: Vector3 = p + N * (rad + 0.12) + UP * 1.3
				k.d.geo.cylinder(p + UP * 1.3, wheel, 0.025, &"gun_metal", 6, false)
				k.d.geo.cylinder(wheel, wheel + N * 0.03, 0.14, &"painted_steel_red", 12)
			sp.solid(k, c + UP * 1.0, SetPieces._sz(A, w, 2.0, depth), &"metal")
		"gas":
			var mat: StringName = [&"painted_steel_green", &"painted_steel_blue", &"painted_steel", &"painted_steel_red"][r.randi_range(0, 3)]
			for i in 3:
				var p := base + N * 0.18 + A * ((i - 1) * 0.3)
				k.d.geo.cylinder(p, p + UP * 1.35, 0.12, mat, 10, true)
				k.d.geo.cylinder(p + UP * 1.35, p + UP * 1.48, 0.04, &"gun_metal", 6)
			k.d.geo.cylinder(base + N * 0.06 - A * 0.5 + UP * 1.0, base + N * 0.06 + A * 0.5 + UP * 1.0, 0.012, &"rusted_metal", 4)
			sp.solid(k, c + UP * 0.7, SetPieces._sz(A, w, 1.4, depth), &"metal")
		"pallet":
			cb.kit(k.d, "pallet", c, yaw)
			for i in r.randi_range(2, 5):
				var q := c + A * r.randf_range(-0.35, 0.35) + N * r.randf_range(-0.25, 0.25) + UP * (0.15 + 0.11 + (i / 3) * 0.22)
				sp.box(k, q, SetPieces._sz(A, 0.55, 0.22, 0.38), &"fabric_canvas", false, Basis(UP, r.randf_range(-0.3, 0.3)))
			sp.solid(k, c + UP * 0.45, SetPieces._sz(A, 1.2, 0.9, 1.0), &"wood")
		"mop":
			k.d.geo.cylinder(c, c + UP * 0.3, 0.17, &"painted_steel_yellow", 10, false)
			k.d.geo.cylinder(c + A * 0.05, c + N * -0.25 + UP * 1.4, 0.015, &"prop_wood", 6)
			sp.box(k, c + N * 0.1 + A * 0.25 + UP * 0.3, SetPieces._sz(A, 0.1, 0.6, 0.25), &"painted_steel_blue")
		"boxes":
			var h := 0.0
			for i in r.randi_range(1, 3):
				var s := Vector3(r.randf_range(0.4, 0.6), r.randf_range(0.25, 0.4), r.randf_range(0.35, 0.5))
				sp.box(k, c + A * r.randf_range(-0.12, 0.12) + UP * (h + s.y * 0.5), s, &"prop_wood", false, Basis(UP, r.randf_range(-0.25, 0.25)))
				h += s.y
			sp.solid(k, c + UP * h * 0.5, SetPieces._sz(A, w * 0.7, h, depth * 0.8), &"wood")
	return true


func _hung_piece(k: SetPieces.Cell, span: ChunkBuilder.Span, dir: int, id: String, a: float, r: RandomNumberGenerator) -> bool:
	var hs: Array = HUNG_SIZES[id]
	var w: float = hs[0]
	var y0: float = hs[1]
	var y1: float = hs[2]
	var depth: float = maxf(hs[3], 0.02)
	var A := span.u
	var N := span.m
	var center := _span_point(span, a, FACE + NUDGE + depth * 0.5, (y0 + y1) * 0.5)
	if not _hung_free(k, center, SetPieces._sz(A, w, y1 - y0, depth)):
		return false
	var at := func(along: float, out: float, y: float) -> Vector3:
		return _span_point(span, a + along, FACE + NUDGE + out, y)
	var hb := func(along: float, out0: float, out1: float, ya: float, yb: float, wide: float, mat: StringName) -> void:
		sp.box(k, at.call(along, (out0 + out1) * 0.5, (ya + yb) * 0.5), SetPieces._sz(A, wide, yb - ya, out1 - out0), mat)
	match id:
		"notice":
			hb.call(0.0, -0.004, 0.022, y0, y1, w, &"prop_wood")
			hb.call(0.0, 0.0, 0.035, y0 - 0.03, y0 + 0.01, w + 0.06, &"gun_metal")
			for i in r.randi_range(3, 7):
				var u := r.randf_range(-w * 0.5 + 0.15, w * 0.5 - 0.15)
				var v := r.randf_range(y0 + 0.2, y1 - 0.2)
				sp.box(k, at.call(u, 0.024 + i * 0.0015, v), SetPieces._sz(A, 0.21, 0.29, 0.002), &"paper", false, Basis(N, r.randf_range(-0.15, 0.15)))
		"whiteboard":
			hb.call(0.0, -0.004, 0.025, y0, y1, w, &"paper")
			hb.call(0.0, 0.0, 0.04, y0 - 0.04, y0, w, &"gun_metal")  # pen tray
			hb.call(0.0, -0.004, 0.032, y1, y1 + 0.03, w + 0.04, &"gun_metal")
		"pegboard":
			hb.call(0.0, -0.004, 0.02, y0, y1, w, &"prop_wood")
			for i in r.randi_range(4, 9):
				var u := r.randf_range(-w * 0.5 + 0.12, w * 0.5 - 0.12)
				var v := r.randf_range(y0 + 0.15, y1 - 0.2)
				sp.box(k, at.call(u, 0.035, v), SetPieces._sz(A, r.randf_range(0.03, 0.06), r.randf_range(0.15, 0.32), 0.025),
					[&"gun_metal", &"painted_steel_red", &"prop_wood"][r.randi_range(0, 2)], false, Basis(N, r.randf_range(-0.6, 0.6)))
		"fuse":
			hb.call(0.0, -0.004, 0.15, y0, y1, w, &"painted_steel")
			hb.call(0.0, 0.15, 0.165, y0 + 0.03, y1 - 0.03, w - 0.06, &"painted_steel")
			var top := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H)
			k.d.geo.cylinder(at.call(0.0, 0.07, y1), at.call(0.0, 0.07, top), 0.025, &"gun_metal", 6, false)
			if r.randf() < 0.4:
				sp.box(k, at.call(w * 0.5 + 0.05, 0.3, (y0 + y1) * 0.5), SetPieces._sz(A, 0.015, y1 - y0 - 0.06, w - 0.06), &"painted_steel", false, Basis(UP, 0.3))
		"first_aid":
			hb.call(0.0, -0.004, 0.11, y0, y1, w, &"paper")
			hb.call(0.0, 0.11, 0.118, (y0 + y1) * 0.5 - 0.035, (y0 + y1) * 0.5 + 0.035, 0.22, &"painted_steel_green")
			hb.call(0.0, 0.11, 0.122, (y0 + y1) * 0.5 - 0.11, (y0 + y1) * 0.5 + 0.11, 0.07, &"painted_steel_green")
		"clock":
			var c: Vector3 = at.call(0.0, 0.0, (y0 + y1) * 0.5)
			k.d.geo.cylinder(c - N * 0.004, c + N * 0.05, 0.18, &"gun_metal", 16, true)
			k.d.geo.cylinder(c + N * 0.05, c + N * 0.056, 0.16, &"paper", 16, true)
			sp.box(k, c + N * 0.06 + UP * 0.05, SetPieces._sz(A, 0.012, 0.1, 0.006), &"gun_metal", false, Basis(N, r.randf() * TAU))
		"poster":
			var idx := r.randi_range(0, POSTERS - 1)
			wall_decal(k, "poster_%d" % idx, at.call(0.0, 0.0, (y0 + y1) * 0.5), N, w, y1 - y0)
		"hazard":
			var tex: String = ["hazard_no_smoking", "hazard_keep_clear", "hazard_ear_protection", "hazard_caution_floor"][r.randi_range(0, 3)]
			wall_decal(k, tex, at.call(0.0, 0.0, (y0 + y1) * 0.5), N, w, y1 - y0)
		"valve":
			var c: Vector3 = at.call(0.0, 0.0, (y0 + y1) * 0.5)
			k.d.geo.cylinder(c - N * 0.004, c + N * 0.2, 0.06, &"rusted_metal", 10, false)
			k.d.geo.cylinder(c + N * 0.2 - A * 0.25, c + N * 0.2 + A * 0.25, 0.07, &"rusted_metal", 10, true)
			k.d.geo.cylinder(c + N * 0.2, c + N * 0.32, 0.02, &"gun_metal", 6)
			k.d.geo.cylinder(c + N * 0.32, c + N * 0.35, 0.16, &"painted_steel_red", 12)
		"gauges":
			hb.call(0.0, -0.004, 0.08, y0, y1, w, &"painted_steel_green")
			for i in 3:
				var g: Vector3 = at.call((i - 1) * 0.27, 0.08, y1 - 0.2)
				k.d.geo.cylinder(g, g + N * 0.04, 0.07, &"gun_metal", 12, true)
				k.d.geo.cylinder(g + N * 0.04, g + N * 0.045, 0.06, &"paper", 12, true)
			for i in 6:
				hb.call(-0.3 + i * 0.12, 0.08, 0.1, y0 + 0.15, y0 + 0.22, 0.05, [&"painted_steel_red", &"gun_metal"][i % 2])
		"hooks":
			hb.call(0.0, -0.004, 0.03, y1 - 0.12, y1, w, &"prop_wood")
			for i in 4:
				var u := -w * 0.5 + 0.15 + i * (w - 0.3) / 3.0
				k.d.geo.cylinder(at.call(u, 0.03, y1 - 0.06), at.call(u, 0.11, y1 - 0.02), 0.012, &"gun_metal", 6)
				if r.randf() < 0.45:
					sp.box(k, at.call(u, 0.08, y1 - 0.45), SetPieces._sz(A, 0.42, 0.75, 0.1), [&"fabric_dark", &"fabric_canvas"][r.randi_range(0, 1)],
						false, Basis(A, r.randf_range(-0.08, 0.08)))
		"shelf_wall":
			hb.call(0.0, -0.004, 0.3, y0, y0 + 0.03, w, &"prop_wood")
			for e: float in [-w * 0.4, w * 0.4]:
				hb.call(e, -0.004, 0.26, y0 - 0.2, y0, 0.03, &"gun_metal")
			for i in r.randi_range(2, 5):
				var s := Vector3(r.randf_range(0.1, 0.3), r.randf_range(0.08, 0.3), r.randf_range(0.1, 0.22))
				sp.box(k, at.call(r.randf_range(-w * 0.4, w * 0.4), 0.15, y0 + 0.03 + s.y * 0.5), s,
					[&"prop_wood", &"paper", &"prop_steel_blue", &"prop_rust"][r.randi_range(0, 3)], false, Basis(UP, r.randf_range(-0.3, 0.3)))
		"mirror":
			hb.call(0.0, -0.004, 0.015, y0, y1, w, &"glass_dirty")
			hb.call(0.0, -0.004, 0.02, y0 - 0.02, y0, w + 0.04, &"gun_metal")
		"radiator":
			hb.call(0.0, 0.02, 0.05, y0 + 0.04, y1 - 0.04, w - 0.1, &"painted_steel")
			for i in int(w / 0.09):
				hb.call(-w * 0.5 + 0.06 + i * 0.09, 0.03, 0.12, y0, y1, 0.035, &"painted_steel")
			k.d.geo.cylinder(at.call(-w * 0.5 + 0.06, 0.07, y0), at.call(-w * 0.5 + 0.06, 0.07, 0.0), 0.015, &"gun_metal", 6, false)
		"extinguisher":
			var p: Vector3 = at.call(0.0, 0.1, y0 + 0.05)
			k.d.geo.cylinder(p, p + UP * 0.5, 0.08, &"painted_steel_red", 10, true)
			k.d.geo.cylinder(p + UP * 0.5, p + UP * 0.58, 0.03, &"gun_metal", 6)
			hb.call(0.0, -0.004, 0.03, y0 + 0.25, y0 + 0.35, 0.12, &"gun_metal")  # bracket
			hb.call(0.0, -0.004, 0.012, y1 - 0.3, y1, 0.25, &"painted_steel_red")  # sign
		"hose":
			hb.call(0.0, -0.004, 0.2, y0, y1, w, &"painted_steel_red")
			hb.call(0.0, 0.2, 0.215, y0 + 0.08, y1 - 0.08, w - 0.12, &"glass_dirty")
			var c: Vector3 = at.call(0.0, 0.1, (y0 + y1) * 0.5)
			k.d.geo.cylinder(c - A * 0.0 - N * 0.06, c + N * 0.06, 0.25, &"painted_steel_red", 14, true)  # reel
		"phone":
			hb.call(0.0, -0.004, 0.08, y0, y1, w, &"painted_steel")
			k.d.geo.cylinder(at.call(-0.08, 0.1, y1 - 0.05), at.call(0.08, 0.1, y1 - 0.05), 0.03, &"gun_polymer", 8, true)
			k.d.geo.cylinder(at.call(0.0, 0.08, y0 + 0.02), at.call(0.05, 0.25, y0 - 0.5), 0.008, &"cable", 4)
	return true


## Conduit and a cable along the walls of plant rooms and workshops, high up
## at a steady height so it runs on from cell to cell and over the doors.
func _conduit(k: SetPieces.Cell) -> void:
	var key := _kit_key(k)
	if not key in [&"boiler", &"pumps", &"electrical", &"workshop", &"vats", &"lab", &"parts", &"processing", &"hall", &"foundry"]:
		return
	var hc := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H)
	var y := minf(hc - 0.35, 3.4)
	for dir in 4:
		if not L.has_wall(k.x, k.z, k.s, dir) or L.stair_sides(k.x, k.z, k.s) & (1 << dir):
			continue
		var span := cb.edge_span(k.o, dir)
		var lo := 0.0
		var hi := C
		if L.chamfer_at(k.x, k.z, k.s, dir, false) >= 0:
			lo = LevelLayout.CHAMFER_CUT
		if L.chamfer_at(k.x, k.z, k.s, dir, true) >= 0:
			hi = C - LevelLayout.CHAMFER_CUT
		# Stop at a wall that meets this one in the cell's corner.
		var d0: int = (dir + 3) % 4
		var d1: int = (dir + 1) % 4
		if L.has_wall(k.x, k.z, k.s, d0):
			lo = maxf(lo, FACE + 0.06)
		if L.has_wall(k.x, k.z, k.s, d1):
			hi = minf(hi, C - FACE - 0.06)
		if L.has_gap(k.x, k.z, k.s, dir):
			var g := cb.gap_span(k.x, k.z, k.s, dir)
			if g.z > y - 0.2:
				continue
		k.d.geo.cylinder(_span_point(span, lo, FACE + 0.06, y), _span_point(span, hi, FACE + 0.06, y), 0.032, &"gun_metal", 6, false)
		k.d.geo.cylinder(_span_point(span, lo, FACE + 0.035, y - 0.11), _span_point(span, hi, FACE + 0.035, y - 0.11), 0.016, &"cable", 4, false)
		for i in 4:
			var a := lo + (hi - lo) * (i + 0.5) / 4.0
			sp.box(k, _span_point(span, a, FACE + NUDGE + 0.035, y - 0.05), SetPieces._sz(span.u, 0.05, 0.22, 0.07), &"gun_metal")  # saddle


## Painted walkway lines round a factory floor, 1.4 m off the walls.
func _walkway_lines(k: SetPieces.Cell) -> void:
	if not (k.zn.type in [&"hall", &"foundry", &"warehouse", &"processing"] and k.s == 0 and k.room == null):
		return
	const OFF := 1.4
	for dir in 4:
		if not L.has_wall(k.x, k.z, k.s, dir) or L.chamfer_at(k.x, k.z, k.s, dir, false) >= 0 or L.chamfer_at(k.x, k.z, k.s, dir, true) >= 0:
			continue
		var span := cb.edge_span(k.o, dir)
		var lo := OFF - 0.05 if L.has_wall(k.x, k.z, k.s, (dir + 3) % 4) else 0.0
		var hi := C - OFF + 0.05 if L.has_wall(k.x, k.z, k.s, (dir + 1) % 4) else C
		var y := 0.003 if dir % 2 == 0 else 0.005
		var c := _span_point(span, (lo + hi) * 0.5, OFF, y * 0.5)
		k.d.geo.box(c, SetPieces._sz(span.u, hi - lo, y, 0.1), &"painted_steel_yellow")


# --- Cramped passages ------------------------------------------------------------------------

## Pipes and a cable bundle down every passage: one side, one height per
## axis, so the runs join cell to cell and turn with a riser.
func _passage_services(k: SetPieces.Cell) -> void:
	var w := k.st.passage_width
	var open := cb.narrow_edges(k.x, k.z, k.s)
	var top := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H - 0.3)
	if top < 2.6:
		return
	var off := w * 0.5 - 0.22  # toward +X / +Z of the passage centre line
	var y0 := k.o.y
	var heights := [[y0 + top - 0.3, y0 + top - 0.52], [y0 + top - 0.44, y0 + top - 0.66]]  # [axis X, axis Z][pipe]
	var radii := [0.075, 0.05]
	var mats := [&"rusted_metal", &"painted_steel_green"]
	var axes := [false, false]
	for dir in 4:
		if not open & (1 << dir):
			continue
		var axis := 0 if dir % 2 == 1 else 1
		axes[axis] = true
		var v := LevelLayout.dir_vector(dir)
		for i in 2:
			# Each pipe runs from its crossing point to the cell edge.
			var lat: float = off - i * 0.18
			var a := Vector3(k.c.x + lat, heights[axis][i], k.c.z + lat)
			var b := a
			if axis == 0:
				b.x = k.c.x + v.x * C * 0.5
			else:
				b.z = k.c.z + v.z * C * 0.5
			k.d.geo.cylinder(a, b, radii[i], mats[i], 10, false)
		# Cables, highest, on the same side.
		for j in 2:
			var lat := off - 0.06 - j * 0.08
			var a := Vector3(k.c.x + lat, y0 + top - 0.12 - j * 0.03, k.c.z + lat)
			var b := a
			if axis == 0:
				b.x = k.c.x + v.x * C * 0.5
			else:
				b.z = k.c.z + v.z * C * 0.5
			k.d.geo.cylinder(a, b, 0.03 - j * 0.008, &"cable", 6, false)
		# Hangers from the ceiling every couple of metres.
		for t: float in [1.6, 3.4]:
			var h := k.c + v * t + (Vector3(0, 0, off - 0.09) if axis == 0 else Vector3(off - 0.09, 0, 0))
			var low: float = heights[axis][1] - radii[1]
			k.d.geo.box(Vector3(h.x, (low + y0 + top) * 0.5, h.z), Vector3(0.025, y0 + top - low, 0.025), &"gun_metal")
	# Where runs on both axes meet: a riser joins their heights.
	if axes[0] and axes[1]:
		for i in 2:
			var lat: float = off - i * 0.18
			var p := Vector3(k.c.x + lat, 0, k.c.z + lat)
			k.d.geo.cylinder(p + UP * heights[1][i], p + UP * heights[0][i], radii[i], mats[i], 10, false)  # (heights are world y)
	else:
		# The run stops in this cell: blank flanges on the ends.
		for i in 2:
			var lat: float = off - i * 0.18
			var axis := 0 if axes[0] else 1
			var p := Vector3(k.c.x + lat, heights[axis][i], k.c.z + lat)
			var along := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
			if open & (1 << (1 if axis == 0 else 2)) and open & (1 << (3 if axis == 0 else 0)):
				continue  # straight through
			var into := along if open & (1 << (1 if axis == 0 else 2)) else -along
			k.d.geo.cylinder(p - into * 0.04, p, radii[i] + 0.03, mats[i], 10)


## Things hung on the passage walls (the faces of the fill each side).
func _passage_walls(k: SetPieces.Cell) -> void:
	var w := k.st.passage_width
	var open := cb.narrow_edges(k.x, k.z, k.s)
	var crawl := cb.narrow_edges(k.x, k.z, k.s, true)
	var r := cb.rng(k.x, k.z, k.s, 330)
	var posters := 0
	for axis in 2:
		var lo_dir := 3 if axis == 0 else 0  # arm toward -X / -Z
		var hi_dir := 1 if axis == 0 else 2
		if not (open & (1 << lo_dir) or open & (1 << hi_dir)):
			continue
		var u := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
		for side: float in [-1.0, 1.0]:
			var lat := Vector3(0, 0, side) if axis == 0 else Vector3(side, 0, 0)
			var side_dir := (2 if side > 0 else 0) if axis == 0 else (1 if side > 0 else 3)
			var a0 := 0.0 if open & (1 << lo_dir) else C * 0.5 - w * 0.5
			var a1 := C if open & (1 << hi_dir) else C * 0.5 + w * 0.5
			var runs: Array[Vector2] = [Vector2(a0 + 0.3, a1 - 0.3)]
			if crawl & (1 << side_dir):
				runs = [Vector2(a0 + 0.3, C * 0.5 - w * 0.5 - 0.2), Vector2(C * 0.5 + w * 0.5 + 0.2, a1 - 0.3)]
			# A frame like a wall span: `along` from the cell edge, FACE in from the face.
			var face := k.c + lat * (w * 0.5) - u * (C * 0.5)
			var span := ChunkBuilder.Span.new(face + lat * FACE, u, -lat, C)
			for run in runs:
				var b := run.x + r.randf_range(0.2, 1.2)
				while b < run.y - 0.3:
					var id := sp._weighted(r, PASSAGE_KIT)
					if id == "poster" and posters >= 1:
						b += 0.5
						continue
					var hs: Array = HUNG_SIZES[id]
					if b + float(hs[0]) > run.y:
						break
					if _hung_piece(k, span, side_dir, id, b + float(hs[0]) * 0.5, r):
						if id == "poster":
							posters += 1
						b += float(hs[0]) + r.randf_range(0.8, 2.4)
					else:
						b += 0.5


## Sector-coloured line down the middle of each passage.
func _passage_stripe(k: SetPieces.Cell) -> void:
	var open := cb.narrow_edges(k.x, k.z, k.s)
	var mat := paint(k.zn)
	for dir in 4:
		if not open & (1 << dir):
			continue
		var v := LevelLayout.dir_vector(dir)
		var y := 0.003 if dir % 2 == 1 else 0.005
		var c := k.c + v * (C * 0.25) + UP * (y * 0.5)
		k.d.geo.box(c, SetPieces._sz(v, C * 0.5 + 0.06, y, 0.12), mat)


## EXIT arrows at passage junctions, door plates on passage doors.
func _passage_signs(k: SetPieces.Cell) -> void:
	var w := k.st.passage_width
	var open := cb.narrow_edges(k.x, k.z, k.s)
	var arms := 0
	for d in 4:
		if open & (1 << d):
			arms += 1
	var head := minf(cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s), H - 0.3) - 0.45
	# Doors at the end of an arm: what's through them.
	for dir in 4:
		if not L.has_door(k.x, k.z, k.s, dir):
			continue
		var n := Vector2i(k.x, k.z) + LevelLayout.DIRS[dir]
		var other := L.room_of(n.x, n.y, k.s)
		if other and other != k.room and other.use in PLATES:
			var v := LevelLayout.dir_vector(dir)
			# On the door wall above the opening (the cell edge, facing in).
			var p := k.c + v * (C * 0.5 - FACE) + UP * minf(head, cb.door_height(k.x, k.z, k.s, n, k.st) + 0.32)
			wall_decal(k, "room_" + String(other.use), p, -v, minf(1.1, w - 0.3), 0.28)
	if arms != 3:
		return
	var here := cb.exit_dist[L.idx(k.x, k.z, k.s)]
	var best := -1
	var best_d := here
	for dir in 4:
		if not open & (1 << dir):
			continue
		var n := Vector2i(k.x, k.z) + LevelLayout.DIRS[dir]
		var nd := cb.exit_dist[L.idx(n.x, n.y, k.s)] if L.inside(n.x, n.y, k.s) else -1
		if nd >= 0 and (best_d < 0 or nd < best_d):
			best = dir
			best_d = nd
	if best < 0:
		return
	for m in 4:
		if open & (1 << m):
			continue
		# The blank wall across the stem of the T: someone facing it reads left / right.
		var tex := ""
		if best == (m + 3) % 4:
			tex = "exit_l"
		elif best == (m + 1) % 4:
			tex = "exit_r"
		if tex == "":
			continue
		var v := LevelLayout.dir_vector(m)
		var p := k.c + v * (w * 0.5) + UP * 2.0
		wall_decal(k, tex, p, -v, 0.75, 0.28)
