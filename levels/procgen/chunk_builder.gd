class_name ChunkBuilder
extends RefCounted
## Turns the cells of one chunk of a LevelLayout into geometry and placements.
## Reads the layout only, keeps no mutable state between calls, and creates no
## nodes, so build() can run on worker threads.
##
## Architecture (floors, walls, stairs, catwalks, ceilings) lives here; what
## fills the rooms comes from SetPieces.
##
## Every random choice comes from a per-cell RNG seeded from (level seed,
## cell, purpose), so a chunk always rebuilds identically.

const T := 0.3  # wall thickness
const STRIP := LevelLayout.STRIP  # width of a stair or catwalk strip
const RUN := LevelLayout.RUN  # horizontal length of a flight
const BRIDGE := 2.2  # width of a catwalk bridge
const TALL: Array[StringName] = [&"hall", &"foundry", &"warehouse", &"loading_dock"]
const SUN_DIR := Vector3(0.38, -1.0, 0.22)
## Kit props that stay separate nodes (lamps swap their emissive material).
const NODE_PROPS := ["cage_lamp", "fluorescent", "lamp_hanging", "fire_pit"]

## Kit prop footprints for collision and navigation: id -> [size, center height].
const FOOTPRINTS := {
	"crate_wood": [Vector3(1.0, 0.8, 1.0), 0.4], "crate_small": [Vector3(0.6, 0.5, 0.6), 0.25],
	"barrel_blue": [Vector3(0.6, 0.9, 0.6), 0.45], "barrel_rust": [Vector3(0.6, 0.9, 0.6), 0.45],
	"barrel_orange": [Vector3(0.6, 0.9, 0.6), 0.45], "pallet": [Vector3(1.2, 0.15, 1.0), 0.07],
	"shelf": [Vector3(2.1, 2.6, 0.65), 1.3], "machine_press": [Vector3(2.8, 4.0, 1.7), 2.0],
	"tank": [Vector3(5.4, 2.7, 2.2), 1.35], "conveyor": [Vector3(4.0, 0.95, 0.9), 0.48],
	"locker": [Vector3(0.5, 1.9, 0.5), 0.95], "desk": [Vector3(1.4, 0.76, 0.7), 0.38],
	"filing_cabinet": [Vector3(0.5, 1.32, 0.65), 0.66], "electrical_cabinet": [Vector3(0.9, 1.8, 0.4), 0.9],
	"rubble": [Vector3(2.0, 0.45, 2.0), 0.22], "sandbags": [Vector3(1.6, 0.66, 0.36), 0.33],
	"shipping_container": [Vector3(6.1, 2.6, 2.45), 1.3], "vat": [Vector3(2.6, 2.3, 2.6), 1.15],
	"bedroll": [Vector3(0.8, 0.15, 2.0), 0.07],
}

const SURFACES := {
	&"wood_planks": &"wood", &"corrugated_metal": &"metal", &"painted_steel": &"metal",
	&"painted_steel_yellow": &"metal", &"painted_steel_red": &"metal", &"painted_steel_blue": &"metal",
	&"painted_steel_green": &"metal", &"rusted_metal": &"metal", &"steel_grate": &"metal",
	&"prop_wood": &"wood", &"prop_steel": &"metal", &"prop_rust": &"metal", &"prop_steel_blue": &"metal",
	&"prop_steel_orange": &"metal", &"gun_metal": &"metal",
}


class ChunkData:
	var coord: Vector2i
	var bounds: AABB
	var geo: GeoBuilder
	## [kit id, Transform3D, options Dictionary] for props that stay nodes
	var props: Array = []
	## Dictionaries: type, position, rotation, color, energy, range, angle, shadow, flicker, pulse, buzz, prop
	var lights: Array = []
	## [texture name, Transform3D, size Vector3]
	var decals: Array = []
	## Dictionaries: position (drip origin), floor (y)
	var leaks: Array = []
	var nav_faces := PackedVector3Array()
	var obstructions: Array = []


var L: LevelLayout
var C: float
var H: float
var N: int
var pieces: SetPieces
var _ibeam: Dictionary  # material -> [verts, normals], unit height
## Kit prop id -> {"arrays": material -> [verts, normals], "surface": StringName}
var _kit: Dictionary = {}


## Must be created on the main thread (reads kit scenes, builds shared meshes).
func _init(layout: LevelLayout) -> void:
	L = layout
	C = layout.cell
	H = layout.storey_height
	N = layout.profile.chunk_cells
	_ibeam = _make_ibeam()
	_load_kit()
	pieces = SetPieces.new(self)


func chunk_count() -> Vector2i:
	return Vector2i(ceili(float(L.size.x) / N), ceili(float(L.size.y) / N))


func chunk_bounds(coord: Vector2i) -> AABB:
	return AABB(Vector3(coord.x * N * C, -1.0, coord.y * N * C), Vector3(N * C, L.storeys * H + 2.0, N * C))


func chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / (N * C)), floori(p.z / (N * C)))


func build(coord: Vector2i) -> ChunkData:
	var d := ChunkData.new()
	d.coord = coord
	d.bounds = chunk_bounds(coord)
	d.geo = GeoBuilder.new()
	for x in range(coord.x * N, (coord.x + 1) * N):
		for z in range(coord.y * N, (coord.y + 1) * N):
			for s in L.storeys:
				_cell(d, x, z, s, true)
	# Everything that collides is navigation source too; the level bakes one
	# navigation mesh from all chunks.
	d.nav_faces = d.geo.packed_nav()
	d.obstructions = d.geo.obstructions
	d.geo.finalize()
	return d


# --- Per cell -------------------------------------------------------------------------

func rng(x: int, z: int, s: int, purpose: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, x, z, s, purpose])
	return r


func _cell(d: ChunkData, x: int, z: int, s: int, full: bool) -> void:
	if not L.inside(x, z, s):
		return
	var k := L.kind_at(x, z, s)
	if k == LevelLayout.Kind.EMPTY:
		return
	var zn := L.zone_of(x, z, s)
	var st := zn.style
	var o := L.cell_origin(x, z, s)
	var flags := L.flags_at(x, z, s)
	var room := L.room_of(x, z, s)
	var floor_mat := floor_material(st, s, room)
	var wall_mat := wall_material(st, s, room)
	match k:
		LevelLayout.Kind.FLOOR:
			_floor(d, x, z, s, o, floor_mat, flags)
		LevelLayout.Kind.CATWALK:
			_catwalk(d, x, z, s, o, flags)
		LevelLayout.Kind.HOLE:
			_broken_floor(d, x, z, s, o, floor_mat)
	if flags & LevelLayout.STAIR:
		_flight(d, x, z, s, o)
	if flags & LevelLayout.STAIR_ABOVE and k == LevelLayout.Kind.FLOOR:
		_hole_rails(d, x, z, s, o)
	for dir in 4:
		_wall(d, x, z, s, o, dir, wall_mat, st, zn, full)
	if flags & LevelLayout.NARROW and k == LevelLayout.Kind.FLOOR:
		_narrow(d, x, z, s, o, st, wall_mat)
	_ceiling(d, x, z, s, o, st, zn, flags, full)
	if s == 0 and zn.type in TALL:
		_column(d, x, z, zn)
	if k == LevelLayout.Kind.FLOOR or k == LevelLayout.Kind.CATWALK:
		pieces.dress(d, x, z, s, o, st, zn, room, flags, full)
		if full and k == LevelLayout.Kind.FLOOR:
			_lights(d, x, z, s, o, st, zn, room, flags)


func floor_material(st: ZoneStyle, s: int, room: LevelLayout.Room) -> StringName:
	if room and room.use == &"washroom":
		return &"tiles_dirty"
	return st.floor_material if s == 0 else st.upper_floor_material


func wall_material(st: ZoneStyle, s: int, room: LevelLayout.Room) -> StringName:
	if room:
		match room.use:
			&"washroom":
				return &"tiles_dirty"
			&"boiler", &"electrical":
				return &"concrete_wall"
			&"stairwell":
				return &"concrete_wall"
	return st.wall_material if s == 0 else st.upper_wall_material


func surface_of(mat: StringName) -> StringName:
	return SURFACES.get(mat, &"concrete")


## Cell-local rectangle (x, z in 0..C) of a strip along one side.
func strip(side: int, depth: float) -> Rect2:
	match side:
		0:
			return Rect2(0, 0, C, depth)
		1:
			return Rect2(C - depth, 0, depth, C)
		2:
			return Rect2(0, C - depth, C, depth)
		_:
			return Rect2(0, 0, depth, C)


## Cell-local rectangle over the run of a flight climbing `dir` on `side`
## (the part of the strip it rises through; the rest of the strip is landing).
func run_rect(dir: int, side: int) -> Rect2:
	var sr := strip(side, STRIP)
	var f := LevelLayout.FOOT
	match dir:
		0:
			return Rect2(sr.position.x, C - f - RUN, sr.size.x, RUN).intersection(sr)
		1:
			return Rect2(f, sr.position.y, RUN, sr.size.y).intersection(sr)
		2:
			return Rect2(sr.position.x, f, sr.size.x, RUN).intersection(sr)
		_:
			return Rect2(C - f - RUN, sr.position.y, RUN, sr.size.y).intersection(sr)


## r minus hole, as up to four rectangles.
static func subtract(r: Rect2, hole: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var h := r.intersection(hole)
	if h.size.x <= 0.001 or h.size.y <= 0.001:
		out.append(r)
		return out
	if h.position.y > r.position.y:
		out.append(Rect2(r.position.x, r.position.y, r.size.x, h.position.y - r.position.y))
	if h.end.y < r.end.y:
		out.append(Rect2(r.position.x, h.end.y, r.size.x, r.end.y - h.end.y))
	if h.position.x > r.position.x:
		out.append(Rect2(r.position.x, h.position.y, h.position.x - r.position.x, h.size.y))
	if h.end.x < r.end.x:
		out.append(Rect2(h.end.x, h.position.y, r.end.x - h.end.x, h.size.y))
	return out


func slab(g: GeoBuilder, o: Vector3, r: Rect2, top: float, thick: float, mat: StringName, occlude: bool) -> void:
	if r.size.x < 0.01 or r.size.y < 0.01:
		return
	g.box(o + Vector3(r.position.x + r.size.x * 0.5, top - thick * 0.5, r.position.y + r.size.y * 0.5),
		Vector3(r.size.x, thick, r.size.y), mat, surface_of(mat), occlude)


func _floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName, flags: int) -> void:
	var thick := 0.5 if s == 0 else 0.3
	var rects: Array[Rect2] = [Rect2(0, 0, C, C)]
	if flags & LevelLayout.STAIR_ABOVE:
		rects = subtract(rects[0], run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s)))
	for r in rects:
		slab(d.geo, o, r, 0.0, thick, mat, s > 0 and r.size.x > 2.0 and r.size.y > 2.0)


func _catwalk(d: ChunkData, x: int, z: int, s: int, o: Vector3, flags: int) -> void:
	var sides := (flags >> 4) & 15
	var hole := Rect2()
	if flags & LevelLayout.STAIR_ABOVE:
		hole = run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s))
	for side in 4:
		if not (sides & (1 << side)):
			continue
		for r in subtract(strip(side, STRIP), hole):
			slab(d.geo, o, r, 0.0, 0.08, &"steel_grate", false)
		# Inner edge: support beam and railing, trimmed where other strips meet.
		var lateral := LevelLayout.dir_vector((side + 1) % 4)
		var inward := -LevelLayout.dir_vector(side)
		var edge_center := o + Vector3(C * 0.5, 0, C * 0.5) - inward * (C * 0.5 - STRIP)
		var a0 := -C * 0.5
		var a1 := C * 0.5
		if sides & (1 << ((side + 3) % 4)):
			a0 += STRIP
		if sides & (1 << ((side + 1) % 4)):
			a1 -= STRIP
		# A bridge leaves through the middle of this strip's inner edge.
		var bridge := LevelLayout.BRIDGE_X if side % 2 == 1 else LevelLayout.BRIDGE_Z
		var spans: Array[Vector2] = [Vector2(a0, a1)]
		if flags & bridge:
			spans.assign([Vector2(a0, -BRIDGE * 0.5), Vector2(BRIDGE * 0.5, a1)])
		if hole.size != Vector2.ZERO and L.hole_side(x, z, s) == side:
			# The flight comes up through this strip: rail the stub at its foot
			# and the landing, and close the stub off from the opening.
			var hd := LevelLayout.dir_vector(L.hole_dir(x, z, s))
			var lc := lateral.dot(o + Vector3(hole.get_center().x, 0, hole.get_center().y) - edge_center)
			var h0 := lc - RUN * 0.5
			var h1 := lc + RUN * 0.5
			spans.assign([Vector2(a0, h0), Vector2(h1, a1)])
			var low := edge_center + lateral * (h0 if lateral.dot(hd) > 0.0 else h1)
			railing(d.geo, low, low - inward * STRIP)
		for sp in spans:
			if sp.y - sp.x < 0.1:
				continue
			var p0 := edge_center + lateral * sp.x
			var p1 := edge_center + lateral * sp.y
			beam(d.geo, p0 + Vector3.DOWN * 0.24, p1 + Vector3.DOWN * 0.24, Vector2(0.14, 0.32), &"painted_steel")
			railing(d.geo, p0, p1)
	for axis in 2:
		var flag := LevelLayout.BRIDGE_X if axis == 0 else LevelLayout.BRIDGE_Z
		if flags & flag:
			_bridge(d, x, z, s, o, axis, sides, flags)


## Catwalk bridge through the middle of the cell along X (axis 0) or Z.
func _bridge(d: ChunkData, x: int, z: int, s: int, o: Vector3, axis: int, sides: int, flags: int) -> void:
	var lo := 0.0
	var hi := C
	# On a ring cell the bridge starts at the strip's inner edge.
	var minus_side := 3 if axis == 0 else 0
	var plus_side := 1 if axis == 0 else 2
	if sides & (1 << minus_side):
		lo = STRIP
	if sides & (1 << plus_side):
		hi = C - STRIP
	var w0 := C * 0.5 - BRIDGE * 0.5
	var r := Rect2(lo, w0, hi - lo, BRIDGE) if axis == 0 else Rect2(w0, lo, BRIDGE, hi - lo)
	slab(d.geo, o, r, 0.0, 0.08, &"steel_grate", false)
	var along := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
	var across := Vector3(0, 0, 1) if axis == 0 else Vector3(1, 0, 0)
	var cross := flags & LevelLayout.BRIDGE_X and flags & LevelLayout.BRIDGE_Z
	for e: float in [-1.0, 1.0]:
		var base := o + across * (C * 0.5 + e * BRIDGE * 0.5)
		var spans: Array[Vector2] = [Vector2(lo, hi)]
		if cross:
			spans.assign([Vector2(lo, w0), Vector2(w0 + BRIDGE, hi)])
		for sp in spans:
			if sp.y - sp.x < 0.1:
				continue
			var p0 := base + along * sp.x
			var p1 := base + along * sp.y
			beam(d.geo, p0 + Vector3.DOWN * 0.22, p1 + Vector3.DOWN * 0.22, Vector2(0.12, 0.3), &"painted_steel")
			railing(d.geo, p0, p1)
	# Hangers up to the roof truss, or a post down to the floor.
	var c := o + Vector3(C * 0.5, 0, C * 0.5)
	if s > 0 and (x + z) % 2 == 0:
		for e: float in [-1.0, 1.0]:
			var p := c + across * (e * (BRIDGE * 0.5 + 0.06))
			d.geo.box(p + Vector3.DOWN * (s * H * 0.5), Vector3(0.16, s * H, 0.16), &"painted_steel", &"metal")


func _broken_floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName) -> void:
	var r := rng(x, z, s, 4)
	# Jagged remains of the slab along a couple of edges.
	for side in 4:
		if r.randf() < 0.55:
			var sr := strip(side, r.randf_range(0.6, 1.6))
			slab(d.geo, o, sr, 0.0, 0.3, mat, false)
			# Rebar sticking out of the broken edge.
			var inward := -LevelLayout.dir_vector(side)
			var edge := o + Vector3(C * 0.5, -0.12, C * 0.5) - inward * (C * 0.5 - sr.size.x if side % 2 == 1 else C * 0.5 - sr.size.y)
			var lateral := LevelLayout.dir_vector((side + 1) % 4)
			for i in 5:
				var p := edge + lateral * r.randf_range(-3.6, 3.6)
				d.geo.cylinder(p, p + inward * r.randf_range(0.3, 0.9) + Vector3.DOWN * r.randf_range(0.0, 0.5), 0.012, &"rusted_metal", 4)
	if r.randf() < 0.7:
		var tilt := Basis.from_euler(Vector3(r.randf_range(-0.6, 0.6), r.randf() * TAU, r.randf_range(-0.5, 0.5)))
		d.geo.box(o + Vector3(r.randf_range(2.5, 5.5), -1.6, r.randf_range(2.5, 5.5)), Vector3(2.4, 0.25, 1.8), mat, &"", false, tilt)


## A flight up one storey along `side`, from the cell edge behind it to its
## landing in the same column.
func _flight(d: ChunkData, x: int, z: int, s: int, o: Vector3) -> void:
	var dir := L.stair_dir(x, z, s)
	var side := L.stair_side(x, z, s)
	var rr := run_rect(dir, side)
	var a := LevelLayout.dir_vector(dir)
	var center := o + Vector3(rr.position.x + rr.size.x * 0.5, 0.0, rr.position.y + rr.size.y * 0.5)
	var bottom := center - a * (RUN * 0.5)
	var top := center + a * (RUN * 0.5) + Vector3.UP * H
	var lateral := a.cross(Vector3.UP).normalized()
	var length := sqrt(RUN * RUN + H * H)
	var forward := (a * RUN + Vector3.UP * H).normalized()
	var up := lateral.cross(forward).normalized()
	if up.y < 0.0:
		up = -up
		lateral = -lateral
	var basis := Basis(lateral, up, forward)
	var mid := (bottom + top) * 0.5
	var width := STRIP - 0.35
	# Walkable ramp collider just under the step noses.
	d.geo.box(mid - up * 0.07, Vector3(width, 0.12, length), &"", &"metal", false, basis)
	# Treads
	var steps := int(round(H / 0.19))
	for i in steps:
		var t := (i + 0.5) / steps
		var p := bottom + a * (t * RUN) + Vector3.UP * ((i + 1) * H / steps - 0.025)
		d.geo.box(p, _oriented(a, Vector3(width, 0.05, RUN / steps + 0.03)), &"steel_grate")
	# Stringers and handrails on both edges
	for e: float in [-1.0, 1.0]:
		var off := lateral * (e * (width * 0.5 + 0.04))
		d.geo.box(mid + off - up * 0.12, Vector3(0.07, 0.34, length), &"painted_steel_yellow", &"", false, basis)
		d.geo.cylinder(bottom + off + Vector3.UP * 1.0, top + off + Vector3.UP * 1.0, 0.025, &"painted_steel_yellow", 6)
		for i in 3:
			var p := bottom.lerp(top, (i + 0.5) / 3.0) + off
			d.geo.box(p + Vector3.UP * 0.5, Vector3(0.04, 1.0, 0.04), &"painted_steel_yellow")
	# Clip guard on the open (inner) edge of the upper half of the flight.
	var inner := -LevelLayout.dir_vector(side)
	var gmid := center + inner * (width * 0.5 + 0.1) + a * (RUN * 0.2) + Vector3.UP * (H * 0.7 + 0.5)
	d.geo.box(gmid, Vector3(0.1, 1.2, length * 0.6), &"", &"metal", false, basis, Layers.CLIP)
	# Landing support under the top end when there's no floor slab there yet.
	d.geo.box(top + a * 0.05 + Vector3.DOWN * 0.15, _oriented(a, Vector3(width, 0.3, 0.2)), &"painted_steel")


func _oriented(along: Vector3, size: Vector3) -> Vector3:
	## size is (width, height, length along `along`) -> world axis-aligned size.
	return Vector3(size.z, size.y, size.x) if absf(along.x) > 0.5 else size


## Railings round the opening a flight comes up through.
func _hole_rails(d: ChunkData, x: int, z: int, s: int, o: Vector3) -> void:
	var rr := run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s))
	var side := L.hole_side(x, z, s)
	var a := LevelLayout.dir_vector(L.hole_dir(x, z, s))
	var inner := -LevelLayout.dir_vector(side)
	var c := o + Vector3(rr.position.x + rr.size.x * 0.5, 0.0, rr.position.y + rr.size.y * 0.5)
	var edge := c + inner * (STRIP * 0.5)
	railing(d.geo, edge - a * (RUN * 0.5), edge + a * (RUN * 0.5 - 1.0))
	# Across the low end of the opening (the flight's foot space is floor up here).
	var low := c - a * (RUN * 0.5)
	railing(d.geo, low + inner * (STRIP * 0.5), low - inner * (STRIP * 0.5 - 0.15))


func railing(g: GeoBuilder, p0: Vector3, p1: Vector3, mat: StringName = &"painted_steel_yellow") -> void:
	var length := p0.distance_to(p1)
	if length < 0.2:
		return
	var posts := maxi(int(ceil(length / 1.6)), 1)
	for i in posts + 1:
		var p := p0.lerp(p1, float(i) / posts)
		g.box(p + Vector3.UP * 0.55, Vector3(0.05, 1.1, 0.05), mat)
	for h: float in [0.55, 1.08]:
		g.cylinder(p0 + Vector3.UP * h, p1 + Vector3.UP * h, 0.022, mat, 6)
	var dir := (p1 - p0).normalized()
	var basis := Basis.looking_at(dir, Vector3.UP)
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.06, Vector3(0.012, 0.12, length), &"painted_steel", &"", false, basis)
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.6, Vector3(0.08, 1.2, length), &"", &"metal", false, basis, Layers.CLIP)


func beam(g: GeoBuilder, p0: Vector3, p1: Vector3, section: Vector2, mat: StringName, collide: bool = false) -> void:
	var length := p0.distance_to(p1)
	if length < 0.05:
		return
	var dir := (p1 - p0) / length
	var basis := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD)
	g.box((p0 + p1) * 0.5, Vector3(section.x, section.y, length), mat, surface_of(mat) if collide else &"", false, basis)


# --- Walls ----------------------------------------------------------------------------

func _wall(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, mat: StringName, st: ZoneStyle,
		zn: LevelLayout.Zone, full: bool) -> void:
	if not L.has_wall(x, z, s, dir):
		return
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	var n_enclosed := L.is_enclosed(n.x, n.y, s)
	# A wall between two built cells is split down the middle: each side
	# builds its own half, so it never depends on the neighbour's chunk.
	var depth := T * 0.5 if n_enclosed else T
	var inset := T * 0.25 if n_enclosed else 0.0
	var owns_trim := not n_enclosed or L.idx(x, z, s) < L.idx(n.x, n.y, s)
	var openings: Array = []
	var exterior := not n_enclosed
	if L.has_door(x, z, s, dir):
		var w := door_width(x, z, s, n, st)
		var h := door_height(x, z, s, n, st)
		openings.append([C * 0.5 - w * 0.5, C * 0.5 + w * 0.5, 0.0, h])
		if owns_trim:
			_door_frame(d, x, z, s, o, dir, openings.back())
	elif L.has_window(x, z, s, dir):
		openings.append([1.2, C - 1.2, 1.05, 2.45])
		if owns_trim:
			_interior_window(d, x, z, s, o, dir)
	elif s == 0 and exterior and L.has_flag(x, z, s, LevelLayout.DOCK):
		openings.append([1.2, C - 1.2, 0.0, 3.8])
		_shutter(d, x, z, s, o, dir)
	elif exterior and st.windows and s >= 1 and zn.type in TALL:
		openings.append([1.4, C - 1.4, 1.2, 3.6])
		_window(d, x, z, s, o, dir, full)
	_wall_with_openings(d.geo, o, dir, openings, mat, depth, inset)


func door_width(x: int, z: int, s: int, n: Vector2i, st: ZoneStyle) -> float:
	var w := st.ground_door_width if s == 0 else st.door_width
	var other := L.style_at(n.x, n.y, s)
	if other:
		w = maxf(w, other.ground_door_width if s == 0 else other.door_width)
	# Never wider than a cramped passage on either side.
	for c: Vector2i in [Vector2i(x, z), n]:
		if L.has_flag(c.x, c.y, s, LevelLayout.NARROW):
			w = minf(w, L.style_at(c.x, c.y, s).passage_width - 0.3)
	return w


func door_height(x: int, z: int, s: int, n: Vector2i, st: ZoneStyle) -> float:
	var h := st.ground_door_height if s == 0 else st.door_height
	var other := L.style_at(n.x, n.y, s)
	if other:
		h = maxf(h, other.ground_door_height if s == 0 else other.door_height)
	for c: Vector2i in [Vector2i(x, z), n]:
		if L.has_flag(c.x, c.y, s, LevelLayout.NARROW):
			h = minf(h, 2.3)
	return minf(h, H - 0.6)


## Wall on the `dir` edge of the cell, minus openings [a0, a1, y0, y1] in
## cell-local "along the wall" coordinates (0..C) and storey-local heights.
func _wall_with_openings(g: GeoBuilder, o: Vector3, dir: int, openings: Array, mat: StringName,
		depth: float = T, inset: float = 0.0) -> void:
	var cuts: Array = [0.0, C]
	for op in openings:
		cuts.append(op[0])
		cuts.append(op[1])
	cuts.sort()
	for i in cuts.size() - 1:
		var a0: float = cuts[i]
		var a1: float = cuts[i + 1]
		if a1 - a0 < 0.001:
			continue
		var mid := (a0 + a1) * 0.5
		var solids: Array = [Vector2(0.0, H)]
		for op in openings:
			if mid > op[0] and mid < op[1]:
				var next: Array = []
				for sp: Vector2 in solids:
					if op[3] <= sp.x or op[2] >= sp.y:
						next.append(sp)
						continue
					if op[2] > sp.x:
						next.append(Vector2(sp.x, op[2]))
					if op[3] < sp.y:
						next.append(Vector2(op[3], sp.y))
				solids = next
		for sp: Vector2 in solids:
			var e0 := a0 - (T * 0.5 if a0 <= 0.0 else 0.0)
			var e1 := a1 + (T * 0.5 if a1 >= C else 0.0)
			wall_box(g, o, dir, e0, e1, sp.x, sp.y, mat, true, depth, inset)


func wall_box(g: GeoBuilder, o: Vector3, dir: int, a0: float, a1: float, y0: float, y1: float, mat: StringName,
		collide: bool, depth: float = T, inset: float = 0.0, layer: int = 1) -> void:
	var along := (a0 + a1) * 0.5
	var length := a1 - a0
	var center: Vector3
	var size: Vector3
	match dir:
		0:
			center = Vector3(along, 0, inset)
			size = Vector3(length, 0, depth)
		1:
			center = Vector3(C - inset, 0, along)
			size = Vector3(depth, 0, length)
		2:
			center = Vector3(along, 0, C - inset)
			size = Vector3(length, 0, depth)
		_:
			center = Vector3(inset, 0, along)
			size = Vector3(depth, 0, length)
	center.y = (y0 + y1) * 0.5
	size.y = y1 - y0
	var big := size.y > 2.0 and length > 2.0
	g.box(o + center, size, mat, surface_of(mat) if collide else &"", collide and big and layer == 1, Basis.IDENTITY, layer)


func _door_frame(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, op: Array) -> void:
	var a0: float = op[0]
	var a1: float = op[1]
	var h: float = op[3]
	var g := d.geo
	wall_box(g, o, dir, a0 - 0.08, a0, 0.0, h + 0.08, &"rusted_metal", false, T + 0.06)
	wall_box(g, o, dir, a1, a1 + 0.08, 0.0, h + 0.08, &"rusted_metal", false, T + 0.06)
	wall_box(g, o, dir, a0 - 0.08, a1 + 0.08, h, h + 0.1, &"rusted_metal", false, T + 0.06)
	# Narrow doors keep a leaf: hanging open, half off its hinges, or flat on the floor.
	var w := a1 - a0
	if w > 1.6:
		return
	var r := rng(x, z, s, 20 + dir)
	var roll := r.randf()
	if roll < 0.35:
		return
	var hinge_a := a0 if r.randf() < 0.5 else a1
	var inward := -LevelLayout.dir_vector(dir)
	if r.randf() < 0.5:
		inward = -inward  # opens into the neighbour
	var along := LevelLayout.dir_vector((dir + 1) % 4)
	var edge := o + Vector3(C * 0.5, 0, C * 0.5) + LevelLayout.dir_vector(dir) * (C * 0.5)
	var hinge := edge + along * (hinge_a - C * 0.5)
	var toward := along * (1.0 if hinge_a == a0 else -1.0)
	var mat: StringName = [&"painted_steel_blue", &"painted_steel", &"wood_planks", &"painted_steel_green"][r.randi_range(0, 3)]
	if roll < 0.85:
		# Swung open, resting against the wall at 80-110 degrees.
		var ang := deg_to_rad(r.randf_range(75.0, 105.0))
		var leaf_dir := (toward * cos(ang) + inward * sin(ang)).normalized()
		var basis := Basis.looking_at(leaf_dir, Vector3.UP)
		var sag := r.randf_range(0.0, 0.06) if roll > 0.7 else 0.0
		g.box(hinge + leaf_dir * (w * 0.5) + Vector3.UP * (h * 0.5 - 0.02 - sag), Vector3(0.05, h - 0.06, w - 0.04), mat, &"", false,
			basis * Basis(Vector3.FORWARD, sag * 2.0))
	else:
		# Torn off, lying in the room.
		var p := edge + inward * r.randf_range(1.2, 1.8) + along * r.randf_range(-0.8, 0.8)
		var basis := Basis(Vector3.UP, r.randf() * TAU) * Basis(Vector3.RIGHT, r.randf_range(-0.12, 0.12))
		g.box(p + Vector3.UP * 0.04, Vector3(w - 0.04, 0.05, h - 0.06), mat, &"", false, basis)


## Window between two interior spaces: frame, mullions, some glass left.
func _interior_window(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int) -> void:
	var g := d.geo
	var r := rng(x, z, s, 30 + dir)
	var a0 := 1.2
	var a1 := C - 1.2
	wall_box(g, o, dir, a0 - 0.06, a1 + 0.06, 0.98, 1.05, &"painted_steel", false, T + 0.12)  # sill
	wall_box(g, o, dir, a0 - 0.06, a1 + 0.06, 2.45, 2.52, &"painted_steel", false, T + 0.04)
	var panes := 4
	var pw := (a1 - a0) / panes
	for i in panes + 1:
		var a := a0 + i * pw
		wall_box(g, o, dir, a - 0.04, a + 0.04, 1.05, 2.45, &"painted_steel", false, 0.08)
	for i in panes:
		var roll := r.randf()
		if roll < 0.4:
			wall_box(g, o, dir, a0 + i * pw + 0.04, a0 + (i + 1) * pw - 0.04, 1.05, 2.45, &"glass_dirty", false, 0.02)
		elif roll < 0.6:
			# Shards left in the bottom of the frame.
			wall_box(g, o, dir, a0 + i * pw + 0.04, a0 + (i + 1) * pw - 0.04, 1.05, 1.05 + r.randf_range(0.1, 0.4), &"glass_dirty", false, 0.02)
	# Blocks walking through, not bullets.
	wall_box(g, o, dir, a0, a1, 1.05, 2.45, &"", true, 0.1, 0.0, Layers.CLIP)


func _shutter(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int) -> void:
	var r := rng(x, z, s, 40 + dir)
	var open := r.randf()
	var bottom := 0.0
	if open < 0.3:
		bottom = r.randf_range(0.5, 1.4)  # jammed half open, light spills under it
	wall_box(d.geo, o, dir, 1.2, C - 1.2, bottom, 3.8, &"corrugated_metal", bottom < 0.4, 0.12, -0.12)
	wall_box(d.geo, o, dir, 1.0, C - 1.0, 3.8, 4.3, &"rusted_metal", true, 0.5, -0.1)
	for a: float in [1.1, C - 1.1]:
		wall_box(d.geo, o, dir, a - 0.1, a + 0.1, 0.0, 3.8, &"painted_steel_yellow", true, 0.4, 0.05)  # guides
	if bottom > 0.0:
		wall_box(d.geo, o, dir, 1.2, C - 1.2, 0.0, bottom, &"", true, 0.1, -0.12)  # nothing crawls out
		var out := LevelLayout.dir_vector(dir)
		var c := o + Vector3(C * 0.5, bottom, C * 0.5) + out * (C * 0.5 + 2.5)
		d.lights.append({"type": "spot", "position": c + Vector3.UP * 0.4, "target": c - out * 6.0,
			"color": Color(0.75, 0.8, 0.88), "energy": 5.0, "range": 12.0, "angle": 40.0, "shadow": true, "fog": 2.0})


func _window(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, full: bool) -> void:
	var r := rng(x, z, s, 10 + dir)
	for a: float in [C / 3.0, C * 2.0 / 3.0]:
		wall_box(d.geo, o, dir, a - 0.05, a + 0.05, 1.2, 3.6, &"rusted_metal", false, 0.1)
	wall_box(d.geo, o, dir, 1.4, C - 1.4, 2.35, 2.45, &"rusted_metal", false, 0.1)
	for pane in 6:
		if r.randf() < 0.35:
			var a := 1.4 + (pane % 3) * (C - 2.8) / 3.0
			var y := 1.2 if pane < 3 else 2.45
			wall_box(d.geo, o, dir, a + 0.06, a + (C - 2.8) / 3.0 - 0.06, y + 0.05, y + 1.1, &"glass_dirty", false, 0.02)
	if full and r.randf() < 0.3:
		var out := LevelLayout.dir_vector(dir)
		var c := o + Vector3(C * 0.5, 2.4, C * 0.5) + out * (C * 0.5)
		var target := c - out * 5.0 + Vector3.DOWN * 2.4
		d.lights.append({"type": "spot", "position": c + out * 6.0 + Vector3.UP * 3.0, "target": target,
			"color": Color(0.74, 0.8, 0.9), "energy": 8.0, "range": 24.0, "angle": 20.0, "shadow": true,
			"fog": 3.0})


# --- Cramped passages -------------------------------------------------------------------

## Fills the cell solid except a narrow cross of passages toward its open
## edges: service corridors and the hallways inside office blocks.
func _narrow(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, mat: StringName) -> void:
	for r in narrow_solids(x, z, s, st):
		d.geo.box(o + Vector3(r.position.x + r.size.x * 0.5, H * 0.5, r.position.y + r.size.y * 0.5),
			Vector3(r.size.x, H, r.size.y), mat, surface_of(mat), true)


## Cell-local rects of the solid fill around a cramped passage.
func narrow_solids(x: int, z: int, s: int, st: ZoneStyle) -> Array[Rect2]:
	var w := st.passage_width
	var h0 := C * 0.5 - w * 0.5
	var h1 := C * 0.5 + w * 0.5
	var open := L.open_edges(x, z, s)
	var out: Array[Rect2] = [Rect2(0, 0, h0, h0), Rect2(h1, 0, C - h1, h0), Rect2(0, h1, h0, C - h1), Rect2(h1, h1, C - h1, C - h1)]
	if not open & 1:
		out.append(Rect2(h0, 0, w, h0))
	if not open & 2:
		out.append(Rect2(h1, h0, C - h1, w))
	if not open & 4:
		out.append(Rect2(h0, h1, w, C - h1))
	if not open & 8:
		out.append(Rect2(0, h0, h0, w))
	return out


## Cell-local rects of the walkable part of a cramped passage.
func narrow_open(x: int, z: int, s: int, st: ZoneStyle) -> Array[Rect2]:
	var w := st.passage_width
	var h0 := C * 0.5 - w * 0.5
	var h1 := C * 0.5 + w * 0.5
	var open := L.open_edges(x, z, s)
	var out: Array[Rect2] = [Rect2(h0, h0, w, w)]
	if open & 1:
		out.append(Rect2(h0, 0, w, h0))
	if open & 2:
		out.append(Rect2(h1, h0, C - h1, w))
	if open & 4:
		out.append(Rect2(h0, h1, w, C - h1))
	if open & 8:
		out.append(Rect2(0, h0, h0, w))
	return out


# --- Ceilings and columns -----------------------------------------------------------------

func ceiling_height(st: ZoneStyle, zn: LevelLayout.Zone, room: LevelLayout.Room, x: int, z: int, s: int) -> float:
	if st.drop_ceiling > 0.0 and not L.has_flag(x, z, s, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) \
			and L.kind_at(x, z, s) == LevelLayout.Kind.FLOOR and not (room and room.use in [&"stairwell", &"boiler"]) \
			and zn.type not in TALL:
		return st.drop_ceiling
	if zn.type in TALL and s == 0:
		return (zn.top + 1) * H
	return H


func _ceiling(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone, flags: int,
		full: bool) -> void:
	var room := L.room_of(x, z, s)
	var hc := ceiling_height(st, zn, room, x, z, s)
	if hc < H - 0.01:
		_drop_ceiling(d, x, z, s, o, st, hc)
	var above := L.kind_at(x, z, s + 1)
	var above_zone := L.zone_at(x, z, s + 1)
	var need := above == LevelLayout.Kind.EMPTY or (above_zone != zn.id and above != LevelLayout.Kind.FLOOR
		and above != LevelLayout.Kind.CATWALK)
	if not need:
		return
	if flags & LevelLayout.ROOF_HOLE:
		var r := rng(x, z, s, 6)
		# What's left of the roof: a ragged edge, a sheet hanging in.
		for side in 4:
			if r.randf() < 0.5:
				slab(d.geo, o, strip(side, r.randf_range(0.5, 1.8)), H, 0.3, st.ceiling_material, false)
		var tilt := Basis.from_euler(Vector3(r.randf_range(0.6, 1.1), r.randf() * TAU, r.randf_range(-0.3, 0.3)))
		d.geo.box(o + Vector3(r.randf_range(1.0, 7.0), H - 1.2, r.randf_range(1.0, 7.0)), Vector3(3.5, 0.1, 2.0),
			&"corrugated_metal", &"metal", false, tilt)
		if full:
			var hole := o + Vector3(C * 0.5, H, C * 0.5)
			var sun := SUN_DIR.normalized()
			d.lights.append({"type": "spot", "position": hole - sun * 10.0, "target": hole + sun * 6.0,
				"color": Color(0.78, 0.83, 0.92), "energy": 12.0, "range": 40.0, "angle": 17.0,
				"shadow": true, "fog": 4.0})
		return
	slab(d.geo, o, Rect2(0, 0, C, C), H, 0.3, st.ceiling_material, true)
	if zn.type in TALL or (zn.type == &"processing" and L.room_at(x, z, s) == 0):
		# Roof trusses
		d.geo.box(o + Vector3(C * 0.5, H - 0.55, C * 0.5), Vector3(C, 0.45, 0.22), &"painted_steel")
		d.geo.box(o + Vector3(C * 0.5, H - 0.25, 0.0), Vector3(C, 0.12, 0.12), &"rusted_metal")
		for i in 3:
			var xx := 1.0 + i * 3.0
			d.geo.box(o + Vector3(xx, H - 0.45, C * 0.5), Vector3(0.08, 0.3, C), &"rusted_metal")


## Suspended tile ceiling: T-bar grid, tiles with gaps where they've fallen,
## some hanging by a corner, a duct showing through.
func _drop_ceiling(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, hc: float) -> void:
	var r := rng(x, z, s, 7)
	var g := d.geo
	var areas: Array[Rect2] = [Rect2(0, 0, C, C)]
	if L.has_flag(x, z, s, LevelLayout.NARROW):
		areas = narrow_open(x, z, s, st)
	var tile := Vector2(1.2, 0.6)
	var decay := r.randf_range(0.05, 0.4)
	for area in areas:
		var nx := int(round(area.size.x / tile.x)) if area.size.x >= tile.x else 1
		var nz := int(round(area.size.y / tile.y)) if area.size.y >= tile.y else 1
		var tw := area.size.x / nx
		var tz := area.size.y / nz
		for i in nx:
			for j in nz:
				var p := o + Vector3(area.position.x + (i + 0.5) * tw, hc + 0.01, area.position.y + (j + 0.5) * tz)
				var roll := r.randf()
				if roll < decay:
					continue  # missing
				if roll < decay + 0.03:
					# Hanging by one edge
					var basis := Basis(Vector3.RIGHT if r.randf() < 0.5 else Vector3.BACK, r.randf_range(0.6, 1.3))
					g.box(p + Vector3.DOWN * 0.25, Vector3(tw - 0.03, 0.02, tz - 0.03), &"ceiling_tile", &"", false, basis)
					continue
				g.box(p, Vector3(tw - 0.03, 0.02, tz - 0.03), &"ceiling_tile")
		# T-bars
		for i in nx + 1:
			var px := area.position.x + i * tw
			g.box(o + Vector3(px, hc + 0.01, area.position.y + area.size.y * 0.5), Vector3(0.025, 0.035, area.size.y), &"painted_steel")
		for j in nz + 1:
			var pz := area.position.y + j * tz
			g.box(o + Vector3(area.position.x + area.size.x * 0.5, hc + 0.01, pz), Vector3(area.size.x, 0.035, 0.025), &"painted_steel")
	# Fallen tiles on the floor
	for i in int(decay * 10.0):
		var p := o + Vector3(r.randf_range(0.8, C - 0.8), 0.02, r.randf_range(0.8, C - 0.8))
		if L.has_flag(x, z, s, LevelLayout.NARROW):
			p = o + Vector3(C * 0.5 + r.randf_range(-0.8, 0.8), 0.02, C * 0.5 + r.randf_range(-0.8, 0.8))
		var basis := Basis(Vector3.UP, r.randf() * TAU) * Basis(Vector3.RIGHT, r.randf_range(-0.25, 0.25))
		if r.randf() < 0.5:
			g.box(p, Vector3(tile.x * r.randf_range(0.4, 1.0), 0.02, tile.y * r.randf_range(0.5, 1.0)), &"ceiling_tile", &"", false, basis)
	# Ducting above the grid, seen through the gaps
	var along_x := (x + s) % 2 == 0
	var dc := o + Vector3(C * 0.5, hc + 0.5, C * 0.5)
	if L.has_flag(x, z, s, LevelLayout.NARROW):
		var open := L.open_edges(x, z, s)
		along_x = (open & 10) != 0
	var duct_len := C if not L.has_flag(x, z, s, LevelLayout.NARROW) else C
	g.box(dc, Vector3(duct_len, 0.4, 0.7) if along_x else Vector3(0.7, 0.4, duct_len), &"corrugated_metal")


func _column(d: ChunkData, x: int, z: int, zn: LevelLayout.Zone) -> void:
	var r := zn.rect
	if x == r.position.x or z == r.position.y or (x - r.position.x) % 2 != 0 or (z - r.position.y) % 2 != 0:
		return
	var height := (zn.top + 1) * H - 0.3
	var base := L.cell_origin(x, z, 0)
	d.geo.mesh(_ibeam, Transform3D(Basis.from_scale(Vector3(1, height, 1)), base))
	d.geo.box(base + Vector3(0, height * 0.5, 0), Vector3(0.32, height, 0.32), &"", &"metal")
	# Column foot and a knee brace
	d.geo.box(base + Vector3(0, 0.15, 0), Vector3(0.6, 0.3, 0.6), &"concrete_dark", &"concrete")


func _make_ibeam() -> Dictionary:
	var k := MeshKit.new()
	var w := 0.32
	var dd := 0.3
	var f := 0.03
	var web := 0.018
	var profile := PackedVector2Array([
		Vector2(-dd * 0.5, -w * 0.5), Vector2(-dd * 0.5 + f, -w * 0.5), Vector2(-dd * 0.5 + f, -web * 0.5),
		Vector2(dd * 0.5 - f, -web * 0.5), Vector2(dd * 0.5 - f, -w * 0.5), Vector2(dd * 0.5, -w * 0.5),
		Vector2(dd * 0.5, w * 0.5), Vector2(dd * 0.5 - f, w * 0.5), Vector2(dd * 0.5 - f, web * 0.5),
		Vector2(-dd * 0.5 + f, web * 0.5), Vector2(-dd * 0.5 + f, w * 0.5), Vector2(-dd * 0.5, w * 0.5)])
	var mat: Material = load("res://assets/materials/painted_steel.tres")
	k.at(Vector3(0, 0.5, 0), Vector3(0, 0, 90)).extrude(profile, 1.0, mat, 0.0, 10.0)
	var mesh := k.commit()
	var arrays := mesh.surface_get_arrays(0)
	return {&"painted_steel": [arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL]]}


# --- Kit props --------------------------------------------------------------------------

## Reads every kit scene once so its meshes can be merged into chunk geometry.
func _load_kit() -> void:
	for f in ResourceLoader.list_directory("res://levels/kit"):
		if not f.ends_with(".tscn"):
			continue
		var id := f.get_basename()
		if id in NODE_PROPS:
			continue
		var scene := load("res://levels/kit/" + f) as PackedScene
		var root := scene.instantiate() as Node3D
		var arrays := {}
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.mesh == null:
				continue
			var xf := root.global_transform.affine_inverse() * m.global_transform if root.is_inside_tree() else _relative(root, m)
			for i in m.mesh.get_surface_count():
				var mat := m.get_surface_override_material(i)
				if mat == null:
					mat = m.mesh.surface_get_material(i)
				var mat_name := StringName(mat.resource_path.get_file().get_basename()) if mat and mat.resource_path != "" else &"prop_steel"
				var a := m.mesh.surface_get_arrays(i)
				var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
				var index: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var nb := xf.basis.inverse().transposed()
				if not arrays.has(mat_name):
					arrays[mat_name] = [PackedVector3Array(), PackedVector3Array()]
				var dst: Array = arrays[mat_name]
				var dv: PackedVector3Array = dst[0]
				var dn: PackedVector3Array = dst[1]
				if index.is_empty():
					for j in verts.size():
						dv.append(xf * verts[j])
						dn.append((nb * normals[j]).normalized())
				else:
					for j in index:
						dv.append(xf * verts[j])
						dn.append((nb * normals[j]).normalized())
				dst[0] = dv
				dst[1] = dn
		_kit[id] = {"arrays": arrays, "surface": StringName(root.get_meta(&"surface", &"metal"))}
		root.free()


static func _relative(root: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != root and cur != null:
		xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## Places a kit prop: merged into the chunk mesh with a box collider (or a
## node for lamps). Returns the node index for node props, else -1.
func kit(d: ChunkData, id: String, pos: Vector3, yaw: float, options: Dictionary = {}, tilt: Basis = Basis.IDENTITY) -> int:
	var xform := Transform3D(Basis(Vector3.UP, yaw) * tilt, pos)
	var collide: bool = options.get("collide", true)
	if FOOTPRINTS.has(id) and collide:
		var fp: Array = FOOTPRINTS[id]
		var size: Vector3 = fp[0]
		var surf: StringName = _kit[id]["surface"] if _kit.has(id) else &"metal"
		d.geo.box(xform * (Vector3.UP * float(fp[1])), size, &"", surf, false, xform.basis)
	if not d.geo.visuals:
		return -1
	if _kit.has(id):
		d.geo.mesh(_kit[id]["arrays"], xform)
		return -1
	d.props.append([id, xform, options])
	return d.props.size() - 1


# --- Lights -----------------------------------------------------------------------------

func _lights(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone,
		room: LevelLayout.Room, flags: int) -> void:
	var r := rng(x, z, s, 3)
	if r.randf() > st.light_chance:
		return
	var working := r.randf() < st.light_working
	var flicker := working and r.randf() < st.flicker_chance
	var hc := ceiling_height(st, zn, room, x, z, s)
	var narrow := flags & LevelLayout.NARROW != 0
	var kind := st.light_kind
	if narrow or (room and room.use in [&"cubicles", &"offices", &"meeting", &"archive", &"washroom", &"lab"]):
		kind = &"fluorescent"
	match kind:
		&"cage":
			var wall := -1
			for i in 4:
				var dir := (i + r.randi_range(0, 3)) % 4
				if _wall_free(x, z, s, dir):
					wall = dir
					break
			var pos: Vector3
			var yaw := 0.0
			if wall >= 0:
				pos = L.wall_point(x, z, s, wall, minf(hc - 0.6, 3.0), r.randf_range(-1.5, 1.5))
				var inward := -LevelLayout.dir_vector(wall)
				yaw = atan2(inward.x, inward.z)
			else:
				pos = o + Vector3(C * 0.5, hc - 0.4, C * 0.5)
			var prop := kit(d, "cage_lamp", pos, yaw, {"dead": not working})
			if working:
				d.lights.append({"type": "omni", "position": pos + Basis(Vector3.UP, yaw) * Vector3(0, -0.1, 0.25),
					"color": st.light_color, "energy": st.light_energy, "range": 9.0, "shadow": r.randf() < 0.15,
					"flicker": 0.85 if flicker else 0.0, "prop": prop, "emissive": "Bulb", "fog": 1.2})
		&"fluorescent":
			var pos := o + Vector3(C * 0.5, hc - (0.07 if hc < H - 0.01 else 1.0), C * 0.5)
			var yaw := 0.0 if r.randf() < 0.5 else PI * 0.5
			if narrow:
				yaw = PI * 0.5 if L.open_edges(x, z, s) & 5 else 0.0
			var prop := kit(d, "fluorescent", pos, yaw, {"dead": not working})
			if working:
				d.lights.append({"type": "omni", "position": pos + Vector3.DOWN * 0.25, "color": st.light_color,
					"energy": st.light_energy, "range": 8.0 if narrow else 9.5, "shadow": r.randf() < 0.25,
					"flicker": 0.9 if flicker else 0.0, "prop": prop, "emissive": "Tubes", "buzz": true, "fog": 1.0})
			if zn.type == &"processing" and r.randf() < 0.05:
				d.lights.append({"type": "omni", "position": L.wall_point(x, z, s, r.randi_range(0, 3), hc - 0.6),
					"color": Color(1.0, 0.15, 0.08), "energy": 1.5, "range": 6.0, "pulse": true, "fog": 1.5})
		&"hanging":
			if s != 0 or (x + z) % 2 != 0:
				return
			var top := hc if zn.type in TALL else (zn.top + 1) * H
			var pos := o + Vector3(C * 0.5, top - 2.6, C * 0.5)
			var prop := kit(d, "lamp_hanging", pos, 0.0, {"dead": not working})
			if working:
				d.lights.append({"type": "spot", "position": pos + Vector3.DOWN * 0.15, "target": pos + Vector3.DOWN * 10.0,
					"color": st.light_color, "energy": st.light_energy, "range": top + 4.0, "angle": 58.0,
					"shadow": r.randf() < 0.5, "flicker": 0.85 if flicker else 0.0, "prop": prop, "emissive": "Bulb",
					"fog": 1.4})


func _wall_free(x: int, z: int, s: int, dir: int) -> bool:
	return L.has_wall(x, z, s, dir) and not L.has_door(x, z, s, dir) and not L.has_window(x, z, s, dir) \
		and not (L.stair_sides(x, z, s) & (1 << dir)) and not L.has_flag(x, z, s, LevelLayout.NARROW)
