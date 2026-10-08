class_name SetPieces
extends RefCounted
## What fills the spaces ChunkBuilder walls in: machines, conveyor lines,
## furnaces, racks, cubicles, boilers, lockers... and the decay over all of it.
##
## Pieces are generated in code from the zone and room they stand in, so a
## pattern that spans cells (a conveyor line, a rack row, a crane over the
## hall) is laid out from zone coordinates and each cell builds its own part.
## Like ChunkBuilder, this only reads the layout and writes into ChunkData, so
## it runs on worker threads.

const UP := Vector3.UP

var cb: ChunkBuilder
var L: LevelLayout
var C: float
var H: float
var detailer: Detailer


## Everything a piece needs to know about the cell it is building in.
class Cell:
	var d: ChunkBuilder.ChunkData
	var x: int
	var z: int
	var s: int
	var o: Vector3  # cell origin (min corner, floor level)
	var c: Vector3  # cell centre at floor level
	var st: ZoneStyle
	var zn: LevelLayout.Zone
	var room: LevelLayout.Room
	var flags: int
	var r: RandomNumberGenerator
	## Cell-local rects (x, z in 0..C) that must stay clear: door lanes, stair strips.
	var blocked: Array[Rect2] = []


func _init(builder: ChunkBuilder) -> void:
	cb = builder
	L = builder.L
	C = builder.C
	H = builder.H
	detailer = Detailer.new(self)


# --- Entry ---------------------------------------------------------------------------------

func dress(d: ChunkBuilder.ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone,
		room: LevelLayout.Room, flags: int, full: bool) -> void:
	var k := Cell.new()
	k.d = d
	k.x = x
	k.z = z
	k.s = s
	k.o = o
	k.c = o + Vector3(C * 0.5, 0, C * 0.5)
	k.st = st
	k.zn = zn
	k.room = room
	k.flags = flags
	k.r = cb.rng(x, z, s, 1)
	k.blocked = _blocked(x, z, s, st)
	_dress(k)
	# Then what follows from how this cell meets its neighbours.
	detailer.detail(k)


func _dress(k: Cell) -> void:
	var d := k.d
	var x := k.x
	var z := k.z
	var s := k.s
	var zn := k.zn
	var st := k.st
	var room := k.room
	var flags := k.flags
	if L.kind_at(x, z, s) == LevelLayout.Kind.CATWALK:
		_catwalk_clutter(k)
		return
	_decay(k)
	_gap_cover(k)
	if L.has_drop(x, z, s + 1):
		_drop_heap(k)
	if zn.type == &"yard":
		_yard(k)
		return
	_walls(k)
	if st.pipe_chance > 0.0 and k.r.randf() < st.pipe_chance:
		_pipes(k)
	if flags & LevelLayout.NARROW:
		_passage(k)
		return
	if flags & (15 * LevelLayout.CHAMFER):
		# Big pieces could reach through the cut corner: wall-side things only.
		_wall_props(k, 0.5)
		return
	if flags & (LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
		return
	if room and room.use == &"stairwell":
		return
	if L.has_split(x, z, s):
		# Two small rooms: their walls are dressed by the Detailer.
		_clutter(k)
		return
	if L.kind_at(x, z, s + 1) == LevelLayout.Kind.HOLE:
		# The floor above came down here.
		cb.kit(d, "rubble", k.c + Vector3(k.r.randf_range(-1, 1), 0, k.r.randf_range(-1, 1)), k.r.randf() * TAU)
		_debris(k, 14, 0.5)
		return
	match zn.type:
		&"hall":
			_factory_floor(k)
		&"foundry":
			_foundry(k)
		&"warehouse":
			_warehouse(k)
		&"loading_dock":
			_dock(k)
		&"corridor":
			_corridor(k)
		&"processing":
			if room:
				_room(k)
			else:
				_processing_floor(k)
		_:
			if room:
				_room(k)
			else:
				_wall_props(k, 0.4)
	_clutter(k)


# --- Helpers -------------------------------------------------------------------------------

func _blocked(x: int, z: int, s: int, st: ZoneStyle) -> Array[Rect2]:
	var out := base_blocked(x, z, s, st)
	var f := cb.level_feature(x, z, s)
	if not f.is_empty():
		out.append((f["footprint"] as Rect2).grow(0.5))
	return out


## Door lanes, stair strips, exits and the like (not the cell's platform or
## pit, which is placed clear of these).
func base_blocked(x: int, z: int, s: int, st: ZoneStyle) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for dir in 4:
		if L.has_door(x, z, s, dir) or (L.has_flag(x, z, s, LevelLayout.DOCK) and L.is_outside(x, z, s, dir)):
			var span := Vector2(C * 0.5 - 1.5, C * 0.5 + 1.5)
			if L.has_door(x, z, s, dir):
				span = cb.door_span(x, z, s, dir) + Vector2(-0.6, 0.6)
			var depth := 2.2  # the approach; cells are big enough to walk round a centred piece
			match dir:
				0:
					out.append(Rect2(span.x, 0, span.y - span.x, depth))
				1:
					out.append(Rect2(C - depth, span.x, depth, span.y - span.x))
				2:
					out.append(Rect2(span.x, C - depth, span.y - span.x, depth))
				3:
					out.append(Rect2(0, span.x, depth, span.y - span.x))
		if L.has_gap(x, z, s, dir):
			var g := cb.gap_span(x, z, s, dir)
			var span := Vector2(g.x - 0.6, g.y + 0.6)
			var depth := 2.4
			match dir:
				0:
					out.append(Rect2(span.x, 0, span.y - span.x, depth))
				1:
					out.append(Rect2(C - depth, span.x, depth, span.y - span.x))
				2:
					out.append(Rect2(span.x, C - depth, span.y - span.x, depth))
				3:
					out.append(Rect2(0, span.x, depth, span.y - span.x))
		if L.has_partial(x, z, s, dir):
			out.append(cb.strip(dir, 0.9))
		elif L.room_at(x, z, s) > 0 and L.open_edges(x, z, s) & (1 << dir) and not L.has_door(x, z, s, dir):
			# Inside a room bigger than a cell: keep a way through to the next cell.
			var lane := Rect2(C * 0.5 - 1.3, 0, 2.6, 2.7)
			match dir:
				1:
					lane = Rect2(C - 2.7, C * 0.5 - 1.3, 2.7, 2.6)
				2:
					lane = Rect2(C * 0.5 - 1.3, C - 2.7, 2.6, 2.7)
				3:
					lane = Rect2(0, C * 0.5 - 1.3, 2.7, 2.6)
			out.append(lane)
	# Posts holding up a catwalk bridge overhead (ChunkBuilder._bridge).
	if (x + z) % 2 == 0:
		for axis in 2:
			if L.has_flag(x, z, s + 1, LevelLayout.BRIDGE_X if axis == 0 else LevelLayout.BRIDGE_Z):
				for e: float in [-1.0, 1.0]:
					var off := e * (ChunkBuilder.BRIDGE * 0.5 + 0.06)
					var p := Vector2(C * 0.5, C * 0.5 + off) if axis == 0 else Vector2(C * 0.5 + off, C * 0.5)
					out.append(Rect2(p - Vector2(0.35, 0.35), Vector2(0.7, 0.7)))
	if L.has_drop(x, z, s):
		out.append(cb.drop_rect(x, z, s).grow(0.45))
	if L.has_split(x, z, s):
		out.append_array(split_blocked(x, z, s))
	if L.has_drop(x, z, s + 1):
		out.append(cb.drop_rect(x, z, s + 1).grow(0.25))
	for corner in 4:
		if L.has_chamfer(x, z, s, corner):
			var e := LevelLayout.CHAMFER_CUT + 0.6
			var k := cb._corner_point(corner)
			out.append(Rect2(minf(k.x, C - e), minf(k.y, C - e), e, e))
	var strips := L.stair_sides(x, z, s)
	for side in 4:
		if strips & (1 << side):
			out.append(cb.strip(side, LevelLayout.STRIP + 0.6))
	if L.has_flag(x, z, s, LevelLayout.EXIT):
		for e in L.exits:
			if e["cell"] == Vector3i(x, z, s):
				out.append(cb.strip(e["dir"], 2.5))
	for e in L.exits:
		var lever: Dictionary = e["lever"]
		if not lever.is_empty() and lever["cell"] == Vector3i(x, z, s):
			out.append(cb.strip(lever["dir"], 1.5))
	for a in L.anomalies:
		if a["cell"] == Vector3i(x, z, s):
			out.append(cb.strip(a["dir"], 1.5 if a["kind"] == &"symbol" else 3.6))
	return out


## Cell-local rects a split cell keeps clear: the partition (and a little
## either side) and the way through its doorway.
func split_blocked(x: int, z: int, s: int) -> Array[Rect2]:
	var side := L.split_side(x, z, s)
	var door := L.split_door(x, z, s)
	var back := LevelLayout.SPLIT_BACK
	var half := LevelLayout.SPLIT_T * 0.5 + 0.02  # things may stand against it
	return [span_rect(side, 0.0, C, back - half, back + half),
		span_rect(side, door.x - 0.3, door.y + 0.3, back - 1.1, back + 1.1)]


## Cell-local rect from coordinates along the edge span of `side` (a) and in
## from its edge line (depth).
func span_rect(side: int, a0: float, a1: float, d0: float, d1: float) -> Rect2:
	match side:
		0:
			return Rect2(a0, d0, a1 - a0, d1 - d0)
		1:
			return Rect2(C - d1, a0, d1 - d0, a1 - a0)
		2:
			return Rect2(a0, C - d1, a1 - a0, d1 - d0)
	return Rect2(d0, a0, d1 - d0, a1 - a0)


func _free(k: Cell, r: Rect2) -> bool:
	if r.position.x < -0.01 or r.position.y < -0.01 or r.end.x > C + 0.01 or r.end.y > C + 0.01:
		return false
	for b in k.blocked:
		if b.intersects(r):
			return false
	return true


## Cell-local rect of a box centred at world p with extents la along A, lb along B.
func _rect(k: Cell, p: Vector3, A: Vector3, la: float, lb: float) -> Rect2:
	var sx := la if absf(A.x) > 0.5 else lb
	var sz := lb if absf(A.x) > 0.5 else la
	return Rect2(p.x - k.o.x - sx * 0.5, p.z - k.o.z - sz * 0.5, sx, sz)


## World size of a box la long along A, h tall, lb along the other axis.
static func _sz(A: Vector3, la: float, h: float, lb: float) -> Vector3:
	return Vector3(la, h, lb) if absf(A.x) > 0.5 else Vector3(lb, h, la)


static func _across(A: Vector3) -> Vector3:
	return Vector3(A.z, 0, A.x).abs()


## Anything big enough to look like you could stand on it or bump into it
## collides, asked or not (so nobody falls into a pallet stack); thin trim,
## papers, small debris and wall-hung things stay visual only.
func box(k: Cell, center: Vector3, size: Vector3, mat: StringName, collide: bool = false, basis: Basis = Basis.IDENTITY) -> void:
	if not collide and size.y >= 0.25 and minf(size.x, size.z) >= 0.3 and maxf(size.x, size.z) >= 0.4:
		collide = true
	k.d.geo.box(center, size, mat, cb.surface_of(mat) if collide else &"", false, basis)
	if collide:
		k.d.taken.append(ChunkBuilder.box_aabb(center, size, basis))


## Invisible collider (also blocks navigation).
func solid(k: Cell, center: Vector3, size: Vector3, surface: StringName = &"metal", basis: Basis = Basis.IDENTITY) -> void:
	k.d.geo.box(center, size, &"", surface, false, basis)
	k.d.taken.append(ChunkBuilder.box_aabb(center, size, basis))


func cyl(k: Cell, a: Vector3, b: Vector3, radius: float, mat: StringName, seg: int = 12, caps: bool = true) -> void:
	k.d.geo.cylinder(a, b, radius, mat, seg, caps)
	# Drums, tanks, vessels: a box collider inside the round body.
	var length := a.distance_to(b)
	if radius >= 0.2 and length >= 0.3:
		var axis := (b - a) / length
		var basis := Basis.looking_at(axis, Vector3.UP if absf(axis.y) < 0.98 else Vector3.FORWARD)
		k.d.geo.box((a + b) * 0.5, Vector3(radius * 1.6, radius * 1.6, length), &"", cb.surface_of(mat), false, basis)
		k.d.taken.append(ChunkBuilder.box_aabb((a + b) * 0.5, Vector3(radius * 2.0, radius * 2.0, length), basis))


func decal(k: Cell, tex: String, p: Vector3, size: Vector3, yaw: float) -> void:
	if k.d.geo.visuals:
		k.d.decals.append([tex, Transform3D(Basis(Vector3.UP, yaw), p + UP * 0.05), size])


## Zone-wide random numbers: the same for every cell of the zone.
func _zone_rng(zn: LevelLayout.Zone, purpose: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, zn.id, purpose])
	return r


## Axes of a zone: A along its long side, B across.
func _zone_axes(zn: LevelLayout.Zone) -> Array:
	var along_x := zn.rect.size.x >= zn.rect.size.y
	return [Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1), Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0), along_x]


## Index of the cell along and across its zone, and the zone's size in cells.
func _zone_index(k: Cell) -> Dictionary:
	var along_x := k.zn.rect.size.x >= k.zn.rect.size.y
	var lx := k.x - k.zn.rect.position.x
	var lz := k.z - k.zn.rect.position.y
	return {"along": lx if along_x else lz, "across": lz if along_x else lx,
		"along_n": k.zn.rect.size.x if along_x else k.zn.rect.size.y,
		"across_n": k.zn.rect.size.y if along_x else k.zn.rect.size.x}


func _wall_free(k: Cell, dir: int) -> bool:
	return L.has_wall(k.x, k.z, k.s, dir) and not L.has_door(k.x, k.z, k.s, dir) and not L.has_window(k.x, k.z, k.s, dir) \
		and not (L.stair_sides(k.x, k.z, k.s) & (1 << dir)) and not L.has_gap(k.x, k.z, k.s, dir) \
		and not (L.has_flag(k.x, k.z, k.s, LevelLayout.DOCK) and L.is_outside(k.x, k.z, k.s, dir)) \
		and L.chamfer_at(k.x, k.z, k.s, dir, false) < 0 and L.chamfer_at(k.x, k.z, k.s, dir, true) < 0


## Point against the inner face of the wall on `dir`, `along` metres from the
## middle (positive toward dir+1), `out` metres off the wall.
func _wall_at(k: Cell, dir: int, along: float, out: float, y: float = 0.0) -> Vector3:
	var v := LevelLayout.dir_vector(dir)
	var t := LevelLayout.dir_vector((dir + 1) % 4)
	return k.c + v * (C * 0.5 - 0.15 - out) + t * along + UP * y


## Yaw that turns a kit prop's front (-Z) away from the wall on `dir`.
static func _face_from_wall(dir: int) -> float:
	var inward := -LevelLayout.dir_vector(dir)
	return atan2(-inward.x, -inward.z)


# --- Decay, everywhere ---------------------------------------------------------------------

func _decay(k: Cell) -> void:
	var r := cb.rng(k.x, k.z, k.s, 50)
	var type := k.zn.type
	var narrow := k.flags & LevelLayout.NARROW != 0
	var spot := func() -> Vector3:
		if narrow:
			return k.c + Vector3(r.randf_range(-0.8, 0.8), 0, r.randf_range(-0.8, 0.8))
		return k.o + Vector3(r.randf_range(0.7, C - 0.7), 0, r.randf_range(0.7, C - 0.7))
	_debris(k, r.randi_range(0, 5), 0.3)
	if type in [&"office", &"corridor", &"maintenance", &"storage"] and r.randf() < 0.55:
		for i in r.randi_range(1, 2):
			decal(k, "papers", spot.call(), Vector3(r.randf_range(1.0, 1.8), 0.4, r.randf_range(1.0, 1.8)), r.randf() * TAU)
	if r.randf() < 0.3:
		decal(k, "crack", spot.call(), Vector3(r.randf_range(1.5, 3.0), 0.4, r.randf_range(1.5, 3.0)), r.randf() * TAU)
	if type in [&"hall", &"foundry", &"warehouse", &"loading_dock", &"processing"] and r.randf() < 0.35:
		decal(k, "oil", spot.call(), Vector3(r.randf_range(1.2, 2.6), 0.4, r.randf_range(1.2, 2.6)), r.randf() * TAU)
	# Daylight and weather through the roof: moss, weeds, a drift of leaves.
	var roof_hole := L.has_flag(k.x, k.z, k.s, LevelLayout.ROOF_HOLE)
	if k.zn.type in ChunkBuilder.TALL and k.s == 0:
		roof_hole = L.has_flag(k.x, k.z, k.zn.top, LevelLayout.ROOF_HOLE)
	if roof_hole:
		decal(k, "moss", k.c + Vector3(r.randf_range(-1, 1), 0, r.randf_range(-1, 1)), Vector3(4.5, 0.6, 4.5), r.randf() * TAU)
		decal(k, "moss", spot.call(), Vector3(2.5, 0.6, 2.5), r.randf() * TAU)
		_weeds(k, r, 10)
	# Cables hanging from the ceiling
	if r.randf() < 0.12 and type != &"yard":
		var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
		var a: Vector3 = spot.call() + UP * hc
		var b: Vector3 = a + Vector3(r.randf_range(-1.5, 1.5), -r.randf_range(0.8, 2.0), r.randf_range(-1.5, 1.5))
		var m := (a + b) * 0.5 + Vector3.DOWN * 0.4
		k.d.geo.cylinder(a, m, 0.02, &"cable", 4)
		k.d.geo.cylinder(m, b, 0.02, &"cable", 4)


## Wall dressing: skirting, a painted lower band or dado rail, vents up
## high, plaster peeling off to the brick.
func _walls(k: Cell) -> void:
	if k.flags & LevelLayout.NARROW or k.zn.type in ChunkBuilder.TALL or k.zn.type == &"yard":
		return
	var r := cb.rng(k.x, k.z, k.s, 52)
	var interior := k.zn.district == 1
	var band_mat: StringName = [&"painted_steel_green", &"painted_steel_blue", &"painted_steel"][(k.zn.id + k.s) % 3]
	var band := (k.zn.type in [&"maintenance", &"storage", &"processing"] or (k.zn.type == &"corridor" and interior)) and (k.zn.id + k.s) % 2 == 0
	var dado := k.zn.type == &"office"
	for dir in 4:
		if not L.has_wall(k.x, k.z, k.s, dir) or L.has_flag(k.x, k.z, k.s, LevelLayout.DOCK):
			continue
		var segs: Array[Vector2] = [Vector2(0.15, C - 0.15)]
		if L.chamfer_at(k.x, k.z, k.s, dir, false) >= 0:
			segs[0].x = LevelLayout.CHAMFER_CUT + 0.15
		if L.chamfer_at(k.x, k.z, k.s, dir, true) >= 0:
			segs[0].y = C - LevelLayout.CHAMFER_CUT - 0.15
		if L.has_door(k.x, k.z, k.s, dir):
			var span := cb.door_span(k.x, k.z, k.s, dir)
			segs.assign([Vector2(segs[0].x, span.x - 0.1), Vector2(span.y + 0.1, segs[0].y)])
		elif L.has_gap(k.x, k.z, k.s, dir):
			var g := cb.gap_span(k.x, k.z, k.s, dir)
			segs.assign([Vector2(segs[0].x, g.x - 0.5), Vector2(g.y + 0.5, segs[0].y)])
		if L.stair_sides(k.x, k.z, k.s) & (1 << dir):
			continue
		for sg in segs:
			if sg.y - sg.x < 0.2:
				continue
			cb.wall_box(k.d.geo, k.o, dir, sg.x, sg.y, 0.0, 0.12, &"prop_wood" if dado else &"painted_steel", false, 0.03, 0.165)
			if band:
				cb.wall_box(k.d.geo, k.o, dir, sg.x, sg.y, 0.12, 1.15, band_mat, false, 0.012, 0.156)
			if dado and not L.has_window(k.x, k.z, k.s, dir):
				cb.wall_box(k.d.geo, k.o, dir, sg.x, sg.y, 0.95, 1.0, &"prop_wood", false, 0.025, 0.162)
		var free := _wall_free(k, dir)
		if free and r.randf() < 0.22:
			# Air vent up near the ceiling, grille hanging off sometimes
			var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
			var t := r.randf_range(-2.5, 2.5)
			var p := _wall_at(k, dir, t, 0.02, minf(hc, H) - 0.45)
			var A := LevelLayout.dir_vector((dir + 1) % 4)
			box(k, p, _sz(A, 0.7, 0.35, 0.04), &"soot")
			if r.randf() < 0.3:
				box(k, _wall_at(k, dir, t, 0.25, 0.04), _sz(A, 0.7, 0.03, 0.35), &"steel_grate", false, Basis(A, 0.2))
			else:
				box(k, p - LevelLayout.dir_vector(dir) * 0.02, _sz(A, 0.66, 0.31, 0.02), &"steel_grate")
		if free and interior and r.randf() < 0.3 and k.d.geo.visuals:
			# Plaster come away from the wall
			var v := LevelLayout.dir_vector(dir)
			var up := -v
			var right := Vector3.UP.cross(up).normalized()
			var q := _wall_at(k, dir, r.randf_range(-2.5, 2.5), 0.0, r.randf_range(0.6, 2.2))
			var sz := r.randf_range(1.0, 2.2)
			k.d.decals.append(["peel", Transform3D(Basis(right, up, right.cross(up)), q), Vector3(sz * 1.3, 0.4, sz)])


## Under a drop-down: the slab that came down, in pieces, and its dust.
func _drop_heap(k: Cell) -> void:
	var r := cb.rng(k.x, k.z, k.s, 161)
	var h := cb.drop_rect(k.x, k.z, k.s + 1)
	var c := k.o + Vector3(h.get_center().x, 0, h.get_center().y)
	cb.kit(k.d, "rubble", c, r.randf() * TAU)
	for i in r.randi_range(5, 9):
		var p := c + Vector3(r.randf_range(-1.3, 1.3), 0, r.randf_range(-1.3, 1.3))
		var size := Vector3(r.randf_range(0.2, 0.6), r.randf_range(0.08, 0.2), r.randf_range(0.2, 0.5))
		box(k, p + UP * size.y * 0.5, size, &"concrete_dark", false, Basis.from_euler(Vector3(r.randf_range(-0.3, 0.3), r.randf() * TAU, r.randf_range(-0.3, 0.3))))
	for i in 3:
		var a := c + Vector3(r.randf_range(-1, 1), 0.3, r.randf_range(-1, 1))
		k.d.geo.cylinder(a, a + Vector3(r.randf_range(-0.8, 0.8), r.randf_range(0.1, 0.5), r.randf_range(-0.8, 0.8)), 0.012, &"rusted_metal", 4)
	decal(k, "crack", c, Vector3(3.2, 0.4, 3.2), r.randf() * TAU)


## Small broken concrete, scraps and dust piles.
func _debris(k: Cell, count: int, spread: float) -> void:
	var r := cb.rng(k.x, k.z, k.s, 51)
	var narrow := k.flags & LevelLayout.NARROW != 0
	for i in count:
		var p := k.o + Vector3(r.randf_range(0.5, C - 0.5), 0, r.randf_range(0.5, C - 0.5))
		if narrow:
			p = k.c + Vector3(r.randf_range(-0.9, 0.9), 0, r.randf_range(-0.9, 0.9))
		var size := Vector3(r.randf_range(0.08, 0.4), r.randf_range(0.05, 0.2), r.randf_range(0.08, 0.35)) * (1.0 + spread * r.randf())
		var basis := Basis.from_euler(Vector3(r.randf_range(-0.4, 0.4), r.randf() * TAU, r.randf_range(-0.4, 0.4)))
		var mat: StringName = [&"concrete_dark", &"concrete_wall", &"rusted_metal", &"concrete_dark"][r.randi_range(0, 3)]
		box(k, p + UP * size.y * 0.4, size, mat, false, basis)


func _weeds(k: Cell, r: RandomNumberGenerator, count: int) -> void:
	for i in count:
		var p := k.c + Vector3(r.randf_range(-2.5, 2.5), 0, r.randf_range(-2.5, 2.5))
		for j in 3:
			var tip := p + Vector3(r.randf_range(-0.25, 0.25), r.randf_range(0.25, 0.7), r.randf_range(-0.25, 0.25))
			k.d.geo.frustum(p, tip, 0.03, 0.0, &"moss", 4)


func _catwalk_clutter(k: Cell) -> void:
	var r := k.r
	if r.randf() < 0.12:
		var sides := (k.flags >> 4) & 15
		for side in 4:
			if sides & (1 << side):
				var p := _wall_at(k, side, r.randf_range(-2.5, 2.5), 0.6)
				cyl(k, p, p + UP * 0.35, 0.16, &"prop_rust", 10)  # bucket
				break


# --- Pipes ---------------------------------------------------------------------------------

## Overhead pipe runs along a consistent side so they join up cell to cell.
func _pipes(k: Cell) -> void:
	var r := cb.rng(k.x, k.z, k.s, 2)
	var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
	var top := minf(hc, H) - 0.15
	var narrow := k.flags & LevelLayout.NARROW != 0
	var along_x := L.zone_at(k.x - 1, k.z, k.s) == L.zone_at(k.x, k.z, k.s) or L.zone_at(k.x + 1, k.z, k.s) == L.zone_at(k.x, k.z, k.s)
	if L.zone_at(k.x, k.z - 1, k.s) == L.zone_at(k.x, k.z, k.s) and L.zone_at(k.x, k.z + 1, k.s) == L.zone_at(k.x, k.z, k.s):
		along_x = false
	var inset0 := 0.45
	if narrow:
		var open := L.open_edges(k.x, k.z, k.s)
		along_x = (open & 10) != 0
		inset0 = C * 0.5 - k.st.passage_width * 0.5 + 0.2
		if open & 10 and open & 5:
			return  # junction: no straight run
	var specs := [[0.13, top - 0.3, inset0], [0.08, top - 0.6, inset0 + 0.3], [0.05, top - 0.85, inset0]]
	if narrow:
		specs = [[0.07, 2.45, inset0], [0.04, 2.3, inset0 + 0.02]]
	for spec in specs:
		var radius: float = spec[0]
		var y: float = spec[1]
		var inset: float = spec[2]
		var a: Vector3
		var b: Vector3
		if along_x:
			a = k.o + Vector3(0, y, inset)
			b = k.o + Vector3(C, y, inset)
		else:
			a = k.o + Vector3(inset, y, 0)
			b = k.o + Vector3(inset, y, C)
		cyl(k, a, b, radius, &"rusted_metal", 10, false)
		# Flanges
		for t: float in [0.25, 0.75]:
			var f := a.lerp(b, t)
			var axis := (b - a).normalized()
			cyl(k, f - axis * 0.03, f + axis * 0.03, radius + 0.03, &"rusted_metal", 10)
	if not narrow:
		for i in 3:
			var t := (i + 0.5) / 3.0
			var p := k.o + (Vector3(C * t, top, inset0) if along_x else Vector3(inset0, top, C * t))
			box(k, p + Vector3.DOWN * 0.45, Vector3(0.05, 0.9, 0.05), &"gun_metal")
	if r.randf() < k.st.leak_chance:
		var t := r.randf_range(0.2, 0.8)
		var drip := k.o + (Vector3(C * t, specs[0][1] - 0.15, inset0) if along_x else Vector3(inset0, specs[0][1] - 0.15, C * t))
		if k.d.geo.visuals:
			k.d.leaks.append({"position": drip, "floor": k.o.y})
		decal(k, "puddle", Vector3(drip.x, k.o.y, drip.z), Vector3(r.randf_range(1.4, 2.4), 0.3, r.randf_range(1.2, 2.0)), r.randf() * TAU)
	# A burst section hanging down
	if not narrow and r.randf() < 0.08:
		var p := k.o + (Vector3(C * 0.5, specs[1][1], inset0 + 0.3) if along_x else Vector3(inset0 + 0.3, specs[1][1], C * 0.5))
		cyl(k, p, p + Vector3(r.randf_range(-1, 1), -r.randf_range(1.2, 2.2), r.randf_range(-1, 1)), 0.08, &"rusted_metal", 8)


# --- Cramped passages ----------------------------------------------------------------------

func _passage(k: Cell) -> void:
	var r := k.r
	var w := k.st.passage_width
	var open := L.open_edges(k.x, k.z, k.s)
	var straight_x := open & 10 != 0 and open & 5 == 0
	var straight_z := open & 5 != 0 and open & 10 == 0
	# Things on the passage walls: walls run along the passage on both sides.
	var faces: Array = []  # [point on the face (centre height 0), outward normal, along axis]
	if straight_x:
		for e: float in [-1.0, 1.0]:
			faces.append([k.c + Vector3(0, 0, e * w * 0.5), Vector3(0, 0, -e), Vector3(1, 0, 0)])
	elif straight_z:
		for e: float in [-1.0, 1.0]:
			faces.append([k.c + Vector3(e * w * 0.5, 0, 0), Vector3(-e, 0, 0), Vector3(0, 0, 1)])
	# (Things hung on the passage walls come from Detailer; here only what
	# stands on the floor.)
	var furnished := false
	for f in faces:
		var p: Vector3 = f[0]
		var n: Vector3 = f[1]
		var ax: Vector3 = f[2]
		var t := r.randf_range(-2.5, 2.5)
		if r.randf() < 0.15 and not furnished:
			# A locker or cabinet against the wall (the passage stays passable).
			furnished = true
			var id: String = ["locker", "filing_cabinet", "locker"][r.randi_range(0, 2)]
			cb.kit(k.d, id, p + ax * t + n * 0.35, atan2(-n.x, -n.z) + PI)
	# A box or drum pushed against a wall
	if r.randf() < 0.3 and not faces.is_empty() and not furnished:
		var f: Array = faces[r.randi_range(0, faces.size() - 1)]
		var q: Vector3 = f[0] + (f[2] as Vector3) * r.randf_range(-2.5, 2.5) + (f[1] as Vector3) * 0.35
		cb.kit(k.d, ["crate_small", "barrel_rust", "crate_small"][r.randi_range(0, 2)], q, r.randf() * TAU)


# --- Factory floor -------------------------------------------------------------------------

func _factory_floor(k: Cell) -> void:
	if k.s != 0:
		return
	var ix := _zone_index(k)
	var axes := _zone_axes(k.zn)
	var A: Vector3 = axes[0]
	var B: Vector3 = axes[1]
	var edge_across: bool = ix["across"] == 0 or ix["across"] == ix["across_n"] - 1
	var edge_along: bool = ix["along"] == 0 or ix["along"] == ix["along_n"] - 1
	var r := k.r
	_crane(k, ix, A, B)
	_hall_ducts(k, ix, A, B)
	if edge_across or edge_along:
		_wall_props(k, 0.55, ["electrical_cabinet", "barrel_rust", "crate_wood", "pallet", "barrel_blue"])
		if r.randf() < 0.4:
			_workbench_against_wall(k)
		return
	var conveyor_row: bool = (int(ix["across"]) - 1) % 3 == 0
	if conveyor_row:
		_conveyor(k, A, B)
		for e: float in [-1.0, 1.0]:
			var p := k.c + B * (e * 2.7) + A * r.randf_range(-1.5, 1.5)
			var roll := r.randf()
			if roll < 0.3:
				_robot_arm(k, p, -B * e)
			elif roll < 0.5:
				if _free(k, _rect(k, p, A, 2.8, 1.7)):
					cb.kit(k.d, "machine_press", p, atan2(B.x * e, B.z * e))
			elif roll < 0.65:
				_workstation(k, p, -B * e, A)
		# Safety lines either side of the belt
		for e: float in [-1.0, 1.0]:
			box(k, k.c + B * (e * 1.4) + UP * 0.006, _sz(A, C, 0.012, 0.08), &"painted_steel_yellow")
		return
	var roll := r.randf()
	if roll < 0.22:
		if _free(k, _rect(k, k.c, A, 3.0, 2.0)):
			cb.kit(k.d, "machine_press", k.c, atan2(A.x, A.z) + (PI if r.randf() < 0.5 else 0.0))
	elif roll < 0.42:
		_lathe(k, k.c, A)
	elif roll < 0.58:
		_generator(k, k.c, A)
	elif roll < 0.68:
		if _free(k, _rect(k, k.c, A, 5.6, 2.4)):
			cb.kit(k.d, "tank", k.c, atan2(A.x, A.z))
	elif roll < 0.8:
		_fallen_beam(k)
	else:
		_pallet_stack(k, k.c + A * r.randf_range(-1.5, 1.5) + B * r.randf_range(-1.5, 1.5))


func _conveyor(k: Cell, A: Vector3, B: Vector3) -> void:
	var r := cb.rng(k.x, k.z, k.s, 60)
	var h := 0.85
	var w := 1.0
	var rect := _rect(k, k.c, A, C, w + 0.3)
	if not _free(k, rect):
		# Break the line at doorways but keep a stub each side.
		for e: float in [-1.0, 1.0]:
			var p := k.c + A * (e * C * 0.33)
			if _free(k, _rect(k, p, A, C * 0.33, w + 0.3)):
				_conveyor_piece(k, p, A, B, C * 0.33, r)
		return
	_conveyor_piece(k, k.c, A, B, C, r)


func _conveyor_piece(k: Cell, p: Vector3, A: Vector3, B: Vector3, length: float, r: RandomNumberGenerator) -> void:
	var h := 0.85
	var w := 1.0
	for e: float in [-1.0, 1.0]:
		box(k, p + B * (e * w * 0.5) + UP * h, _sz(A, length, 0.16, 0.08), &"painted_steel_green")
	var legs := int(length / 2.0)
	for i in legs + 1:
		var q := p + A * (-length * 0.5 + 0.2 + i * (length - 0.4) / maxi(legs, 1))
		for e: float in [-1.0, 1.0]:
			box(k, q + B * (e * w * 0.45) + UP * (h * 0.5), Vector3(0.07, h, 0.07), &"painted_steel")
		box(k, q + UP * 0.25, _sz(A, 0.06, 0.06, w), &"painted_steel")
	var rollers := int(length / 0.6)
	for i in rollers:
		var q := p + A * (-length * 0.5 + (i + 0.5) * length / rollers) + UP * (h + 0.02)
		cyl(k, q - B * (w * 0.47), q + B * (w * 0.47), 0.045, &"gun_metal", 6, false)
	# Belt: torn in places, a length hanging off the side
	if r.randf() < 0.75:
		var keep := length * r.randf_range(0.5, 1.0)
		box(k, p + A * ((length - keep) * 0.5 * (1 if r.randf() < 0.5 else -1)) + UP * (h + 0.075), _sz(A, keep, 0.01, w * 0.9), &"prop_rubber")
		if r.randf() < 0.3:
			var q := p + B * (w * 0.5) + UP * (h * 0.5)
			box(k, q, _sz(A, 1.2, 0.01, h), &"prop_rubber", false, Basis(A, 0.15))
	solid(k, p + UP * (h * 0.5 + 0.05), _sz(A, length, h + 0.1, w + 0.15))
	# Things left on the line
	for i in r.randi_range(0, 2):
		var q := p + A * r.randf_range(-length * 0.4, length * 0.4) + UP * (h + 0.09)
		if r.randf() < 0.5:
			cb.kit(k.d, "crate_small", q, r.randf() * TAU, {"collide": false})
		else:
			box(k, q + UP * 0.12, Vector3(r.randf_range(0.3, 0.6), 0.25, r.randf_range(0.3, 0.6)), &"painted_steel", false, Basis(Vector3.UP, r.randf() * TAU))


## An assembly robot, slumped where it stopped.
func _robot_arm(k: Cell, p: Vector3, toward: Vector3) -> void:
	if not _free(k, Rect2(p.x - k.o.x - 0.7, p.z - k.o.z - 0.7, 1.4, 1.4)):
		return
	var r := cb.rng(k.x, k.z, k.s, 61 + int(p.x * 10.0))
	cyl(k, p, p + UP * 0.25, 0.55, &"painted_steel", 14)
	cyl(k, p + UP * 0.25, p + UP * 0.75, 0.32, &"painted_steel_orange", 12)
	var shoulder := p + UP * 0.95
	var yaw_dir := toward.rotated(Vector3.UP, r.randf_range(-0.8, 0.8))
	var elbow := shoulder + yaw_dir * 0.7 + UP * r.randf_range(0.5, 1.0)
	var wrist := elbow + yaw_dir * 0.8 + UP * r.randf_range(-0.9, -0.2)
	cyl(k, p + UP * 0.75, shoulder, 0.26, &"painted_steel_orange", 12)
	cb.beam(k.d.geo, shoulder, elbow, Vector2(0.28, 0.32), &"painted_steel_orange")
	cyl(k, elbow - yaw_dir.cross(UP) * 0.18, elbow + yaw_dir.cross(UP) * 0.18, 0.18, &"gun_metal", 10)
	cb.beam(k.d.geo, elbow, wrist, Vector2(0.2, 0.22), &"painted_steel_orange")
	cyl(k, wrist, wrist + (wrist - elbow).normalized() * 0.25, 0.1, &"gun_metal", 8)
	if r.randf() < 0.5:
		k.d.geo.cylinder(wrist, wrist + Vector3.DOWN * r.randf_range(0.4, 1.2), 0.015, &"cable", 4)
	solid(k, p + UP * 0.9, Vector3(1.1, 1.8, 1.1))


func _workstation(k: Cell, p: Vector3, facing: Vector3, A: Vector3) -> void:
	if not _free(k, _rect(k, p, A, 1.8, 1.0)):
		return
	box(k, p + UP * 0.95, _sz(A, 1.6, 0.06, 0.8), &"painted_steel", true)
	box(k, p + UP * 0.45, _sz(A, 1.5, 0.9, 0.7), &"painted_steel_green", true)
	# Control panel on a post
	var q := p + facing * 0.25 + UP * 1.35
	box(k, q, _sz(A, 0.6, 0.45, 0.12), &"painted_steel", false, Basis(A, 0.4))
	box(k, q + facing * 0.07 + UP * 0.05, _sz(A, 0.12, 0.12, 0.02), &"painted_steel_red")


func _lathe(k: Cell, p: Vector3, A: Vector3) -> void:
	if not _free(k, _rect(k, p, A, 4.6, 1.6)):
		return
	var B := _across(A)
	box(k, p + UP * 0.45, _sz(A, 4.0, 0.9, 0.8), &"painted_steel_green", true)  # base
	box(k, p + UP * 1.0, _sz(A, 4.2, 0.2, 0.5), &"gun_metal")  # bed ways
	box(k, p - A * 1.7 + UP * 1.35, _sz(A, 0.9, 0.7, 0.9), &"painted_steel_green", true)  # headstock
	cyl(k, p - A * 1.25 + UP * 1.35, p - A * 1.05 + UP * 1.35, 0.25, &"gun_metal", 14)  # chuck
	box(k, p + A * 1.7 + UP * 1.25, _sz(A, 0.5, 0.45, 0.4), &"painted_steel_green")  # tailstock
	box(k, p + A * 0.2 + B * 0.35 + UP * 1.2, _sz(A, 0.5, 0.25, 0.4), &"painted_steel")  # carriage
	cyl(k, p - A * 1.05 + UP * 1.35, p + A * 1.45 + UP * 1.35, 0.06, &"rusted_metal", 8)  # half-turned bar
	box(k, p + UP * 0.92, _sz(A, 3.0, 0.04, 1.0), &"rusted_metal")  # chip tray


func _generator(k: Cell, p: Vector3, A: Vector3) -> void:
	if not _free(k, _rect(k, p, A, 5.4, 2.8)):
		return
	var r := k.r
	box(k, p + UP * 0.25, _sz(A, 5.0, 0.5, 2.4), &"concrete_dark", true)  # plinth
	cyl(k, p - A * 1.6 + UP * 1.55, p + A * 1.2 + UP * 1.55, 1.05, &"painted_steel_green", 20)  # stator
	for t: float in [-1.2, -0.2, 0.8]:
		cyl(k, p + A * (t - 0.05) + UP * 1.55, p + A * (t + 0.05) + UP * 1.55, 1.12, &"painted_steel", 20)
	cyl(k, p + A * 1.2 + UP * 1.55, p + A * 2.0 + UP * 1.55, 0.18, &"gun_metal", 10)  # shaft
	cyl(k, p + A * 1.9 + UP * 1.55, p + A * 2.25 + UP * 1.55, 1.3, &"rusted_metal", 24)  # flywheel
	box(k, p - A * 2.1 + UP * 1.0, _sz(A, 0.6, 1.0, 1.6), &"painted_steel")  # exciter housing
	solid(k, p + UP * 1.4, _sz(A, 4.8, 2.8, 2.4))
	if r.randf() < 0.5:
		cyl(k, p + UP * 2.6, p + UP * 6.0, 0.18, &"rusted_metal", 8)  # cable conduit up


func _fallen_beam(k: Cell) -> void:
	var r := k.r
	var p := k.c + Vector3(r.randf_range(-1.5, 1.5), 0, r.randf_range(-1.5, 1.5))
	var a := p + Vector3(r.randf_range(-3, 3), r.randf_range(1.5, 3.5), r.randf_range(-3, 3))
	var b := p + Vector3(r.randf_range(-3, 3), 0.15, r.randf_range(-3, 3))
	cb.beam(k.d.geo, a, b, Vector2(0.3, 0.32), &"painted_steel", true)
	cb.kit(k.d, "rubble", b, r.randf() * TAU)
	_debris(k, 8, 0.6)


func _pallet_stack(k: Cell, p: Vector3) -> void:
	var r := cb.rng(k.x, k.z, k.s, 62)
	if not _free(k, Rect2(p.x - k.o.x - 0.8, p.z - k.o.z - 0.8, 1.6, 1.6)):
		return
	var n := r.randi_range(1, 6)
	var yaw := r.randf() * TAU
	for i in n:
		cb.kit(k.d, "pallet", p + UP * (i * 0.15), yaw + r.randf_range(-0.1, 0.1), {"collide": i == 0})
	if r.randf() < 0.5:
		cb.kit(k.d, "crate_wood", p + UP * (n * 0.15), yaw)
	solid(k, p + UP * (n * 0.075), Vector3(1.2, n * 0.15, 1.2), &"wood", Basis(Vector3.UP, yaw))


func _workbench_against_wall(k: Cell) -> void:
	for dir in 4:
		if _wall_free(k, dir):
			var t := k.r.randf_range(-2.0, 2.0)
			var p := _wall_at(k, dir, t, 0.4)
			var A := LevelLayout.dir_vector((dir + 1) % 4)
			if _free(k, _rect(k, p, A, 2.2, 0.9)):
				_workbench(k, p, A, -LevelLayout.dir_vector(dir))
			return


func _workbench(k: Cell, p: Vector3, A: Vector3, facing: Vector3) -> void:
	var r := cb.rng(k.x, k.z, k.s, 63)
	box(k, p + UP * 0.9, _sz(A, 2.0, 0.06, 0.8), &"prop_wood", true)
	for e: float in [-1.0, 1.0]:
		for f: float in [-1.0, 1.0]:
			box(k, p + A * (e * 0.92) + facing * (f * 0.34) + UP * 0.44, Vector3(0.06, 0.88, 0.06), &"painted_steel")
	box(k, p + UP * 0.25, _sz(A, 1.9, 0.03, 0.7), &"painted_steel")
	box(k, p - facing * 0.38 + UP * 1.5, _sz(A, 1.9, 1.1, 0.03), &"prop_wood")  # pegboard
	var turn := atan2(facing.x, facing.z)  # scanned models face +Z
	if cb.models.has("vice"):
		cb.kit(k.d, "vice", p + A * 0.7 + facing * 0.3 + UP * 0.93, turn, {"collide": false})
	else:
		box(k, p + A * 0.7 + facing * 0.3 + UP * 1.0, _sz(A, 0.2, 0.15, 0.15), &"painted_steel_blue")  # vise
	if cb.models.has("drill_press") and r.randf() < 0.3:
		cb.kit(k.d, "drill_press", p - A * 0.6 + UP * 0.93, turn + r.randf_range(-0.3, 0.3), {"collide": false})
	if cb.models.has("toolbox") and r.randf() < 0.4:
		cb.kit(k.d, "toolbox", p + A * r.randf_range(-0.2, 0.3) + facing * 0.05 + UP * 0.93, turn + r.randf_range(-0.5, 0.5),
			{"collide": false})
	if cb.models.has("stool") and r.randf() < 0.5:
		var q := p + facing * 0.75 + A * r.randf_range(-0.6, 0.6)
		if _room_for(k, q, A, 0.4, 0.4):
			cb.kit(k.d, "stool", q, r.randf() * TAU, {"collide": false})
	for i in r.randi_range(0, 2):
		var q := p + A * r.randf_range(-0.8, 0.8) + facing * r.randf_range(-0.2, 0.2) + UP * 0.97
		box(k, q, Vector3(r.randf_range(0.08, 0.3), r.randf_range(0.04, 0.12), r.randf_range(0.06, 0.2)), &"gun_metal", false, Basis(Vector3.UP, r.randf() * TAU))
	solid(k, p + UP * 0.47, _sz(A, 2.0, 0.94, 0.8), &"wood")


## Overhead travelling crane: rails along the long walls, one girder across
## the hall with a trolley and a hook left hanging.
func _crane(k: Cell, ix: Dictionary, A: Vector3, B: Vector3) -> void:
	if k.zn.top < 1:
		return
	var zr := _zone_rng(k.zn, 70)
	var y := (k.zn.top + 1) * H - 1.4
	var girder_at := zr.randi_range(1, maxi(int(ix["along_n"]) - 2, 1))
	var trolley_at := zr.randi_range(1, maxi(int(ix["across_n"]) - 2, 1))
	var hook_y := zr.randf_range(2.6, 5.5)
	var load := zr.randf()
	if ix["across"] == 0 or ix["across"] == ix["across_n"] - 1:
		var side := -1.0 if ix["across"] == 0 else 1.0
		var p := k.c + B * (side * (C * 0.5 - 0.5)) + UP * y
		box(k, p, _sz(A, C, 0.35, 0.3), &"painted_steel_yellow")
		box(k, p + UP * 0.22, _sz(A, C, 0.08, 0.08), &"gun_metal")
		box(k, p + B * (side * 0.3) + Vector3.DOWN * 0.3, _sz(A, 0.25, 0.9, 0.5), &"painted_steel")  # bracket
	if ix["along"] == girder_at:
		var p := k.c + UP * (y + 0.55)
		box(k, p, _sz(B, C, 0.9, 0.55), &"painted_steel_yellow")
		if ix["across"] == trolley_at:
			box(k, p + Vector3.DOWN * 0.7, _sz(A, 1.4, 0.6, 1.2), &"painted_steel")
			var hook := k.c + UP * hook_y
			for e: float in [-1.0, 1.0]:
				k.d.geo.cylinder(p + Vector3.DOWN * 1.0 + A * (e * 0.15), hook + UP * 0.4 + A * (e * 0.08), 0.02, &"gun_metal", 4)
			box(k, hook + UP * 0.2, _sz(A, 0.35, 0.55, 0.25), &"painted_steel_yellow")
			cyl(k, hook - UP * 0.05, hook - UP * 0.35, 0.05, &"gun_metal", 8)
			if load < 0.4:
				# A beam still slung from the hook
				for e: float in [-1.0, 1.0]:
					k.d.geo.cylinder(hook - UP * 0.35, hook - UP * 1.4 + A * (e * 1.4), 0.015, &"gun_metal", 4)
				box(k, hook - UP * 1.5, _sz(A, 3.4, 0.3, 0.25), &"rusted_metal")


func _hall_ducts(k: Cell, ix: Dictionary, A: Vector3, B: Vector3) -> void:
	if k.zn.top < 1:
		return
	var zr := _zone_rng(k.zn, 71)
	var side_i := 0 if zr.randf() < 0.5 else int(ix["across_n"]) - 1
	if ix["across"] != side_i:
		return
	var side := -1.0 if side_i == 0 else 1.0
	var y := (k.zn.top + 1) * H - 3.0
	var p := k.c + B * (side * (C * 0.5 - 1.0)) + UP * y
	cyl(k, p - A * (C * 0.5), p + A * (C * 0.5), 0.5, &"corrugated_metal", 14, false)
	cyl(k, p - A * 0.05, p + A * 0.05, 0.54, &"rusted_metal", 14)
	box(k, p + UP * 1.0, Vector3(0.06, 1.5, 0.06), &"gun_metal")


# --- Foundry -------------------------------------------------------------------------------

func _foundry(k: Cell) -> void:
	if k.s != 0:
		return
	var ix := _zone_index(k)
	var axes := _zone_axes(k.zn)
	var A: Vector3 = axes[0]
	var B: Vector3 = axes[1]
	var r := k.r
	_crane(k, ix, A, B)
	# The charging deck runs above one row of cells; furnaces stand along it.
	if L.kind_at(k.x, k.z, 1) == LevelLayout.Kind.CATWALK:
		var sides := (L.flags_at(k.x, k.z, 1) >> 4) & 15
		for side in 4:
			if sides & (1 << side) and int(ix["along"]) % 2 == 1:
				_furnace(k, side)
				return
		_wall_props(k, 0.4, ["barrel_rust", "crate_wood"])
		return
	var edge: bool = ix["across"] == 0 or ix["across"] == ix["across_n"] - 1 or ix["along"] == 0 or ix["along"] == ix["along_n"] - 1
	if edge:
		if r.randf() < 0.5:
			_slag_heap(k)
		else:
			_wall_props(k, 0.4, ["barrel_rust", "pallet", "crate_wood"])
		return
	var roll := r.randf()
	if roll < 0.45:
		_mould_rows(k, A)
	elif roll < 0.75:
		_ladle(k, k.c + A * r.randf_range(-1.5, 1.5), r.randf() < 0.35)
		if r.randf() < 0.5:
			_slag_heap(k)
	else:
		_slag_heap(k)
		_debris(k, 10, 0.5)


func _furnace(k: Cell, side: int) -> void:
	var inward := -LevelLayout.dir_vector(side)
	var p := k.c - inward * (C * 0.5) + inward * (LevelLayout.STRIP + 1.7)
	var rad := 1.55
	if not _free(k, Rect2(p.x - k.o.x - rad, p.z - k.o.z - rad, rad * 2, rad * 2)):
		return
	var h := 3.7
	cyl(k, p, p + UP * h, rad, &"brick", 20)
	for y: float in [0.5, 1.6, 2.7]:
		cyl(k, p + UP * y, p + UP * (y + 0.14), rad + 0.06, &"rusted_metal", 20)
	k.d.geo.frustum(p + UP * h, p + UP * (h + 0.5), rad, rad * 0.65, &"rusted_metal", 20, true)
	# Hood and flue up through the roof
	var top := (k.zn.top + 1) * H
	k.d.geo.frustum(p + UP * (h + 1.6), p + UP * (h + 2.6), rad * 1.15, 0.5, &"rusted_metal", 16, false)
	cyl(k, p + UP * (h + 2.6), p + UP * top, 0.45, &"rusted_metal", 12, false)
	for i in 3:
		var a := TAU * i / 3.0
		var off := Vector3(cos(a), 0, sin(a)) * rad * 1.1
		cb.beam(k.d.geo, p + off + UP * h, p + off * 0.9 + UP * (h + 1.6), Vector2(0.08, 0.08), &"gun_metal")
	# Tapping spout and a trough toward the floor
	var spout := p + inward * rad + UP * 0.9
	box(k, spout + inward * 0.4, _sz(inward, 0.9, 0.25, 0.35), &"rusted_metal", false, Basis(_across(inward), -0.25 if absf(inward.x) > 0.5 else 0.25))
	box(k, p + inward * (rad + 1.3) + UP * 0.2, _sz(inward, 1.2, 0.4, 0.6), &"concrete_dark", true)
	decal(k, "oil", p + inward * (rad + 1.2), Vector3(2.8, 0.6, 2.8), k.r.randf() * TAU)
	solid(k, p + UP * (h * 0.5), Vector3(rad * 2, h, rad * 2), &"concrete")


func _mould_rows(k: Cell, A: Vector3) -> void:
	var r := cb.rng(k.x, k.z, k.s, 64)
	var B := _across(A)
	for row: float in [-2.0, 0.0, 2.0]:
		var p := k.c + B * row
		if not _free(k, _rect(k, p, A, 5.6, 1.0)):
			continue
		for i in 4:
			var q := p + A * (-2.1 + i * 1.4)
			if r.randf() < 0.15:
				# Broken open, sand spilled
				box(k, q + UP * 0.1, _sz(A, 1.3, 0.2, 0.9), &"concrete_floor", false, Basis(Vector3.UP, r.randf_range(-0.3, 0.3)))
				continue
			box(k, q + UP * 0.22, _sz(A, 1.2, 0.44, 0.8), &"painted_steel", false)
			box(k, q + UP * 0.45, _sz(A, 1.1, 0.02, 0.7), &"concrete_floor")
			cyl(k, q + UP * 0.46, q + UP * 0.5, 0.12, &"soot", 10)  # sprue
		solid(k, p + UP * 0.25, _sz(A, 5.6, 0.5, 0.9))


func _ladle(k: Cell, p: Vector3, tipped: bool) -> void:
	if not _free(k, Rect2(p.x - k.o.x - 1.3, p.z - k.o.z - 1.3, 2.6, 2.6)):
		return
	var r := cb.rng(k.x, k.z, k.s, 65)
	var tilt := Basis(Vector3(1, 0, 0).rotated(Vector3.UP, r.randf() * TAU), 1.3) if tipped else Basis.IDENTITY
	var base := p + (UP * 0.95 if tipped else Vector3.ZERO)
	var axis := tilt * UP
	k.d.geo.frustum(base, base + axis * 1.5, 0.85, 1.05, &"rusted_metal", 18, false)
	k.d.geo.frustum(base, base + axis * 0.05, 0.0, 0.85, &"rusted_metal", 18, false)
	var side := tilt * Vector3(1, 0, 0)
	for e: float in [-1.0, 1.0]:
		cyl(k, base + axis * 1.0 + side * (e * 1.0), base + axis * 1.0 + side * (e * 1.25), 0.12, &"gun_metal", 8)
	if tipped:
		# Slag frozen where it poured out
		var mouth := base + axis * 1.6
		for i in 6:
			var q := Vector3(mouth.x, 0.06, mouth.z) + Vector3(r.randf_range(-1.0, 1.0), 0, r.randf_range(-1.0, 1.0))
			box(k, q, Vector3(r.randf_range(0.4, 1.1), r.randf_range(0.06, 0.14), r.randf_range(0.4, 1.0)), &"soot", false, Basis(Vector3.UP, r.randf() * TAU))
	solid(k, p + UP * 0.8, Vector3(2.0, 1.6, 2.0))


func _slag_heap(k: Cell) -> void:
	var r := cb.rng(k.x, k.z, k.s, 66)
	var p := k.c + Vector3(r.randf_range(-2, 2), 0, r.randf_range(-2, 2))
	if not _free(k, Rect2(p.x - k.o.x - 1.5, p.z - k.o.z - 1.5, 3.0, 3.0)):
		return
	for i in 9:
		var q := p + Vector3(r.randf_range(-1.2, 1.2), 0, r.randf_range(-1.2, 1.2))
		var s := Vector3(r.randf_range(0.5, 1.2), r.randf_range(0.3, 0.9), r.randf_range(0.5, 1.2))
		box(k, q + UP * s.y * 0.35, s, &"soot", false, Basis.from_euler(Vector3(r.randf_range(-0.3, 0.3), r.randf() * TAU, r.randf_range(-0.3, 0.3))))
	solid(k, p + UP * 0.4, Vector3(2.4, 0.8, 2.4), &"concrete")


# --- Processing ----------------------------------------------------------------------------

func _processing_floor(k: Cell) -> void:
	if k.s != 0:
		return
	var ix := _zone_index(k)
	var axes := _zone_axes(k.zn)
	var A: Vector3 = axes[0]
	var edge: bool = ix["across"] == 0 or ix["across"] == ix["across_n"] - 1 or ix["along"] == 0 or ix["along"] == ix["along_n"] - 1
	if edge:
		_wall_props(k, 0.5, ["electrical_cabinet", "barrel_blue", "barrel_orange"])
		return
	var r := k.r
	if r.randf() < 0.5:
		_reactor(k, k.c)
	elif _free(k, Rect2(C * 0.5 - 1.4, C * 0.5 - 1.4, 2.8, 2.8)):
		cb.kit(k.d, "vat", k.c, r.randf() * TAU)
	# Manifold pipe along the row joining the vessels
	var y := 3.3
	cyl(k, k.c - A * (C * 0.5) + UP * y + _across(A) * 1.6, k.c + A * (C * 0.5) + UP * y + _across(A) * 1.6, 0.16, &"painted_steel_green", 10, false)
	cyl(k, k.c + _across(A) * 1.6 + UP * y, k.c + _across(A) * 0.6 + UP * (y + 0.6), 0.1, &"painted_steel_green", 8, false)
	_valve(k, k.c - A * 1.5 + UP * y + _across(A) * 1.85, A)


func _reactor(k: Cell, p: Vector3) -> void:
	if not _free(k, Rect2(p.x - k.o.x - 1.4, p.z - k.o.z - 1.4, 2.8, 2.8)):
		return
	var r := cb.rng(k.x, k.z, k.s, 67)
	var h := r.randf_range(4.0, 6.0)
	for i in 4:
		var a := TAU * i / 4.0 + 0.4
		box(k, p + Vector3(cos(a), 0, sin(a)) * 1.0 + UP * 0.6, Vector3(0.14, 1.2, 0.14), &"painted_steel")
	cyl(k, p + UP * 1.0, p + UP * h, 1.15, &"painted_steel", 20)
	k.d.geo.frustum(p + UP * h, p + UP * (h + 0.6), 1.15, 0.4, &"painted_steel", 20, true)
	k.d.geo.frustum(p + UP * 1.0, p + UP * 0.6, 1.15, 0.3, &"painted_steel", 20, true)
	for y: float in [1.8, 3.0]:
		if y < h:
			cyl(k, p + UP * y, p + UP * (y + 0.1), 1.2, &"rusted_metal", 20)
	# Ladder
	var side := Vector3(1, 0, 0).rotated(Vector3.UP, r.randf() * TAU)
	var ladder := p + side * 1.3
	for e: float in [-1.0, 1.0]:
		var off := side.cross(UP) * (e * 0.22)
		cyl(k, ladder + off, ladder + off + UP * h, 0.025, &"painted_steel_yellow", 6, false)
	for i in int(h / 0.3):
		cyl(k, ladder - side.cross(UP) * 0.22 + UP * (0.3 + i * 0.3), ladder + side.cross(UP) * 0.22 + UP * (0.3 + i * 0.3), 0.015, &"painted_steel_yellow", 4, false)
	solid(k, p + UP * (h * 0.5), Vector3(2.4, h, 2.4))


func _valve(k: Cell, p: Vector3, axis: Vector3) -> void:
	var n := 10
	var rad := 0.25
	var B := _across(axis)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		k.d.geo.cylinder(p + (B * cos(a0) + UP * sin(a0)) * rad, p + (B * cos(a1) + UP * sin(a1)) * rad, 0.02, &"painted_steel_red", 4)
	k.d.geo.cylinder(p - B * rad, p + B * rad, 0.015, &"painted_steel_red", 4)
	k.d.geo.cylinder(p - UP * rad, p + UP * rad, 0.015, &"painted_steel_red", 4)


# --- Warehouse -----------------------------------------------------------------------------

const RACK_DEPTH := 2.3
const RACK_PITCH := 5.6
const RACK_BAY := 2.7


func _warehouse(k: Cell) -> void:
	if k.s != 0:
		return
	var ix := _zone_index(k)
	var axes := _zone_axes(k.zn)
	var A: Vector3 = axes[0]
	var B: Vector3 = axes[1]
	var along_x: bool = axes[2]
	var r := k.r
	var edge_along: bool = ix["along"] == 0 or ix["along"] == ix["along_n"] - 1
	var cross_aisle: bool = int(ix["along_n"]) >= 4 and int(ix["along"]) % 3 == 2
	if edge_along or cross_aisle:
		if r.randf() < 0.25:
			_forklift(k, k.c + A * r.randf_range(-1.5, 1.5), A if r.randf() < 0.5 else B)
		elif r.randf() < 0.5:
			_pallet_stack(k, k.c + B * r.randf_range(-2.5, 2.5))
		_wall_props(k, 0.35, ["pallet", "crate_wood", "barrel_orange"])
		return
	# Rack rows across the zone in zone metres; this cell builds the parts it covers.
	var width: float = float(ix["across_n"]) * C
	var u0: float = float(ix["across"]) * C
	var top_y := (k.zn.top + 1) * H - 1.4
	var any := false
	var row_start := 1.2
	while row_start + RACK_DEPTH <= width - 1.0:
		var b0 := maxf(row_start, u0)
		var b1 := minf(row_start + RACK_DEPTH, u0 + C)
		if b1 - b0 > 0.2:
			var mid := (b0 + b1) * 0.5 - u0 - C * 0.5
			var p := k.c + B * mid
			if _free(k, _rect(k, p, A, C, b1 - b0)):
				_rack(k, p, A, B, b1 - b0, top_y, (b0 + b1) * 0.5 - row_start - RACK_DEPTH * 0.5)
				any = true
		row_start += RACK_PITCH
	if not any and r.randf() < 0.3:
		_forklift(k, k.c, A)


## One cell-long piece of a double pallet rack, `depth` wide across B.
func _rack(k: Cell, p: Vector3, A: Vector3, B: Vector3, depth: float, top_y: float, offset: float) -> void:
	var r := cb.rng(k.x, k.z, k.s, 68 + int(offset * 10.0))
	var levels: Array[float] = []
	var y := 0.15
	while y < top_y - 0.5:
		levels.append(y)
		y += 1.55
	var height: float = (levels.back() + 1.3) if not levels.is_empty() else 2.0
	var collapsed := r.randf() < 0.1
	var a_start := (k.x * C if absf(A.x) > 0.5 else k.z * C)
	# Uprights on a 2.7 m grid in world metres so pieces line up across cells.
	var first := ceilf(a_start / RACK_BAY) * RACK_BAY - a_start
	var uprights: Array[float] = []
	var a := first
	while a <= C + 0.001:
		uprights.append(a - C * 0.5)
		a += RACK_BAY
	var faces: Array[float] = []
	var half := depth * 0.5
	for e: float in [-1.0, 1.0]:
		faces.append(e * (half - 0.05))
	for ua in uprights:
		for f in faces:
			var q := p + A * ua + B * f
			if collapsed and r.randf() < 0.5:
				box(k, q + UP * (height * 0.25) + A * 0.3, Vector3(0.09, height * 0.5, 0.09), &"painted_steel_orange", false,
					Basis(B, r.randf_range(-0.5, 0.5)))
				continue
			box(k, q + UP * (height * 0.5), Vector3(0.09, height, 0.09), &"painted_steel_orange")
		box(k, p + A * ua + UP * (height * 0.5), _sz(B, depth - 0.1, 0.04, 0.04), &"painted_steel_orange")  # tie
	for lv in levels:
		if collapsed and lv > 0.2:
			continue
		for f in faces:
			box(k, p + B * f + UP * (lv + 0.08), _sz(A, C, 0.12, 0.06), &"painted_steel_blue")
		# Loads in each bay on both sides
		for i in uprights.size() - 1 if uprights.size() > 1 else 1:
			var c0: float = uprights[i] if uprights.size() > 1 else -C * 0.5
			var c1: float = uprights[i + 1] if uprights.size() > 1 else C * 0.5
			for f in faces:
				var roll := r.randf()
				if roll < 0.28:
					continue
				var q := p + A * ((c0 + c1) * 0.5) + B * (f * 0.5) + UP * (lv + 0.14)
				_rack_load(k, q, A, minf(c1 - c0 - 0.2, 2.4), half - 0.2, roll, r)
	if collapsed:
		# Everything on the floor in the aisle
		for i in 8:
			var q := p + A * r.randf_range(-3.5, 3.5) + B * r.randf_range(-depth, depth) * 1.2
			var sz := Vector3(r.randf_range(0.4, 1.1), r.randf_range(0.3, 0.8), r.randf_range(0.4, 1.0))
			box(k, q + UP * sz.y * 0.4, sz, &"prop_wood" if r.randf() < 0.6 else &"fabric_canvas", false,
				Basis.from_euler(Vector3(r.randf_range(-0.6, 0.6), r.randf() * TAU, r.randf_range(-0.6, 0.6))))
		cb.beam(k.d.geo, p + A * -2.0 + UP * 0.1, p + A * 2.5 + B * 1.4 + UP * 1.6, Vector2(0.1, 0.12), &"painted_steel_blue")
		solid(k, p + UP * 0.6, _sz(A, C, 1.2, depth), &"wood")
	else:
		solid(k, p + UP * (height * 0.5), _sz(A, C, height, depth), &"metal")


func _rack_load(k: Cell, q: Vector3, A: Vector3, length: float, depth: float, roll: float, r: RandomNumberGenerator) -> void:
	var B := _across(A)
	box(k, q + UP * 0.07, _sz(A, minf(length, 1.2), 0.14, minf(depth, 1.0)), &"prop_wood")  # pallet
	if roll < 0.75:
		var h := r.randf_range(0.5, 1.2)
		var mat := &"fabric_canvas" if r.randf() < 0.5 else &"prop_wood"
		box(k, q + UP * (0.14 + h * 0.5), _sz(A, minf(length, 1.15) * r.randf_range(0.8, 1.0), h, minf(depth, 0.95) * r.randf_range(0.8, 1.0)), mat)
	elif roll < 0.9:
		# Drums two by two, or in a single row where the load is shallow
		# (loads from both faces meet in the middle of the rack).
		var rows: Array[float] = [0.0]
		if depth >= 1.1:
			rows = [-0.28, 0.28]
		for e: float in [-1.0, 1.0]:
			for f in rows:
				var b := q + A * (e * 0.28) + B * f + UP * 0.143
				cyl(k, b, b + UP * 0.85, 0.27, &"prop_steel_blue" if r.randf() < 0.5 else &"prop_rust", 10)
	else:
		# Spilled: boxes half off the edge
		box(k, q + UP * 0.4 + B * 0.3, Vector3(0.6, 0.5, 0.6), &"prop_wood", false, Basis.from_euler(Vector3(0.4, r.randf() * TAU, 0.2)))


func _forklift(k: Cell, p: Vector3, A: Vector3) -> void:
	if not _free(k, _rect(k, p, A, 3.2, 1.4)):
		return
	var B := _across(A)
	var r := cb.rng(k.x, k.z, k.s, 69)
	if r.randf() < 0.5:
		A = -A
	box(k, p + UP * 0.6, _sz(A, 2.2, 0.8, 1.15), &"painted_steel_yellow", true)  # body
	box(k, p - A * 0.82 + UP * 0.75, _sz(A, 0.6, 0.9, 1.1), &"gun_metal")  # counterweight, proud of the body
	box(k, p - A * 0.2 + UP * 1.15, _sz(A, 0.5, 0.15, 0.6), &"prop_rubber")  # seat
	for e: float in [-1.0, 1.0]:
		box(k, p + A * 0.2 + B * (e * 0.55) + UP * 1.6, Vector3(0.06, 1.8, 0.06), &"gun_metal")  # overhead guard
		for f: float in [-0.7, 0.7]:
			cyl(k, p + A * f + B * (e * 0.62) + UP * 0.3, p + A * f + B * (e * 0.45) + UP * 0.3, 0.3, &"prop_rubber", 12)
	box(k, p + A * 0.2 + UP * 2.5, _sz(A, 1.0, 0.06, 1.15), &"gun_metal")
	box(k, p + A * 1.2 + UP * 1.3, _sz(A, 0.12, 2.6, 0.9), &"gun_metal")  # mast
	var fork_y := r.randf_range(0.1, 1.5)
	for e: float in [-1.0, 1.0]:
		box(k, p + A * 1.8 + B * (e * 0.3) + UP * fork_y, _sz(A, 1.1, 0.05, 0.12), &"gun_metal")
	if r.randf() < 0.4:
		cb.kit(k.d, "pallet", p + A * 1.8 + UP * (fork_y + 0.05), atan2(A.x, A.z), {"collide": false})


# --- Loading dock --------------------------------------------------------------------------

func _dock(k: Cell) -> void:
	if k.s != 0:
		return
	var r := k.r
	if L.has_flag(k.x, k.z, 0, LevelLayout.DOCK):
		# Dock leveller and bollards in front of each shutter
		for dir in 4:
			if L.is_outside(k.x, k.z, 0, dir) and not L.has_door(k.x, k.z, 0, dir):
				var p := _wall_at(k, dir, 0.0, 1.2)
				var A := LevelLayout.dir_vector((dir + 1) % 4)
				box(k, p + UP * 0.02, _sz(A, 3.2, 0.04, 2.2), &"painted_steel_yellow")
				for e: float in [-1.0, 1.0]:
					var b := _wall_at(k, dir, e * 3.0, 0.4)
					cyl(k, b, b + UP * 1.0, 0.12, &"painted_steel_yellow", 10)
				return
	var interior := true
	for dir in 4:
		if L.has_wall(k.x, k.z, k.s, dir):
			interior = false
	if interior and r.randf() < 0.4 and _free(k, Rect2(0.8, 0.8, C - 1.6, C - 1.6)):
		cb.kit(k.d, "shipping_container", k.c, (PI * 0.5) * r.randi_range(0, 1) + r.randf_range(-0.06, 0.06))
		return
	var roll := r.randf()
	if roll < 0.3:
		_forklift(k, k.c, Vector3(1, 0, 0) if r.randf() < 0.5 else Vector3(0, 0, 1))
	elif roll < 0.7:
		_pallet_stack(k, k.c + Vector3(r.randf_range(-2, 2), 0, r.randf_range(-2, 2)))
	_wall_props(k, 0.4, ["pallet", "crate_wood", "barrel_rust"])


# --- Clutter: the odds and ends of a works ---------------------------------------------------

## A few of the things that pile up in a factory, wherever there's room
## left: against the walls (cylinders, panels, tool chests, ladders, sacks,
## extinguishers, junction boxes) and out on the floor (spools, pipe
## bundles, fans, dollies, chains, buckets).
func _clutter(k: Cell) -> void:
	var r := cb.rng(k.x, k.z, k.s, 150)
	var fam := k.zn.style.family if k.zn.style else &"factory"
	var count := r.randi_range(1, 3) if fam == &"factory" else r.randi_range(0, 2)
	if k.zn.type in ChunkBuilder.TALL:
		count += 1
	var wall_items := ["gas_cylinders", "panel", "tool_chest", "ladder", "sacks", "extinguisher", "junction", "drums"]
	var floor_items := ["spool", "pipes", "fan", "dolly", "chain", "buckets", "worklight", "tyre", "cardboard", "toolbox"]
	if fam == &"interior":
		wall_items = ["panel", "extinguisher", "junction", "ladder", "sacks", "tool_chest"]
		floor_items = ["buckets", "dolly", "fan", "spool", "wet_sign", "cardboard"]
	for i in count:
		if r.randf() < 0.6:
			_clutter_wall(k, r, wall_items[r.randi_range(0, wall_items.size() - 1)])
		else:
			_clutter_floor(k, r, floor_items[r.randi_range(0, floor_items.size() - 1)])


## Room for a footprint (world centre, half sizes along A and across) clear of
## lanes and of everything solid already in the cell.
func _room_for(k: Cell, c: Vector3, A: Vector3, la: float, lb: float) -> bool:
	if not _free(k, _rect(k, c, A, la, lb)):
		return false
	var ab := AABB(c + Vector3(0, 0.05, 0), Vector3.ZERO).grow(0.0)
	var B := _across(A)
	ab = AABB(c - A * la * 0.5 - B * lb * 0.5 + Vector3.UP * 0.05, Vector3.ZERO).expand(c + A * la * 0.5 + B * lb * 0.5 + Vector3.UP * 1.8)
	for t in k.d.taken:
		if t.intersects(ab):
			return false
	k.d.taken.append(ab)
	return true


func _clutter_wall(k: Cell, r: RandomNumberGenerator, item: String) -> void:
	var dirs: Array[int] = []
	for dir in 4:
		if _wall_free(k, dir):
			dirs.append(dir)
	if dirs.is_empty():
		return
	var dir: int = dirs[r.randi_range(0, dirs.size() - 1)]
	var N := -LevelLayout.dir_vector(dir)
	var A := LevelLayout.dir_vector((dir + 1) % 4)
	var t := r.randf_range(-2.8, 2.8)
	var base := _wall_at(k, dir, t, 0.0)
	if L.has_split(k.x, k.z, k.s) and not _free(k, _rect(k, base + N * 0.3, A, 0.9, 0.5)):
		return  # against the partition
	match item:
		"gas_cylinders":
			var n := r.randi_range(2, 5)
			if not _room_for(k, base + N * 0.2, A, n * 0.3, 0.4):
				return
			var mat: StringName = [&"painted_steel_green", &"painted_steel_blue", &"painted_steel_red", &"painted_steel_yellow"][r.randi_range(0, 3)]
			for i in n:
				var p := base + N * 0.18 + A * ((i - (n - 1) * 0.5) * 0.28)
				if r.randf() < 0.15:
					# One has fallen and rolled.
					var q := p + N * r.randf_range(0.8, 1.6)
					var ax := Vector3(r.randf_range(-1, 1), 0, r.randf_range(-1, 1)).normalized()
					cyl(k, q + Vector3.UP * 0.12 - ax * 0.7, q + Vector3.UP * 0.12 + ax * 0.7, 0.12, mat, 10)
					continue
				cyl(k, p, p + UP * 1.35, 0.12, mat, 10)
				cyl(k, p + UP * 1.35, p + UP * 1.5, 0.05, &"gun_metal", 6)
			k.d.geo.cylinder(base + N * 0.05 + A * (-n * 0.15) + UP * 1.0, base + N * 0.05 + A * (n * 0.15) + UP * 1.0, 0.012, &"rusted_metal", 4)  # chain
		"panel":
			if not _room_for(k, base + N * 0.25, A, 1.3, 0.5):
				return
			var mat: StringName = [&"painted_steel_green", &"painted_steel", &"painted_steel_blue"][r.randi_range(0, 2)]
			box(k, base + N * 0.25 + UP * 0.95, _sz(A, 1.2, 1.9, 0.5), mat, true)
			for i in r.randi_range(2, 5):
				var g := base + N * 0.51 + A * r.randf_range(-0.45, 0.45) + UP * r.randf_range(1.2, 1.7)
				k.d.geo.cylinder(g, g + N * 0.03, 0.06, &"paper", 10, true)  # gauges
			for i in r.randi_range(3, 8):
				var b := base + N * 0.51 + A * r.randf_range(-0.5, 0.5) + UP * r.randf_range(0.9, 1.15)
				k.d.geo.cylinder(b, b + N * 0.02, 0.02, [&"painted_steel_red", &"painted_steel_yellow", &"gun_metal"][r.randi_range(0, 2)], 6, true)
			if r.randf() < 0.5:
				# Door hanging open, wiring spilling out.
				box(k, base + N * 0.75 + A * 0.55 + UP * 0.95, _sz(A, 0.03, 1.8, 0.55), mat, false, Basis(UP, 0.5))
				for i in 4:
					var w0 := base + N * 0.45 + A * r.randf_range(-0.4, 0.4) + UP * r.randf_range(0.6, 1.4)
					k.d.geo.cylinder(w0, w0 + N * r.randf_range(0.2, 0.5) + UP * -r.randf_range(0.3, 0.8), 0.01, &"cable", 4)
		"tool_chest":
			if not _room_for(k, base + N * 0.3, A, 0.8, 0.6):
				return
			if cb.models.has("tool_chest"):
				cb.kit(k.d, "tool_chest", base + N * (cb.models.size("tool_chest").z * 0.5 + 0.03), _face_from_wall(dir) + PI)
				return
			box(k, base + N * 0.3 + UP * 0.5, _sz(A, 0.75, 1.0, 0.5), &"painted_steel_red", true)
			for i in 5:
				box(k, base + N * 0.56 + UP * (0.15 + i * 0.17), _sz(A, 0.68, 0.14, 0.02), &"painted_steel_red")
				box(k, base + N * 0.58 + UP * (0.15 + i * 0.17), _sz(A, 0.3, 0.02, 0.02), &"gun_metal")
		"ladder":
			if cb.models.has("ladder") and r.randf() < 0.5:
				var lean := 0.24
				var at := base + N * (cb.models.size("ladder").y * sin(lean) + 0.12)
				if _room_for(k, at - N * 0.25, A, 0.8, 0.7):
					cb.kit(k.d, "ladder", at, _face_from_wall(dir) + PI, {}, Basis(Vector3.RIGHT, -lean))
				return
			var h := r.randf_range(2.6, 3.4)
			var lean := 0.28
			var foot := base + N * (h * sin(lean))
			for e: float in [-0.22, 0.22]:
				k.d.geo.cylinder(foot + A * e, base + N * 0.05 + A * e + UP * h * cos(lean), 0.025, &"rusted_metal", 6)
			for i in int(h / 0.3):
				var f := float(i + 1) / int(h / 0.3 + 1)
				var p := foot.lerp(base + N * 0.05 + UP * h * cos(lean), f)
				k.d.geo.cylinder(p - A * 0.22, p + A * 0.22, 0.015, &"rusted_metal", 4)
		"sacks":
			if not _room_for(k, base + N * 0.5, A, 1.4, 1.0):
				return
			for i in r.randi_range(3, 7):
				var p := base + N * r.randf_range(0.3, 0.8) + A * r.randf_range(-0.6, 0.6) + UP * (0.12 + (i / 3) * 0.2)
				box(k, p, _sz(A, 0.55, 0.22, 0.35), &"fabric_canvas", false, Basis(UP, r.randf_range(-0.3, 0.3)) * Basis(A, r.randf_range(-0.1, 0.1)))
		"extinguisher":
			var p := base + N * 0.12 + UP * 1.0
			k.d.geo.cylinder(p, p + UP * 0.5, 0.08, &"painted_steel_red", 10, true)
			k.d.geo.cylinder(p + UP * 0.5, p + UP * 0.58, 0.03, &"gun_metal", 6)
			box(k, p + UP * 0.3 - N * 0.06, _sz(A, 0.12, 0.08, 0.04), &"gun_metal")  # bracket
			box(k, base + N * 0.015 + UP * 1.85, _sz(A, 0.25, 0.25, 0.02), &"painted_steel_red")  # sign
		"junction":
			for i in r.randi_range(1, 3):
				var p := base + N * 0.08 + A * (i * 0.5 - 0.5) + UP * r.randf_range(1.4, 2.1)
				box(k, p, _sz(A, 0.35, 0.45, 0.16), &"painted_steel")
				k.d.geo.cylinder(p + UP * 0.22, p + UP * 2.4, 0.025, &"gun_metal", 6)  # conduit up to the ceiling
		"drums":
			for q in _cluster(r, base + N * 0.55, r.randi_range(2, 4)):
				if _room_for(k, q, A, 0.6, 0.6):
					cb.kit(k.d, drum(r), q, r.randf() * TAU)


func _clutter_floor(k: Cell, r: RandomNumberGenerator, item: String) -> void:
	var p := k.o + Vector3(r.randf_range(1.2, C - 1.2), 0, r.randf_range(1.2, C - 1.2))
	var A := Vector3(1, 0, 0) if r.randf() < 0.5 else Vector3(0, 0, 1)
	var B := _across(A)
	match item:
		"spool":
			if not _room_for(k, p, A, 1.3, 1.3):
				return
			if r.randf() < 0.5:
				cyl(k, p, p + UP * 0.08, 0.6, &"prop_wood", 14)
				cyl(k, p + UP * 0.08, p + UP * 0.72, 0.32, &"cable", 12)
				cyl(k, p + UP * 0.72, p + UP * 0.8, 0.6, &"prop_wood", 14)
			else:
				var c := p + UP * 0.6
				cyl(k, c - A * 0.4, c - A * 0.32, 0.6, &"prop_wood", 14)
				cyl(k, c - A * 0.32, c + A * 0.32, 0.32, &"cable", 12)
				cyl(k, c + A * 0.32, c + A * 0.4, 0.6, &"prop_wood", 14)
				# Cable unrolled across the floor.
				var e := c + B * 0.3 + Vector3.DOWN * 0.58
				k.d.geo.cylinder(e, e + B * r.randf_range(1.5, 3.0) + A * r.randf_range(-1.0, 1.0), 0.03, &"cable", 6)
		"pipes":
			if not _room_for(k, p, A, 3.2, 0.8):
				return
			var n := r.randi_range(3, 6)
			for i in n:
				var row := i % 3
				var layer := i / 3
				var q := p + B * ((row - 1) * 0.22 + layer * 0.11) + UP * (0.1 + layer * 0.19)
				cyl(k, q - A * 1.5, q + A * 1.5, 0.1, &"rusted_metal", 10)
			for e: float in [-1.0, 1.0]:
				box(k, p + A * (e * 1.1) + UP * 0.03, _sz(A, 0.1, 0.06, 0.8), &"prop_wood")  # bearers
		"fan":
			if not _room_for(k, p, A, 1.0, 1.0):
				return
			var h := 1.3
			k.d.geo.cylinder(p, p + UP * h, 0.03, &"gun_metal", 6)
			for i in 3:
				var a := TAU * i / 3.0
				k.d.geo.cylinder(p + UP * 0.02, p + Vector3(cos(a), 0, sin(a)) * 0.35, 0.02, &"gun_metal", 4)
			var spin := r.randf() * TAU
			var face := Vector3(cos(spin), 0, sin(spin))
			k.d.geo.frustum(p + UP * h - face * 0.12, p + UP * h + face * 0.12, 0.45, 0.42, &"painted_steel", 14, false)
			k.d.geo.cylinder(p + UP * h, p + UP * h + face * 0.02, 0.4, &"steel_grate", 14, true)
		"dolly":
			if not _room_for(k, p, A, 0.8, 0.6):
				return
			var yaw := r.randf() * TAU
			if cb.models.has("hand_truck"):
				cb.kit(k.d, "hand_truck", p, yaw)
				return
			var b := Basis(UP, yaw) * Basis(Vector3.RIGHT, -0.35)
			for e: float in [-0.2, 0.2]:
				k.d.geo.cylinder(p + Basis(UP, yaw) * Vector3(e, 0.18, 0), p + b * Vector3(e, 1.3, 0) + Vector3.UP * 0.18, 0.02, &"painted_steel_red", 6)
				k.d.geo.cylinder(p + Basis(UP, yaw) * Vector3(e * 1.3, 0.12, 0.12), p + Basis(UP, yaw) * Vector3(e * 1.3 + 0.06 * signf(e), 0.12, 0.12), 0.12, &"rubber", 10, true)
			box(k, p + Basis(UP, yaw) * Vector3(0, 0.03, -0.2), Vector3(0.4, 0.02, 0.3), &"gun_metal", false, Basis(UP, yaw))
		"chain":
			var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
			# The anchor plate ends at the underside of the slab (0.3 thick).
			var top := k.o.y + minf(hc, H * (k.zn.top + 1 - k.s) if k.zn.type in ChunkBuilder.TALL else hc) - 0.4
			var len := r.randf_range(1.2, top - k.o.y - 1.9)
			if len < 0.6:
				return
			var q := Vector3(p.x, top, p.z)
			for i in int(len / 0.09):
				var y := top - i * 0.09
				var b := Basis(UP, (PI * 0.5) * (i % 2))
				k.d.geo.box(Vector3(p.x, y - 0.045, p.z), b * Vector3(0.012, 0.09, 0.05), &"rusted_metal", &"", false, b)
			var hook := Vector3(p.x, top - len, p.z)
			k.d.geo.cylinder(hook, hook + Vector3.DOWN * 0.18 + A * 0.08, 0.025, &"gun_metal", 6)
			k.d.geo.cylinder(q, q + Vector3.UP * 0.1, 0.06, &"gun_metal", 6, true)
		"buckets":
			for i in r.randi_range(1, 3):
				var q := p + Vector3(r.randf_range(-0.6, 0.6), 0, r.randf_range(-0.6, 0.6))
				if r.randf() < 0.3:
					var ax := Vector3(r.randf_range(-1, 1), 0, r.randf_range(-1, 1)).normalized()
					k.d.geo.frustum(q + UP * 0.15 - ax * 0.17, q + UP * 0.15 + ax * 0.17, 0.12, 0.15, &"prop_rust", 10, true)
				else:
					k.d.geo.frustum(q, q + UP * 0.34, 0.12, 0.15, [&"prop_rust", &"painted_steel_blue", &"prop_steel"][r.randi_range(0, 2)], 10, true)
			if r.randf() < 0.5:
				k.d.geo.cylinder(p + UP * 0.05, p + Vector3(0.9, 1.2, 0.3), 0.015, &"prop_wood", 4)  # mop handle against the bucket
		"worklight":
			if not _room_for(k, p, A, 0.9, 0.9):
				return
			for i in 3:
				var a := TAU * i / 3.0
				k.d.geo.cylinder(p + Vector3(cos(a), 0, sin(a)) * 0.35, p + UP * 1.4, 0.015, &"painted_steel_yellow", 4)
			var head := p + UP * 1.55
			var face := Vector3(cos(r.randf() * TAU), -0.3, sin(r.randf() * TAU)).normalized()
			k.d.geo.box(head, Vector3(0.3, 0.22, 0.12), &"painted_steel_yellow", &"", false, Basis.looking_at(face, UP))
			k.d.geo.box(head + face * 0.065, Vector3(0.24, 0.16, 0.01), &"lamp_dead", &"", false, Basis.looking_at(face, UP))
		"tyre":
			if not cb.models.has("tyre") or not _room_for(k, p, A, 0.8, 0.8):
				return
			var sz := cb.models.size("tyre")
			var turn := r.randf() * TAU
			if r.randf() < 0.6:
				# Lying flat, maybe another on top.
				for i in r.randi_range(1, 2):
					var t := turn + i * 0.4
					cb.kit(k.d, "tyre", p + UP * (sz.z * 0.5 + i * sz.z) - Basis(UP, t) * Vector3(0, 0, sz.y * 0.5) + Vector3(i * 0.05, 0, 0), t, {},
						Basis(Vector3.RIGHT, PI * 0.5))
			else:
				cb.kit(k.d, "tyre", p, turn)
		"cardboard":
			if not cb.models.has("cardboard_box") or not _room_for(k, p, A, 1.2, 1.2):
				return
			for i in r.randi_range(1, 3):
				var q := p + Vector3(r.randf_range(-0.4, 0.4), 0, r.randf_range(-0.4, 0.4))
				if r.randf() < 0.3:
					# Knocked on its side.
					cb.kit(k.d, "cardboard_box", q + UP * cb.models.size("cardboard_box").z * 0.5, r.randf() * TAU, {},
						Basis(Vector3.RIGHT, PI * 0.5))
				else:
					cb.kit(k.d, "cardboard_box", q, r.randf() * TAU)
		"toolbox":
			if cb.models.has("toolbox") and _room_for(k, p, A, 0.5, 0.5):
				cb.kit(k.d, "toolbox", p, r.randf() * TAU)
		"wet_sign":
			if cb.models.has("wet_floor_sign") and _room_for(k, p, A, 0.5, 0.5):
				cb.kit(k.d, "wet_floor_sign", p, r.randf() * TAU)


# --- Yards and open ground ----------------------------------------------------------------

## Open-air courtyard: cracked asphalt gone to weeds, puddles, whatever was
## dumped there.
func _yard(k: Cell) -> void:
	var r := k.r
	_weeds(k, r, r.randi_range(6, 16))
	for i in r.randi_range(1, 3):
		var p := k.o + Vector3(r.randf_range(1.0, C - 1.0), 0, r.randf_range(1.0, C - 1.0))
		decal(k, ["moss", "puddle", "crack", "oil"][r.randi_range(0, 3)], p, Vector3(r.randf_range(1.5, 3.5), 0.5, r.randf_range(1.5, 3.5)), r.randf() * TAU)
	var roll := r.randf()
	var p := k.c + Vector3(r.randf_range(-1.5, 1.5), 0, r.randf_range(-1.5, 1.5))
	if roll < 0.12 and _free(k, Rect2(p.x - k.o.x - 2.6, p.z - k.o.z - 2.6, 5.2, 5.2)):
		_wreck(k.d, p, r.randf() * TAU, r, true)
	elif roll < 0.3:
		_pallet_stack(k, p)
	elif roll < 0.45:
		for q in _cluster(r, p, r.randi_range(2, 4)):
			if _free(k, Rect2(q.x - k.o.x - 0.4, q.z - k.o.z - 0.4, 0.8, 0.8)):
				cb.kit(k.d, drum(r), q, r.randf() * TAU)
	elif roll < 0.55 and _free(k, Rect2(p.x - k.o.x - 1.2, p.z - k.o.z - 1.2, 2.4, 2.4)):
		cb.kit(k.d, "rubble", p, r.randf() * TAU)
	elif roll < 0.68 and cb.models.has("road_barrier") and _free(k, Rect2(p.x - k.o.x - 2.6, p.z - k.o.z - 1.0, 5.2, 2.0)):
		# A line of road barriers someone dragged across.
		var turn := (PI * 0.5) * r.randi_range(0, 1)
		var along := Basis(UP, turn) * Vector3(1, 0, 0)
		for i in r.randi_range(2, 3):
			cb.kit(k.d, "road_barrier", p + along * ((i - 1) * 1.6), turn + r.randf_range(-0.12, 0.12))


## Ground between the buildings, seen through windows and over yard walls:
## weeds, rubble, puddles, junk, the odd wreck, a fence round the site. Pure
## scenery: nothing out here collides.
func outside(d: ChunkBuilder.ChunkData, x: int, z: int, o: Vector3) -> void:
	if not d.geo.visuals:
		return
	var r := cb.rng(x, z, 0, 100)
	var g := d.geo
	var lo := 1.2
	var hi := C - 1.2
	for i in r.randi_range(4, 12):
		var p := o + Vector3(r.randf_range(lo, hi), 0, r.randf_range(lo, hi))
		for j in 3:
			var tip := p + Vector3(r.randf_range(-0.3, 0.3), r.randf_range(0.2, 0.8), r.randf_range(-0.3, 0.3))
			g.frustum(p, tip, 0.03, 0.0, &"moss", 4)
	for i in r.randi_range(0, 6):
		var p := o + Vector3(r.randf_range(lo, hi), 0, r.randf_range(lo, hi))
		var size := Vector3(r.randf_range(0.15, 0.6), r.randf_range(0.08, 0.3), r.randf_range(0.15, 0.5))
		g.box(p + UP * size.y * 0.3, size, &"concrete_dark", &"", false, Basis.from_euler(Vector3(r.randf_range(-0.3, 0.3), r.randf() * TAU, 0)))
	if r.randf() < 0.35:
		d.decals.append(["puddle", Transform3D(Basis(UP, r.randf() * TAU), o + Vector3(r.randf_range(2, 6), 0.0, r.randf_range(2, 6))),
			Vector3(r.randf_range(2.0, 4.0), 0.5, r.randf_range(2.0, 3.5))])
	var bridge_above := L.is_enclosed(x, z, 1)
	var c := o + Vector3(C * 0.5 + r.randf_range(-1, 1), 0, C * 0.5 + r.randf_range(-1, 1))
	var roll := r.randf()
	if not bridge_above:
		if roll < 0.07:
			_wreck(d, c, r.randf() * TAU, r, false)
		elif roll < 0.15:
			for q in _cluster(r, c, r.randi_range(2, 5)):
				cb.kit(d, drum(r), q, r.randf() * TAU, {"collide": false})
		elif roll < 0.22:
			cb.kit(d, "pallet", c, r.randf() * TAU, {"collide": false})
			cb.kit(d, "crate_wood", c + Vector3(0, 0.15, 0), r.randf() * TAU, {"collide": false})
		elif roll < 0.28:
			cb.kit(d, "rubble", c, r.randf() * TAU, {"collide": false})
		elif roll < 0.31:
			cb.kit(d, "shipping_container", c, (PI * 0.5) * r.randi_range(0, 1) + r.randf_range(-0.1, 0.1), {"collide": false})
		elif roll < 0.37 and cb.models.has("road_barrier"):
			for i in r.randi_range(1, 3):
				cb.kit(d, "road_barrier", c + Vector3(i * 1.6, 0, r.randf_range(-0.2, 0.2)), r.randf_range(-0.2, 0.2), {"collide": false})
		elif roll < 0.42 and cb.models.has("tyre"):
			for i in r.randi_range(1, 3):
				cb.kit(d, "tyre", c + Vector3(r.randf_range(-1, 1), 0.08, r.randf_range(-1, 1)), r.randf() * TAU, {"collide": false},
					Basis(Vector3.RIGHT, PI * 0.5))
	# Chain-link fence and poles round the edge of the site.
	for dir in 4:
		var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
		if n.x >= 0 and n.y >= 0 and n.x < L.size.x and n.y < L.size.y:
			continue
		var sp := cb.edge_span(o, dir)
		var inset := -1.5  # a little way out from the cell edge
		for i in 4:
			var a := C * i / 4.0
			cb.sbox(g, sp, a - 0.04, a + 0.04, 0.0, 2.6, 0.08, inset, &"gun_metal")
		cb.sbox(g, sp, 0.0, C, 0.1, 2.5, 0.015, inset, &"steel_grate")
		if (x * 7 + z * 3 + dir) % 4 == 0:
			var p := sp.origin + sp.u * (C * 0.5) - sp.m * 3.0
			g.cylinder(p, p + UP * 9.0, 0.14, &"wood_planks", 8)
			g.box(p + UP * 8.4, Vector3(1.8, 0.12, 0.12) if absf(sp.u.x) > 0.5 else Vector3(0.12, 0.12, 1.8), &"wood_planks")


## A drum of any kind, generated or scanned.
func drum(r: RandomNumberGenerator) -> String:
	const IDS := ["barrel_rust", "barrel_blue", "barrel_orange", "barrel_red", "barrel_plastic", "barrel_steel"]
	var id: String = IDS[r.randi_range(0, IDS.size() - 1)]
	return id if not ModelProps.MODELS.has(id) or cb.models.has(id) else "barrel_rust"


## Up to n spots round p on a 0.7 m grid (barrels side by side, never inside
## each other).
static func _cluster(r: RandomNumberGenerator, p: Vector3, n: int) -> Array[Vector3]:
	var spots: Array = []
	for i in range(-1, 2):
		for j in range(-1, 2):
			spots.append(Vector3(i * 0.7, 0, j * 0.7))
	var out: Array[Vector3] = []
	for i in mini(n, spots.size()):
		var q: Vector3 = spots.pop_at(r.randi_range(0, spots.size() - 1))
		out.append(p + q + Vector3(r.randf_range(-0.04, 0.04), 0, r.randf_range(-0.04, 0.04)))
	return out


## A burnt-out car on its rims.
func _wreck(d: ChunkBuilder.ChunkData, p: Vector3, yaw: float, r: RandomNumberGenerator, collide: bool) -> void:
	var b := Basis(UP, yaw) * Basis(Vector3.FORWARD, r.randf_range(-0.05, 0.05))
	var mat: StringName = [&"prop_rust", &"rusted_metal", &"prop_steel_blue"][r.randi_range(0, 2)]
	d.geo.box(p + b * Vector3(0, 0.62, 0), Vector3(4.2, 0.62, 1.75), mat, &"", false, b)
	d.geo.box(p + b * Vector3(-0.3, 1.18, 0), Vector3(2.1, 0.5, 1.6), mat, &"", false, b)
	d.geo.box(p + b * Vector3(-0.3, 1.18, 0), Vector3(1.9, 0.42, 1.64), &"soot", &"", false, b)  # empty window frames
	for e: float in [-1.0, 1.0]:
		for f: float in [-1.0, 1.0]:
			var w := p + b * Vector3(e * 1.35, 0.3, f * 0.8)
			d.geo.cylinder(w - b * Vector3(0, 0, 0.1), w + b * Vector3(0, 0, 0.1), 0.3, &"gun_metal", 10, true)
	if collide:
		d.geo.box(p + b * Vector3(0, 0.7, 0), Vector3(4.2, 1.4, 1.75), &"", &"metal", false, b)


# --- Corridors -----------------------------------------------------------------------------

func _corridor(k: Cell) -> void:
	var r := k.r
	_wall_props(k, k.st.prop_density)
	var roll := r.randf()
	if roll < 0.04:
		# Someone held out here once.
		var p := k.c + Vector3(r.randf_range(-1.5, 1.5), 0, r.randf_range(-1.5, 1.5))
		if _free(k, Rect2(p.x - k.o.x - 1.5, p.z - k.o.z - 1.5, 3, 3)):
			cb.kit(k.d, "sandbags", p + Vector3(0, 0, -1.2), 0.0)
			cb.kit(k.d, "bedroll", p + Vector3(0.8, 0, 0.4), r.randf() * TAU)
			box(k, p + Vector3(-0.7, 0.05, 0.3), Vector3(0.6, 0.1, 0.6), &"soot")
	elif roll < 0.1:
		_trolley(k, k.c + Vector3(r.randf_range(-2, 2), 0, r.randf_range(-2, 2)))


func _trolley(k: Cell, p: Vector3) -> void:
	if not _free(k, Rect2(p.x - k.o.x - 0.8, p.z - k.o.z - 0.6, 1.6, 1.2)):
		return
	var r := cb.rng(k.x, k.z, k.s, 70)
	var yaw := r.randf() * TAU
	var b := Basis(Vector3.UP, yaw)
	box(k, p + UP * 0.35, Vector3(1.2, 0.04, 0.7), &"painted_steel", false, b)
	box(k, p + UP * 0.8, Vector3(1.2, 0.04, 0.7), &"painted_steel", false, b)
	for e: float in [-1.0, 1.0]:
		for f: float in [-1.0, 1.0]:
			box(k, p + b * Vector3(e * 0.56, 0.45, f * 0.32), Vector3(0.04, 0.8, 0.04), &"painted_steel")
	solid(k, p + UP * 0.45, Vector3(1.2, 0.9, 0.7), &"metal", b)


# --- Rooms ---------------------------------------------------------------------------------

func _room(k: Cell) -> void:
	match k.room.use:
		&"cubicles":
			_cubicles(k)
		&"offices":
			_private_office(k)
		&"meeting":
			_meeting(k)
		&"archive":
			_archive(k)
		&"boiler":
			_boiler(k)
		&"electrical":
			_electrical(k)
		&"lockers":
			_lockers(k)
		&"washroom":
			_washroom(k)
		&"workshop":
			_workshop(k)
		&"parts":
			_parts(k)
		&"cages":
			_cages(k)
		&"vats":
			if _free(k, Rect2(C * 0.5 - 1.4, C * 0.5 - 1.4, 2.8, 2.8)):
				cb.kit(k.d, "vat", k.c, k.r.randf() * TAU)
			_wall_props(k, 0.4, ["barrel_blue", "barrel_orange", "electrical_cabinet"])
		&"pumps":
			_pumps(k)
		&"lab":
			_lab(k)
		&"stash":
			_stash(k)
		_:
			_wall_props(k, 0.5)


## Generic wall-side props from the style (or the given ids) in the corners of the cell.
## Now and then a hole or vent was half hidden: a locker or shelf dragged
## across the end of it, enough to squeeze past.
func _gap_cover(k: Cell) -> void:
	for dir in 4:
		if not L.has_gap(k.x, k.z, k.s, dir) or L.has_flag(k.x, k.z, k.s, LevelLayout.NARROW):
			continue
		var r := cb.rng(k.x, k.z, k.s, 120 + dir)
		if r.randf() > 0.35:
			continue
		var g := cb.gap_span(k.x, k.z, k.s, dir)
		var sp := cb.edge_span(k.o, dir)
		var vent := L.has_vent(k.x, k.z, k.s, dir)
		var id := "locker" if vent or r.randf() < 0.5 else "shelf"
		var half := 0.25 if id == "locker" else 1.05
		var side := 1.0 if r.randf() < 0.5 else -1.0
		var a := (g.y + half - 0.35) if side > 0.0 else (g.x - half + 0.35)
		if a - half < 0.3 or a + half > C - 0.3:
			continue
		var out := 0.15 + (0.95 if vent else 0.45)
		var p := sp.origin + sp.u * a + sp.m * out
		cb.kit(k.d, id, p, _face_from_wall(dir) + side * r.randf_range(0.25, 0.45))


## Someone holed up here, getting in through the vent: a bedroll, a low wall
## of sandbags facing the way in, tins, candle stubs, scrawled notes.
func _stash(k: Cell) -> void:
	var r := k.r
	var p := k.c + Vector3(r.randf_range(-1.0, 1.0), 0, r.randf_range(-1.0, 1.0))
	if _free(k, Rect2(p.x - k.o.x - 1.2, p.z - k.o.z - 1.2, 2.4, 2.4)):
		var yaw := r.randf() * TAU
		var b := Basis(UP, yaw)
		box(k, p + b * Vector3(0, 0.08, 0), Vector3(0.95, 0.16, 1.95), &"fabric_dark", false, b)  # mattress
		cb.kit(k.d, "bedroll", p + b * Vector3(0, 0.16, 0.1), yaw + r.randf_range(-0.2, 0.2), {"collide": false})
		# A table of crates, a lamp and a tin on it.
		var t := p + b * Vector3(1.2, 0, -0.4)
		cb.kit(k.d, "crate_wood", t, yaw)
		k.d.geo.frustum(t + UP * 0.8, t + UP * 1.05, 0.08, 0.06, &"glass_dirty", 8, true)
		k.d.geo.cylinder(t + UP * 1.05, t + UP * 1.12, 0.05, &"gun_metal", 8, true)
		cb.kit(k.d, "crate_small", t + b * Vector3(0.1, 0, 0.9), r.randf() * TAU)
		for i in r.randi_range(3, 7):
			var q := p + Vector3(r.randf_range(-1.4, 1.4), 0, r.randf_range(-1.4, 1.4))
			cyl(k, q, q + UP * r.randf_range(0.08, 0.12), 0.035, &"prop_rust", 8)  # tins
		for i in r.randi_range(2, 4):
			var q := p + Vector3(r.randf_range(-0.8, 0.8), 0, r.randf_range(-0.8, 0.8))
			cyl(k, q, q + UP * r.randf_range(0.03, 0.09), 0.018, &"paper", 6)  # candle stubs
		box(k, p + Vector3(-0.6, 0.004, 0.5), Vector3(0.7, 0.008, 0.7), &"soot", false, Basis(UP, r.randf() * TAU))
	for dir in 4:
		if L.has_vent(k.x, k.z, k.s, dir):
			var q := _wall_at(k, dir, 0.0, 2.6)
			if _free(k, _rect(k, q, LevelLayout.dir_vector((dir + 1) % 4), 1.6, 0.4)):
				cb.kit(k.d, "sandbags", q, _face_from_wall(dir))
	for i in 3:
		decal(k, "papers", k.o + Vector3(r.randf_range(1, C - 1), 0, r.randf_range(1, C - 1)), Vector3(1.2, 0.4, 1.2), r.randf() * TAU)
	_wall_props(k, 0.4, ["crate_wood", "barrel_rust", "filing_cabinet"])


func _wall_props(k: Cell, density: float, ids: Array = []) -> void:
	var r := cb.rng(k.x, k.z, k.s, 9)
	var table: Dictionary = k.st.props
	if not ids.is_empty():
		table = {}
		for id in ids:
			table[id] = 1.0
	if table.is_empty():
		return
	for q in 4:
		if r.randf() > density:
			continue
		var qx := q % 2
		var qz := q / 2
		var wall_z := 0 if qz == 0 else 2
		var wall_x := 3 if qx == 0 else 1
		var against := -1
		if _wall_free(k, wall_z):
			against = wall_z
		elif _wall_free(k, wall_x):
			against = wall_x
		if against < 0:
			continue
		var id := _weighted(r, table)
		var fp: Array = ChunkBuilder.FOOTPRINTS.get(id, [Vector3.ONE, 0.5])
		var size: Vector3 = fp[0]
		var local := Vector3(2.0 if qx == 0 else C - 2.0, 0, 2.0 if qz == 0 else C - 2.0)
		var depth := size.z * 0.5 + 0.2
		var yaw := 0.0
		match against:
			0:
				local.z = depth
				yaw = PI
			2:
				local.z = C - depth
				yaw = 0.0
			3:
				local.x = depth
				yaw = -PI * 0.5
			1:
				local.x = C - depth
				yaw = PI * 0.5
		yaw += r.randf_range(-0.08, 0.08)
		var foot := Rect2(local.x - maxf(size.x, size.z) * 0.5, local.z - maxf(size.x, size.z) * 0.5, maxf(size.x, size.z), maxf(size.x, size.z))
		if not _free(k, foot):
			continue
		# Now and then it has fallen over.
		var fallen_at := k.o + local + (k.c - (k.o + local)).normalized() * 0.9
		if id in ["locker", "filing_cabinet", "electrical_cabinet"] and r.randf() < 0.15 \
				and _free(k, Rect2(fallen_at.x - k.o.x - 1.1, fallen_at.z - k.o.z - 1.1, 2.2, 2.2)):
			# (a hair above the floor: parts of its face sit proud of the footprint)
			cb.kit(k.d, id, k.o + local + (k.c - (k.o + local)).normalized() * 0.6 + UP * (size.z * 0.5 + 0.012), yaw, {}, Basis(Vector3.RIGHT, -PI * 0.5))
			continue
		cb.kit(k.d, id, k.o + local, yaw)
		if id.begins_with("crate") and r.randf() < 0.3:
			cb.kit(k.d, "crate_small", k.o + local + UP * size.y, r.randf() * TAU)


## Up to n positions in -half..half for things `width` wide that don't
## overlap (two overlapping boxes flicker where their faces meet).
static func _slots(r: RandomNumberGenerator, n: int, half: float, width: float) -> Array[float]:
	var out: Array[float] = []
	var count := maxi(int(floor(half * 2.0 / (width + 0.02))), 1)
	var free: Array = range(count)
	for i in mini(n, count):
		var pick: int = free.pop_at(r.randi_range(0, free.size() - 1))
		var step := half * 2.0 / count
		out.append(-half + step * (pick + 0.5) + r.randf_range(-1.0, 1.0) * maxf(step - width - 0.02, 0.0) * 0.5)
	return out


func _weighted(r: RandomNumberGenerator, table: Dictionary) -> String:
	var total := 0.0
	for key in table:
		total += float(table[key])
	var roll := r.randf() * total
	for key in table:
		roll -= float(table[key])
		if roll <= 0.0:
			return String(key)
	return String(table.keys().back())


func _chair(k: Cell, p: Vector3, yaw: float, r: RandomNumberGenerator) -> void:
	var b := Basis(Vector3.UP, yaw)
	var fallen := r.randf() < 0.25
	if not fallen and cb.models.has("school_chair") and r.randf() < 0.35:
		cb.kit(k.d, "school_chair", p, yaw + PI, {"collide": false})  # it faces +Z, this chair -Z
		return
	if fallen:
		b = b * Basis(Vector3.RIGHT, PI * 0.5)
		p += UP * 0.25
	var seat := p + b * Vector3(0, 0.48, 0)
	box(k, seat, Vector3(0.5, 0.08, 0.48), &"fabric_dark", false, b)
	box(k, p + b * Vector3(0, 0.82, 0.24), Vector3(0.46, 0.6, 0.06), &"fabric_dark", false, b)
	k.d.geo.cylinder(p + b * Vector3(0, 0.1, 0), seat, 0.025, &"gun_metal", 6)
	for i in 5:
		var a := TAU * i / 5.0
		box(k, p + b * (Vector3(cos(a), 0, sin(a)) * 0.15 + Vector3(0, 0.06, 0)), Vector3(0.3, 0.04, 0.05), &"gun_metal", false, b * Basis(Vector3.UP, -a))


func _cubicles(k: Cell) -> void:
	var r := k.r
	# A cluster of four desks around a cross of partitions, aisles at the cell edges.
	var c0 := Vector2(C * 0.5, C * 0.5)
	var size := 2.7
	var quads := [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]
	var h := 1.45
	var cross_ok := _free(k, Rect2(c0.x - size, c0.y - 0.1, size * 2, 0.2)) and _free(k, Rect2(c0.x - 0.1, c0.y - size, 0.2, size * 2))
	for q: Vector2 in quads:
		var qc := c0 + q * (size * 0.5)
		var rect := Rect2(qc.x - size * 0.5, qc.y - size * 0.5, size, size)
		if not _free(k, rect):
			continue
		var p := k.o + Vector3(qc.x, 0, qc.y)
		var toppled := r.randf() < 0.15
		# Outer partition along the x side, with the opening on the z side
		var outer := k.o + Vector3(qc.x, 0, qc.y + q.y * size * 0.5)
		if toppled:
			box(k, outer + UP * 0.05 - Vector3(0, 0, q.y * 0.7), Vector3(size, 0.06, h), &"fabric_dark", false, Basis.IDENTITY)
		else:
			box(k, outer + UP * (h * 0.5), Vector3(size, h, 0.06), &"fabric_dark", true)
		# Desk in the inner corner, L-shaped
		var dx := -q.x
		var dz := -q.y
		var desk_a := p + Vector3(dx * (size * 0.5 - 0.4), 0, 0)
		box(k, desk_a + UP * 0.74, Vector3(0.7, 0.04, size - 0.3), &"prop_wood", true)
		var desk_b := p + Vector3(0, 0, dz * (size * 0.5 - 0.4))
		box(k, desk_b + UP * 0.74, Vector3(size - 0.3, 0.04, 0.7), &"prop_wood", true)
		box(k, desk_a + UP * 0.37 + Vector3(0, 0, -dz * 0.6), Vector3(0.6, 0.66, 0.5), &"painted_steel")  # pedestal
		solid(k, desk_a + UP * 0.38, Vector3(0.7, 0.76, size - 0.3), &"wood")
		solid(k, desk_b + UP * 0.38, Vector3(size - 0.3, 0.76, 0.7), &"wood")
		# Monitor, keyboard, papers
		var corner := p + Vector3(dx * (size * 0.5 - 0.45), 0.76, dz * (size * 0.5 - 0.45))
		if r.randf() < 0.75:
			var fell := r.randf() < 0.2
			var mon := corner + (Vector3(-dx * 0.6, -0.7, -dz * 0.4) if fell else Vector3.ZERO)
			var mb := Basis(Vector3.UP, atan2(dx, dz)) * (Basis(Vector3.RIGHT, -PI * 0.5) if fell else Basis.IDENTITY)
			box(k, mon + mb * Vector3(0, 0.22, 0), Vector3(0.42, 0.34, 0.38), &"prop_steel", false, mb)  # CRT
			box(k, mon + mb * Vector3(0, 0.03, 0), Vector3(0.24, 0.06, 0.22), &"prop_steel", false, mb)
		box(k, corner + Vector3(-dx * 0.35, 0.015, -dz * 0.35), Vector3(0.45, 0.03, 0.18), &"prop_steel", false, Basis(Vector3.UP, atan2(dx, dz)))
		if r.randf() < 0.6:
			box(k, desk_b + UP * 0.765 + Vector3(r.randf_range(-0.6, 0.6), 0, 0), Vector3(0.3, 0.01, 0.22), &"paper", false, Basis(Vector3.UP, r.randf()))
		if r.randf() < 0.8:
			_chair(k, p + Vector3(r.randf_range(-0.3, 0.3), 0, r.randf_range(-0.3, 0.3)), r.randf() * TAU, r)
	if cross_ok:
		var hc := 1.45
		box(k, k.o + Vector3(c0.x, hc * 0.5, c0.y), Vector3(size * 2, hc, 0.06), &"fabric_dark", true)
		box(k, k.o + Vector3(c0.x, hc * 0.5, c0.y), Vector3(0.06, hc, size * 2), &"fabric_dark", true)
		box(k, k.o + Vector3(c0.x, hc + 0.02, c0.y), Vector3(0.1, 0.04, 0.1), &"gun_metal")


func _private_office(k: Cell) -> void:
	var r := k.r
	var p := k.c + Vector3(r.randf_range(-0.8, 0.8), 0, r.randf_range(-0.8, 0.8))
	var yaw := (PI * 0.5) * r.randi_range(0, 3)
	if _free(k, Rect2(p.x - k.o.x - 1.0, p.z - k.o.z - 1.0, 2.0, 2.0)):
		var tilt := Basis.IDENTITY
		if r.randf() < 0.15:
			tilt = Basis(Vector3.FORWARD, 0.3)  # a leg gone
		cb.kit(k.d, "desk", p, yaw, {}, tilt)
		_chair(k, p + Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.8), yaw + PI + r.randf_range(-0.6, 0.6), r)
		box(k, p + UP * 0.78 + Basis(Vector3.UP, yaw) * Vector3(-0.3, 0, 0), Vector3(0.32, 0.04, 0.24), &"paper", false, Basis(Vector3.UP, r.randf()))
	# Bookcase and a dead plant
	for dir in 4:
		if _wall_free(k, dir) and r.randf() < 0.6:
			var q := _wall_at(k, dir, r.randf_range(-2.0, 2.0), 0.2)
			var A := LevelLayout.dir_vector((dir + 1) % 4)
			if _free(k, _rect(k, q, A, 1.0, 0.4)):
				_bookcase(k, q, A, r)
			break
	if r.randf() < 0.5:
		var q := k.o + Vector3(r.randf_range(0.8, 1.2) if r.randf() < 0.5 else C - 1.0, 0, r.randf_range(0.8, 1.2) if r.randf() < 0.5 else C - 1.0)
		if _free(k, Rect2(q.x - k.o.x - 0.3, q.z - k.o.z - 0.3, 0.6, 0.6)):
			k.d.geo.frustum(q, q + UP * 0.45, 0.16, 0.22, &"brick", 10, true)
			for i in 3:
				k.d.geo.cylinder(q + UP * 0.45, q + UP * 0.45 + Vector3(r.randf_range(-0.3, 0.3), r.randf_range(0.3, 0.8), r.randf_range(-0.3, 0.3)), 0.012, &"prop_wood", 4)
	_wall_props(k, 0.3, ["filing_cabinet"])


func _bookcase(k: Cell, p: Vector3, A: Vector3, r: RandomNumberGenerator) -> void:
	var B := _across(A)
	box(k, p + UP * 0.95, _sz(A, 0.9, 1.9, 0.35), &"prop_wood", true)
	for i in 4:
		var y := 0.25 + i * 0.45
		for j in r.randi_range(0, 6):
			var t := r.randf_range(-0.38, 0.38)
			var lean := r.randf_range(-0.3, 0.3) if r.randf() < 0.3 else 0.0
			box(k, p + A * t + UP * (y + 0.13) + B * 0.02, _sz(A, 0.05, 0.25, 0.22), &"fabric_canvas" if r.randf() < 0.5 else &"fabric_dark", false, Basis(B, lean))


func _meeting(k: Cell) -> void:
	var r := k.r
	var along_x := r.randf() < 0.5
	if k.room:
		along_x = k.room.rect.size.x >= k.room.rect.size.y
	var A := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var B := _across(A)
	if _free(k, _rect(k, k.c, A, 4.2, 2.6)):
		box(k, k.c + UP * 0.74, _sz(A, 3.6, 0.06, 1.2), &"prop_wood", true)
		for e: float in [-1.0, 1.0]:
			box(k, k.c + A * (e * 1.4) + UP * 0.36, _sz(A, 0.1, 0.72, 0.9), &"gun_metal")
		solid(k, k.c + UP * 0.38, _sz(A, 3.6, 0.76, 1.2), &"wood")
		for i in 3:
			for e: float in [-1.0, 1.0]:
				if r.randf() < 0.8:
					var q := k.c + A * (-1.2 + i * 1.2) + B * (e * (0.95 + r.randf_range(0.0, 0.4)))
					_chair(k, q, atan2(-B.x * e, -B.z * e) + PI + r.randf_range(-0.5, 0.5), r)
	for dir in 4:
		if _wall_free(k, dir):
			var q := _wall_at(k, dir, 0.0, 0.03, 1.6)
			var W := LevelLayout.dir_vector((dir + 1) % 4)
			box(k, q, _sz(W, 2.2, 1.1, 0.03), &"plaster")  # whiteboard, clear of the dado rail
			box(k, q + Vector3.DOWN * 0.6 - LevelLayout.dir_vector(dir) * 0.05, _sz(W, 2.0, 0.03, 0.08), &"gun_metal")
			break


func _archive(k: Cell) -> void:
	var r := k.r
	var along_x := (k.x + k.z) % 2 == 0
	var A := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var B := _across(A)
	for row: float in [-2.2, 0.0, 2.2]:
		for i in 2:
			var p := k.c + B * row + A * (-1.15 + i * 2.3)
			if not _free(k, _rect(k, p, A, 2.2, 0.7)):
				continue
			if r.randf() < 0.12 and _free(k, _rect(k, p + B * 1.3, A, 2.4, 2.8)):
				cb.kit(k.d, "shelf", p + B * 0.6 + UP * 0.3, atan2(B.x, B.z), {}, Basis(Vector3.RIGHT, -1.2))
				continue
			cb.kit(k.d, "shelf", p, atan2(B.x, B.z) if along_x else atan2(A.x, A.z) + PI * 0.5)
			for y: float in [0.25, 1.15, 2.05]:
				for t in _slots(r, r.randi_range(1, 4), 0.8, 0.4):
					box(k, p + A * t + UP * (y + 0.18), _sz(A, 0.4, 0.3, 0.33), &"fabric_canvas")
	for i in 3:
		decal(k, "papers", k.o + Vector3(r.randf_range(1, C - 1), 0, r.randf_range(1, C - 1)), Vector3(1.6, 0.4, 1.6), r.randf() * TAU)


func _boiler(k: Cell) -> void:
	var r := k.r
	var along_x := (k.room.rect.size.x >= k.room.rect.size.y) if k.room else true
	var A := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var B := _across(A)
	var p := k.c + B * r.randf_range(-0.6, 0.6)
	if _free(k, _rect(k, p, A, 5.4, 2.8)) and r.randf() < 0.8:
		var y := 1.35
		for e: float in [-1.0, 1.0]:
			box(k, p + A * (e * 1.6) + UP * 0.45, _sz(A, 0.4, 0.9, 1.8), &"concrete_dark")  # saddles
		cyl(k, p - A * 2.3 + UP * y, p + A * 2.3 + UP * y, 1.1, &"painted_steel", 22)
		cyl(k, p - A * 2.35 + UP * y, p - A * 2.25 + UP * y, 1.16, &"rusted_metal", 22)
		cyl(k, p + A * 2.25 + UP * y, p + A * 2.35 + UP * y, 1.16, &"rusted_metal", 22)
		box(k, p - A * 2.4 + UP * y, _sz(A, 0.08, 0.7, 0.6), &"gun_metal")  # firebox door
		var flue := p + A * 1.6 + UP * (y + 1.0)
		var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
		cyl(k, flue, flue + UP * (hc - y - 1.0), 0.3, &"rusted_metal", 12, false)
		for i in 3:
			var g := p + A * (-1.0 + i * 0.8) + B * 1.15 + UP * (y + 0.4)
			cyl(k, g, g + B * 0.08, 0.08, &"gun_metal", 10)  # gauges
		cyl(k, p + A * 0.5 + UP * (y + 1.05), p + A * 0.5 + B * 2.5 + UP * (y + 1.05), 0.12, &"rusted_metal", 10, false)
		_valve(k, p + A * 0.5 + B * 1.6 + UP * (y + 1.05), B)
		solid(k, p + UP * (y * 0.5 + 0.5), _sz(A, 4.8, 2.6, 2.3))
		decal(k, "puddle", p + B * 1.6, Vector3(2.0, 0.4, 1.6), r.randf() * TAU)
	else:
		_wall_props(k, 0.6, ["barrel_rust", "electrical_cabinet"])


func _electrical(k: Cell) -> void:
	var r := k.r
	for dir in 4:
		if not _wall_free(k, dir):
			continue
		for i in 5:
			var t := -2.4 + i * 1.2
			var p := _wall_at(k, dir, t, 0.25)
			var A := LevelLayout.dir_vector((dir + 1) % 4)
			if not _free(k, _rect(k, p, A, 1.0, 0.5)):
				continue
			if r.randf() < 0.75:
				cb.kit(k.d, "electrical_cabinet", p, _face_from_wall(dir))
		# Cable tray along the wall, cables spilling out
		var hc := cb.ceiling_height(k.st, k.zn, k.room, k.x, k.z, k.s)
		var q := _wall_at(k, dir, 0.0, 0.45, hc - 0.4)
		var A2 := LevelLayout.dir_vector((dir + 1) % 4)
		box(k, q, _sz(A2, C - 0.4, 0.08, 0.4), &"steel_grate")
		for j in 2:
			var a := q + A2 * r.randf_range(-3, 3)
			k.d.geo.cylinder(a, a + Vector3(r.randf_range(-0.5, 0.5), -r.randf_range(0.8, 1.6), r.randf_range(-0.5, 0.5)), 0.025, &"cable", 4)
	# Transformer in the middle
	if _free(k, Rect2(C * 0.5 - 1.0, C * 0.5 - 0.8, 2.0, 1.6)) and r.randf() < 0.6:
		box(k, k.c + UP * 0.9, Vector3(1.4, 1.8, 1.0), &"painted_steel_green", true)
		for i in 5:
			box(k, k.c + Vector3(-0.6 + i * 0.3, 0.8, 0.55), Vector3(0.03, 1.2, 0.12), &"painted_steel_green")
			box(k, k.c + Vector3(-0.6 + i * 0.3, 0.8, -0.55), Vector3(0.03, 1.2, 0.12), &"painted_steel_green")
		for i in 3:
			cyl(k, k.c + Vector3(-0.4 + i * 0.4, 1.8, 0), k.c + Vector3(-0.4 + i * 0.4, 2.2, 0), 0.07, &"plaster", 8)


func _lockers(k: Cell) -> void:
	var r := k.r
	var along_x := (k.x + k.z) % 2 == 0
	if k.room:
		along_x = k.room.rect.size.x >= k.room.rect.size.y
	var A := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var B := _across(A)
	for e: float in [-1.0, 1.0]:
		for i in 9:
			var p := k.c + A * (-2.0 + i * 0.5) + B * (e * 0.26)
			if not _free(k, _rect(k, p, A, 0.5, 0.5)):
				continue
			var yaw := atan2(B.x * e, B.z * e)
			if r.randf() < 0.08 and _free(k, _rect(k, p + B * (e * 1.2), A, 0.6, 2.0)):
				cb.kit(k.d, "locker", p + B * (e * 0.9) + UP * 0.282, yaw, {}, Basis(Vector3.RIGHT, -PI * 0.5))  # face down, on its handle
			elif r.randf() < 0.9:
				cb.kit(k.d, "locker", p, yaw)
	# Benches either side
	for e: float in [-1.0, 1.0]:
		var p := k.c + B * (e * 1.4)
		if _free(k, _rect(k, p, A, 3.0, 0.4)):
			box(k, p + UP * 0.45, _sz(A, 3.0, 0.05, 0.35), &"prop_wood", true)
			for f: float in [-1.2, 1.2]:
				box(k, p + A * f + UP * 0.22, Vector3(0.05, 0.44, 0.05), &"gun_metal")


func _washroom(k: Cell) -> void:
	var r := k.r
	var wall := -1
	for dir in 4:
		if _wall_free(k, dir):
			wall = dir
			break
	if wall < 0:
		return
	var A := LevelLayout.dir_vector((wall + 1) % 4)
	var inward := -LevelLayout.dir_vector(wall)
	# Stalls along one wall
	for i in 3:
		var t := -1.8 + i * 1.2
		var p := _wall_at(k, wall, t, 0.75)
		if not _free(k, _rect(k, p, A, 1.2, 1.5)):
			continue
		if r.randf() < 0.85:
			box(k, p + A * 0.6 + UP * 1.0, _sz(A, 0.04, 1.8, 1.5), &"painted_steel_blue", true)
		# Toilet
		var tp := _wall_at(k, wall, t, 0.35)
		if r.randf() < 0.8:
			k.d.geo.frustum(tp + UP * 0.05, tp + UP * 0.4, 0.15, 0.22, &"plaster", 12, true)
			box(k, tp - inward * 0.12 + UP * 0.6, _sz(A, 0.45, 0.4, 0.18), &"plaster")
		else:
			_debris(k, 4, 0.2)  # smashed
		if r.randf() < 0.7:
			# Stall door, hanging or on the floor
			var dp := p + inward * 0.75 + UP * 1.0
			if r.randf() < 0.6:
				box(k, dp, _sz(A, 0.9, 1.6, 0.04), &"painted_steel_blue", false, Basis(Vector3.UP, r.randf_range(-0.9, 0.9)))
			else:
				box(k, dp + inward * 0.5 + Vector3.DOWN * 0.95, _sz(A, 0.9, 0.04, 1.6), &"painted_steel_blue")
	# Sinks and a mirror on the opposite wall
	var opp := (wall + 2) % 4
	if _wall_free(k, opp):
		for i in 3:
			var t := -1.2 + i * 1.2
			var p := _wall_at(k, opp, t, 0.3, 0.85)
			if _free(k, Rect2(p.x - k.o.x - 0.35, p.z - k.o.z - 0.35, 0.7, 0.7)):
				box(k, p, Vector3(0.5, 0.18, 0.5) if absf(A.x) < 0.5 else Vector3(0.5, 0.18, 0.5), &"plaster")
				k.d.geo.cylinder(p + UP * 0.1, p + UP * 0.3 + LevelLayout.dir_vector(opp) * 0.15, 0.015, &"gun_metal", 4)
		var m := _wall_at(k, opp, 0.0, 0.02, 1.6)
		if r.randf() < 0.6:
			box(k, m, _sz(A, 3.0, 0.8, 0.02), &"glass_dirty")


func _workshop(k: Cell) -> void:
	var r := k.r
	var placed := 0
	for dir in 4:
		if not _wall_free(k, dir) or placed >= 2:
			continue
		var p := _wall_at(k, dir, r.randf_range(-1.5, 1.5), 0.4)
		var A := LevelLayout.dir_vector((dir + 1) % 4)
		if _free(k, _rect(k, p, A, 2.2, 0.9)):
			_workbench(k, p, A, -LevelLayout.dir_vector(dir))
			placed += 1
	# Drill press
	var q := k.c + Vector3(r.randf_range(-1.2, 1.2), 0, r.randf_range(-1.2, 1.2))
	if _free(k, Rect2(q.x - k.o.x - 0.5, q.z - k.o.z - 0.5, 1.0, 1.0)) and r.randf() < 0.6:
		box(k, q + UP * 0.05, Vector3(0.6, 0.1, 0.45), &"painted_steel_green")
		cyl(k, q + UP * 0.1 - Vector3(0, 0, 0.12), q + UP * 1.7 - Vector3(0, 0, 0.12), 0.05, &"gun_metal", 8)
		box(k, q + UP * 0.8, Vector3(0.35, 0.04, 0.35), &"painted_steel_green")
		box(k, q + UP * 1.55, Vector3(0.3, 0.35, 0.55), &"painted_steel_green")
		solid(k, q + UP * 0.85, Vector3(0.6, 1.7, 0.6))
	_wall_props(k, 0.4, ["electrical_cabinet", "barrel_rust", "crate_small"])


func _parts(k: Cell) -> void:
	var r := k.r
	var along_x := (k.x + k.z) % 2 == 0
	if k.room:
		along_x = k.room.rect.size.x >= k.room.rect.size.y
	var A := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var B := _across(A)
	for row: float in [-2.0, 2.0]:
		for i in 2:  # two per row: an aisle down the middle crosses the rows
			var p := k.c + B * row + A * (-2.3 + i * 4.6)
			if not _free(k, _rect(k, p, A, 2.2, 0.7)):
				continue
			cb.kit(k.d, "shelf", p, atan2(B.x, B.z) if along_x else atan2(A.x, A.z) + PI * 0.5)
			for y: float in [0.25, 1.15, 2.05]:
				for t in _slots(r, r.randi_range(2, 5), 0.8, 0.3):
					var mat: StringName = [&"painted_steel_blue", &"painted_steel_red", &"painted_steel", &"painted_steel_yellow"][r.randi_range(0, 3)]
					box(k, p + A * t + UP * (y + 0.12), _sz(A, 0.3, 0.2, 0.45), mat)  # bins
	if r.randf() < 0.4:
		_trolley(k, k.c + A * r.randf_range(-2, 2))


func _cages(k: Cell) -> void:
	var r := k.r
	# Two wire lockups against opposite walls of the cell.
	for dir in [0, 2] if (k.x + k.z) % 2 == 0 else [1, 3]:
		if not _wall_free(k, dir):
			continue
		var A := LevelLayout.dir_vector((dir + 1) % 4)
		var inward := -LevelLayout.dir_vector(dir)
		var depth := 2.6
		var front := _wall_at(k, dir, 0.0, depth)
		if not _free(k, _rect(k, _wall_at(k, dir, 0.0, depth * 0.5), A, 6.0, depth)):
			continue
		var h := 2.4
		# Front mesh with a gate gap, side meshes
		for seg in [[-3.0, -0.6], [0.6, 3.0]]:
			var a: float = seg[0]
			var b: float = seg[1]
			var mid := front + A * ((a + b) * 0.5)
			box(k, mid + UP * (h * 0.5), _sz(A, b - a, h, 0.03), &"steel_grate")
			k.d.geo.box(mid + UP * (h * 0.5), _sz(A, b - a, h, 0.1), &"", &"metal", false, Basis.IDENTITY, Layers.CLIP)
		for e: float in [-3.0, 3.0]:
			var mid := _wall_at(k, dir, e, depth * 0.5)
			box(k, mid + UP * (h * 0.5), _sz(inward, depth, h, 0.03), &"steel_grate")
			k.d.geo.box(mid + UP * (h * 0.5), _sz(inward, depth, h, 0.1), &"", &"metal", false, Basis.IDENTITY, Layers.CLIP)
		for e: float in [-3.0, -0.6, 0.6, 3.0]:
			box(k, front + A * e + UP * (h * 0.5), Vector3(0.06, h, 0.06), &"painted_steel")
		box(k, front + UP * h, _sz(A, 6.0, 0.06, 0.06), &"painted_steel")
		# Gate swung open
		var gate_hinge := front + A * 0.6
		var ang := r.randf_range(0.6, 1.6)
		var gdir := (-A * cos(ang) - inward * sin(ang)).normalized()
		box(k, gate_hinge + gdir * 0.6 + UP * (h * 0.5 - 0.05), Vector3(0.03, h - 0.1, 1.2), &"steel_grate", false,
			Basis.looking_at(gdir, Vector3.UP))
		# Contents
		for i in r.randi_range(1, 4):
			var q := _wall_at(k, dir, r.randf_range(-2.4, 2.4), r.randf_range(0.6, 1.8))
			cb.kit(k.d, ["crate_wood", "crate_small", "barrel_blue"][r.randi_range(0, 2)], q, r.randf() * TAU)


func _pumps(k: Cell) -> void:
	var r := k.r
	var A := Vector3(1, 0, 0) if r.randf() < 0.5 else Vector3(0, 0, 1)
	var B := _across(A)
	for e: float in [-1.5, 1.5]:
		var p := k.c + B * e
		if not _free(k, _rect(k, p, A, 2.6, 1.0)):
			continue
		box(k, p + UP * 0.1, _sz(A, 2.4, 0.2, 0.9), &"painted_steel")  # skid
		cyl(k, p - A * 0.9 + UP * 0.55, p + A * 0.1 + UP * 0.55, 0.32, &"painted_steel_blue", 14)  # motor
		k.d.geo.frustum(p + A * 0.3 + UP * 0.55, p + A * 0.9 + UP * 0.55, 0.4, 0.3, &"painted_steel_blue", 14, true)  # volute
		cyl(k, p + A * 0.6 + UP * 0.9, p + A * 0.6 + UP * 2.6, 0.12, &"rusted_metal", 10, false)
		cyl(k, p + A * 0.95 + UP * 0.55, p + A * 0.95 + UP * 0.05, 0.12, &"rusted_metal", 10, false)
		_valve(k, p + A * 0.6 + UP * 1.6, A)
		solid(k, p + UP * 0.5, _sz(A, 2.4, 1.0, 0.9))
	_wall_props(k, 0.4, ["electrical_cabinet", "barrel_blue"])


func _lab(k: Cell) -> void:
	var r := k.r
	for dir in 4:
		if not _wall_free(k, dir):
			continue
		var A := LevelLayout.dir_vector((dir + 1) % 4)
		var p := _wall_at(k, dir, 0.0, 0.4)
		if not _free(k, _rect(k, p, A, 5.0, 0.9)):
			continue
		box(k, p + UP * 0.9, _sz(A, 5.0, 0.05, 0.8), &"tiles_dirty", true)
		box(k, p + UP * 0.44, _sz(A, 5.0, 0.86, 0.7), &"painted_steel")
		solid(k, p + UP * 0.47, _sz(A, 5.0, 0.94, 0.8))
		for i in r.randi_range(3, 8):
			var q := p + A * r.randf_range(-2.3, 2.3) + LevelLayout.dir_vector(dir) * r.randf_range(-0.2, 0.2) + UP * 0.93
			if r.randf() < 0.25:
				box(k, q + UP * 0.02, Vector3(0.1, 0.04, 0.2), &"glass_dirty", false, Basis(Vector3.UP, r.randf()))  # broken
			else:
				k.d.geo.frustum(q, q + UP * r.randf_range(0.12, 0.3), r.randf_range(0.04, 0.08), 0.03, &"glass_dirty", 8, true)
		# Fume hood
		var hood := p + A * 1.8 + UP * 1.6
		box(k, hood, _sz(A, 1.2, 1.3, 0.8), &"painted_steel")
		cyl(k, hood + UP * 0.65, hood + UP * 2.0, 0.15, &"corrugated_metal", 10, false)
		break
	if _free(k, Rect2(C * 0.5 - 1.5, C * 0.5 - 0.6, 3.0, 1.2)):
		box(k, k.c + UP * 0.9, Vector3(2.8, 0.05, 1.0), &"tiles_dirty", true)
		box(k, k.c + UP * 0.44, Vector3(2.7, 0.86, 0.9), &"painted_steel")
		solid(k, k.c + UP * 0.47, Vector3(2.8, 0.94, 1.0))
