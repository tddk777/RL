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
## Parapet above a roofline, boundary walls of yards, wall footings below
## the ground floor, clear height of a covered walkway.
const PARAPET := 0.9
const YARD_WALL := 3.2
const FOUNDATION := 0.3
const PASSAGE := 3.2
## Below ground: walls stop this far under the next storey's floor level (the
## underside of a ground-floor slab); a tunnel's own roof is buried just under
## the ground.
const BURIED := 0.5
const BURIED_ROOF := 0.1
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
	## World AABBs of everything solid placed so far (set pieces check it
	## before adding clutter).
	var taken: Array[AABB] = []


var L: LevelLayout
var C: float
var H: float
var N: int
var pieces: SetPieces
## Debugging: chunks list their visible solids (GeoBuilder.solids).
var record_solids: bool = false
var _ibeam: Dictionary  # material -> [verts, normals], unit height
## Kit prop id -> {"arrays": material -> [verts, normals], "surface": StringName}
var _kit: Dictionary = {}
## Steps (cells) from each cell to the nearest exit along walkable links,
## -1 = no way out (signs point the way with it).
var exit_dist := PackedInt32Array()


## Must be created on the main thread (reads kit scenes, builds shared meshes).
func _init(layout: LevelLayout) -> void:
	L = layout
	C = layout.cell
	H = layout.storey_height
	N = layout.profile.chunk_cells
	_ibeam = _make_ibeam()
	_load_kit()
	_exit_distances()
	pieces = SetPieces.new(self)


func _exit_distances() -> void:
	exit_dist.resize(L.size.x * L.size.y * (L.storeys + L.basement))
	exit_dist.fill(-1)
	var queue: Array[Vector3i] = []
	for e in L.exits:
		var c: Vector3i = e["cell"]
		if L.inside(c.x, c.y, c.z) and exit_dist[L.idx(c.x, c.y, c.z)] < 0:
			exit_dist[L.idx(c.x, c.y, c.z)] = 0
			queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var dist := exit_dist[L.idx(c.x, c.y, c.z)]
		for n in L.links(c.x, c.y, c.z):
			var j := L.idx(n.x, n.y, n.z)
			if exit_dist[j] < 0:
				exit_dist[j] = dist + 1
				queue.append(n)


func chunk_count() -> Vector2i:
	return Vector2i(ceili(float(L.size.x) / N), ceili(float(L.size.y) / N))


func chunk_bounds(coord: Vector2i) -> AABB:
	var y0 := -L.basement * H - 1.0
	return AABB(Vector3(coord.x * N * C, y0, coord.y * N * C), Vector3(N * C, L.storeys * H + 2.0 - y0 - 1.0, N * C))


func chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / (N * C)), floori(p.z / (N * C)))


func build(coord: Vector2i) -> ChunkData:
	var d := ChunkData.new()
	d.coord = coord
	d.bounds = chunk_bounds(coord)
	d.geo = GeoBuilder.new()
	d.geo.record_solids = record_solids
	for x in range(coord.x * N, (coord.x + 1) * N):
		for z in range(coord.y * N, (coord.y + 1) * N):
			for s: int in L.all_storeys():
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
	var o := L.cell_origin(x, z, s)
	if k == LevelLayout.Kind.EMPTY:
		if s == 0:
			pieces.outside(d, x, z, o)
		return
	var zn := L.zone_of(x, z, s)
	var st := zn.style
	var flags := L.flags_at(x, z, s)
	var room := L.room_of(x, z, s)
	if zn.type == &"connector":
		_connector(d, x, z, s, o, st)
		pieces.dress(d, x, z, s, o, st, zn, room, flags, full)
		if full:
			_lights(d, x, z, s, o, st, zn, room, flags)
		return
	var floor_mat := floor_material(st, s, room)
	var wall_mat := wall_material(st, s, room)
	match k:
		LevelLayout.Kind.FLOOR:
			_floor(d, x, z, s, o, floor_mat, flags)
		LevelLayout.Kind.CATWALK:
			_catwalk(d, x, z, s, o, flags)
		LevelLayout.Kind.HOLE:
			_broken_floor(d, x, z, s, o, floor_mat)
	_level_feature(d, x, z, s, o, floor_mat)
	if flags & LevelLayout.STAIR:
		_flight(d, x, z, s, o)
	if flags & LevelLayout.STAIR_ABOVE and k == LevelLayout.Kind.FLOOR:
		_hole_rails(d, x, z, s, o)
	for dir in 4:
		_wall(d, x, z, s, o, dir, wall_mat, st, zn, full)
	_pillars(d, x, z, s, wall_mat)
	_partials(d, x, z, s, o, wall_mat)
	_chamfers(d, x, z, s, o, wall_mat, zn, full)
	if flags & LevelLayout.NARROW and k == LevelLayout.Kind.FLOOR:
		_narrow(d, x, z, s, o, st, wall_mat)
	if zn.type != &"yard":
		_ceiling(d, x, z, s, o, st, zn, flags, full)
	if s == 0 and zn.type in TALL:
		_column(d, x, z, zn)
	if k == LevelLayout.Kind.FLOOR or k == LevelLayout.Kind.CATWALK:
		pieces.dress(d, x, z, s, o, st, zn, room, flags, full)
		if full and k == LevelLayout.Kind.FLOOR:
			_lights(d, x, z, s, o, st, zn, room, flags)


## Direction the overcast daylight comes from (fixed per level seed).
func sun_dir() -> Vector3:
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, 99])
	var az := r.randf() * TAU
	var el := deg_to_rad(52.0)
	return Vector3(cos(az) * cos(el), -sin(el), sin(az) * cos(el))


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



## r minus every rect in holes.
static func subtract_all(r: Rect2, holes: Array[Rect2]) -> Array[Rect2]:
	var out: Array[Rect2] = [r]
	for h in holes:
		var next: Array[Rect2] = []
		for q in out:
			next.append_array(subtract(q, h))
		out = next
	return out


## A slab closes the top of this cell: the floor of the storey above, or its
## own ceiling.
func slab_over(x: int, z: int, s: int) -> bool:
	if L.kind_at(x, z, s + 1) == LevelLayout.Kind.FLOOR:
		return true
	if not L.is_enclosed(x, z, s) or L.has_flag(x, z, s, LevelLayout.ROOF_HOLE):
		return false
	var zn := L.zone_of(x, z, s)
	return zn.type != &"yard" and zn.type != &"connector" and needs_ceiling(x, z, s, zn)


func needs_ceiling(x: int, z: int, s: int, zn: LevelLayout.Zone) -> bool:
	var above := L.kind_at(x, z, s + 1)
	if s < 0:
		# Under a building or yard its ground floor is the tunnel's roof;
		# anywhere else the tunnel has its own, buried under the ground.
		return above != LevelLayout.Kind.FLOOR or L.zone_of(x, z, s + 1).type == &"connector"
	return above == LevelLayout.Kind.EMPTY or (L.zone_at(x, z, s + 1) != zn.id and above != LevelLayout.Kind.FLOOR
		and above != LevelLayout.Kind.CATWALK)


## Convex pieces (cell-local polygons) of a slab whose top is the top of
## storey `sw` (sw < 0 for a ground floor). It stops at the full-height walls
## and pillars of storey sw - their tops make the floor there - and at cut
## corners, so no face of it shares a plane with a wall.
func slab_pieces(x: int, z: int, sw: int, rects: Array[Rect2], s_cell: int) -> Array[PackedVector2Array]:
	var e := T * 0.5
	var walled: Array[bool] = [false, false, false, false]
	if sw >= 0:
		for dir in 4:
			walled[dir] = edge_top(x, z, sw, dir) >= H - 0.01
	var polys: Array[PackedVector2Array] = []
	for r in rects:
		var x0 := r.position.x
		var z0 := r.position.y
		var x1 := r.end.x
		var z1 := r.end.y
		if walled[0]:
			z0 = maxf(z0, e)
		if walled[1]:
			x1 = minf(x1, C - e)
		if walled[2]:
			z1 = minf(z1, C - e)
		if walled[3]:
			x0 = maxf(x0, e)
		if x1 - x0 > 0.01 and z1 - z0 > 0.01:
			polys.append(PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]))
	if sw >= 0:
		# Pillars standing in a corner whose sides here are open.
		for corner in 4:
			var dirs: Array = LevelLayout.CORNER_DIRS[corner]
			if walled[dirs[0]] or walled[dirs[1]]:
				continue
			var v := Vector2i(x + (1 if corner == 1 or corner == 2 else 0), z + (1 if corner >= 2 else 0))
			var p := pillar(v.x, v.y, sw)
			if p.is_empty() or p[0] < H - 0.01:
				continue
			var k := _corner_point(corner)
			var sx := 1.0 if k.x < C * 0.5 else -1.0
			var sz := 1.0 if k.y < C * 0.5 else -1.0
			var next: Array[PackedVector2Array] = []
			for poly in polys:
				var beyond_x := _clip(poly, Vector2(sx, 0), sx * k.x + e)
				var beyond_z := _clip(_clip(poly, Vector2(-sx, 0), -(sx * k.x + e)), Vector2(0, sz), sz * k.y + e)
				for q in [beyond_x, beyond_z]:
					if _area(q) > 0.0005:
						next.append(q)
			polys = next
	for corner in 4:
		if not L.has_chamfer(x, z, s_cell, corner):
			continue
		var k := _corner_point(corner)
		var m := (Vector2(C * 0.5, C * 0.5) - k).normalized()
		var dist := m.dot(k) + LevelLayout.CHAMFER_CUT / sqrt(2.0) + (e if sw >= 0 else 0.0)
		var next: Array[PackedVector2Array] = []
		for poly in polys:
			var q := _clip(poly, m, dist)
			if _area(q) > 0.0005:
				next.append(q)
		polys = next
	return polys


## The part of a convex polygon where n.p >= d.
static func _clip(poly: PackedVector2Array, n: Vector2, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var count := poly.size()
	for i in count:
		var a := poly[i]
		var b := poly[(i + 1) % count]
		var da := n.dot(a) - d
		var db := n.dot(b) - d
		if da >= -0.00001:
			out.append(a)
		if (da > 0.00001 and db < -0.00001) or (da < -0.00001 and db > 0.00001):
			out.append(a.lerp(b, da / (da - db)))
	return out


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return absf(a) * 0.5


## Emits slab pieces (cell-local) as prisms from top - thick to top.
func emit_slab(d: ChunkData, o: Vector3, polys: Array[PackedVector2Array], top: float, thick: float, mat: StringName,
		occlude: bool) -> void:
	for poly in polys:
		var w := PackedVector2Array()
		for p in poly:
			w.append(Vector2(o.x + p.x, o.z + p.y))
		d.geo.prism(w, o.y + top - thick, o.y + top, mat, surface_of(mat), occlude and _area(poly) > 4.0)


func _rects(r: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = [r]
	return out


func _floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName, flags: int) -> void:
	var thick := 0.5 if s == 0 else 0.3
	var rects := _rects(Rect2(0, 0, C, C))
	if flags & LevelLayout.STAIR_ABOVE:
		rects = subtract(rects[0], run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s)))
	if L.has_drop(x, z, s):
		var cut: Array[Rect2] = []
		for r in rects:
			cut.append_array(subtract(r, drop_rect(x, z, s)))
		rects = cut
		_drop_edge(d, x, z, s, o, thick)
	var f := level_feature(x, z, s)
	if not f.is_empty() and f["kind"] == &"pit":
		var cut: Array[Rect2] = []
		for r in rects:
			cut.append_array(subtract(r, f["rect"]))
		rects = cut
	emit_slab(d, o, slab_pieces(x, z, s - 1, rects, s), 0.0, thick, mat, s > 0)


func _catwalk(d: ChunkData, x: int, z: int, s: int, o: Vector3, flags: int) -> void:
	var sides := (flags >> 4) & 15
	var hole := Rect2()
	if flags & LevelLayout.STAIR_ABOVE:
		hole = run_rect(L.hole_dir(x, z, s), L.hole_side(x, z, s))
	for side in 4:
		if not (sides & (1 << side)):
			continue
		var holes: Array[Rect2] = [hole]
		for other in side:
			if sides & (1 << other):
				holes.append(strip(other, STRIP))
		emit_slab(d, o, slab_pieces(x, z, s - 1, subtract_all(strip(side, STRIP), holes), s), 0.0, 0.08, &"steel_grate", false)
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
	var holes: Array[Rect2] = []
	if axis == 1 and flags & LevelLayout.BRIDGE_X:
		holes.append(Rect2(0, w0, C, BRIDGE))  # the crossing is the X bridge's
	emit_slab(d, o, slab_pieces(x, z, s - 1, subtract_all(r, holes), s), 0.0, 0.08, &"steel_grate", false)
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
			var h := s * H - 0.08  # up to the underside of the deck
			d.geo.box(p + Vector3.DOWN * (0.08 + h * 0.5), Vector3(0.16, h, 0.16), &"painted_steel", &"metal")


func _broken_floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName) -> void:
	var r := rng(x, z, s, 4)
	# Jagged remains of the slab along a couple of edges.
	var done: Array[Rect2] = []
	for side in 4:
		if r.randf() < 0.55:
			var sr := strip(side, r.randf_range(0.6, 1.6))
			emit_slab(d, o, slab_pieces(x, z, s - 1, subtract_all(sr, done), s), 0.0, 0.3, mat, false)
			done.append(sr)
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
	# Walkable ramp collider along the step noses. Its surface runs 2 cm
	# above the line from foot to landing so it passes over the landing
	# slab's edge: a capsule meeting that corner even 1 cm proud of the slope
	# touches it at over 50 degrees, which counts as a wall.
	d.geo.box(mid - up * 0.04, Vector3(width, 0.12, length), &"", &"metal", false, basis)
	# Treads
	var steps := int(round(H / 0.19))
	for i in steps:
		var t0 := maxf(i * RUN / steps - 0.015, 0.0)
		var t1 := minf((i + 1) * RUN / steps + 0.015, RUN - 0.005)  # the last one stops short of the landing slab
		var p := bottom + a * ((t0 + t1) * 0.5) + Vector3.UP * ((i + 1) * H / steps - 0.025)
		d.geo.box(p, _oriented(a, Vector3(width, 0.05, t1 - t0)), &"steel_grate")
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
	d.geo.box(top + a * 0.05 + Vector3.DOWN * 0.165, _oriented(a, Vector3(width - 0.1, 0.3, 0.2)), &"painted_steel")


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
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.07, Vector3(0.012, 0.12, length), &"painted_steel", &"", false, basis)  # kick plate, off the floor
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.6, Vector3(0.08, 1.2, length), &"", &"metal", false, basis, Layers.CLIP)


func beam(g: GeoBuilder, p0: Vector3, p1: Vector3, section: Vector2, mat: StringName, collide: bool = false) -> void:
	var length := p0.distance_to(p1)
	if length < 0.05:
		return
	var dir := (p1 - p0) / length
	var basis := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD)
	g.box((p0 + p1) * 0.5, Vector3(section.x, section.y, length), mat, surface_of(mat) if collide else &"", false, basis)


# --- Walls ----------------------------------------------------------------------------
#
# A wall occupies a band T thick centred on the cell edge. Between two
# building cells each side builds its own half; an outer wall (onto open
# ground, a yard or a walkway) is built whole by the building, its inner
# half in the room's material and its outer half in the building's facade.
# Walls run between pillars at the grid vertices, so no two wall boxes
# overlap, and slabs stop at the walls below them (whose tops then make the
# floor there): no two faces ever share a plane, so nothing flickers.

## Open air for a building's walls: nothing built there, or a walkway or a
## yard (their sides are the building's outer walls).
func outdoor(x: int, z: int, s: int) -> bool:
	if not L.is_enclosed(x, z, s):
		return true
	var t := L.zone_of(x, z, s).type
	return t == &"connector" or t == &"yard"


func is_building(x: int, z: int, s: int) -> bool:
	return not outdoor(x, z, s)


## What this cell builds on its `dir` edge: 0 nothing, 1 its half of a wall
## shared with another building cell, 2 the whole wall.
func wall_kind(x: int, z: int, s: int, dir: int) -> int:
	if not L.is_enclosed(x, z, s):
		return 0
	var t := L.zone_of(x, z, s).type
	if t == &"connector":
		return 0
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	if t == &"yard":
		return 2 if not L.is_enclosed(n.x, n.y, s) else 0
	if outdoor(n.x, n.y, s):
		return 2
	return 1 if L.has_wall(x, z, s, dir) else 0


## Height of the wall this cell builds on `dir` (storey-local): the storey
## height, a parapet above the roofline, or a yard's boundary wall.
func wall_top(x: int, z: int, s: int, dir: int) -> float:
	if s < 0:
		return H - BURIED  # up to the underside of the ground floor / buried roof
	var zn := L.zone_of(x, z, s)
	if zn.type == &"yard":
		return YARD_WALL
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	if is_building(x, z, s + 1) or is_building(n.x, n.y, s + 1):
		return H
	if wall_kind(x, z, s, dir) == 1 and L.zone_at(n.x, n.y, s) == zn.id:
		return H  # partitions stop under the roof
	return H + PARAPET


## Top of the highest wall on an edge (either side), or -INF.
func edge_top(x: int, z: int, s: int, dir: int) -> float:
	var top := -INF
	if wall_kind(x, z, s, dir) > 0:
		top = wall_top(x, z, s, dir)
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	var back := (dir + 2) % 4
	if L.inside(n.x, n.y, s) and wall_kind(n.x, n.y, s, back) > 0:
		top = maxf(top, wall_top(n.x, n.y, s, back))
	return top


func facade_material(zn: LevelLayout.Zone) -> StringName:
	match zn.type:
		&"hall", &"foundry", &"maintenance":
			return &"brick"
		&"warehouse", &"loading_dock":
			return &"corrugated_metal" if zn.id % 3 != 0 else &"brick"
		&"office":
			return &"plaster" if zn.id % 2 == 0 else &"brick"
		&"yard":
			return zn.style.wall_material
	return &"concrete_wall"


## A frame of reference along one wall: `origin` on the edge line at the
## storey's floor, `u` along the wall, `m` into the cell.
class Span:
	var origin: Vector3
	var u: Vector3
	var m: Vector3
	var length: float

	func _init(p: Vector3, along: Vector3, inward: Vector3, len: float) -> void:
		origin = p
		u = along
		m = inward
		length = len


func edge_span(o: Vector3, dir: int) -> Span:
	match dir:
		0:
			return Span.new(o, Vector3(1, 0, 0), Vector3(0, 0, 1), C)
		1:
			return Span.new(o + Vector3(C, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), C)
		2:
			return Span.new(o + Vector3(0, 0, C), Vector3(1, 0, 0), Vector3(0, 0, -1), C)
	return Span.new(o, Vector3(0, 0, 1), Vector3(1, 0, 0), C)


## Box in a span: a0..a1 along it, y0..y1 high, `depth` thick, centred `off`
## metres in from the edge line.
func sbox(g: GeoBuilder, sp: Span, a0: float, a1: float, y0: float, y1: float, depth: float, off: float,
		mat: StringName, surface: StringName = &"", layer: int = 1, occlude: bool = false) -> void:
	if a1 - a0 < 0.005 or y1 - y0 < 0.005:
		return
	var c := sp.origin + sp.u * ((a0 + a1) * 0.5) + sp.m * off + Vector3.UP * ((y0 + y1) * 0.5)
	var basis := Basis(Vector3.UP.cross(sp.u), Vector3.UP, sp.u)
	g.box(c, Vector3(depth, y1 - y0, a1 - a0), mat, surface, occlude, basis, layer)


## Solid parts of a wall from a_lo to a_hi and y_lo to top, minus openings
## [a0, a1, y0, y1]. An opening starting at the floor cuts down to y_lo.
## Returns Rect2s (x = along, y = height).
static func wall_solids(a_lo: float, a_hi: float, y_lo: float, top: float, openings: Array) -> Array[Rect2]:
	var cuts: Array = [a_lo, a_hi]
	for op in openings:
		cuts.append(clampf(op[0], a_lo, a_hi))
		cuts.append(clampf(op[1], a_lo, a_hi))
	cuts.sort()
	var out: Array[Rect2] = []
	for i in cuts.size() - 1:
		var a0: float = cuts[i]
		var a1: float = cuts[i + 1]
		if a1 - a0 < 0.005:
			continue
		var mid := (a0 + a1) * 0.5
		var solids: Array[Vector2] = [Vector2(y_lo, top)]
		for op in openings:
			if mid <= op[0] or mid >= op[1]:
				continue
			var o0: float = y_lo if op[2] <= 0.001 else op[2]
			var o1: float = op[3]
			var next: Array[Vector2] = []
			for sp in solids:
				if o1 <= sp.x or o0 >= sp.y:
					next.append(sp)
					continue
				if o0 > sp.x:
					next.append(Vector2(sp.x, o0))
				if o1 < sp.y:
					next.append(Vector2(o1, sp.y))
			solids = next
		for sp in solids:
			if sp.y - sp.x > 0.005:
				out.append(Rect2(a0, sp.x, a1 - a0, sp.y - sp.x))
	return out


## A wall in a span with openings: `bands` are [offset, depth, material].
func wall_run(g: GeoBuilder, sp: Span, a_lo: float, a_hi: float, y_lo: float, top: float, openings: Array,
		bands: Array) -> void:
	for r in wall_solids(a_lo, a_hi, y_lo, top, openings):
		for b in bands:
			var mat: StringName = b[2]
			sbox(g, sp, r.position.x, r.end.x, r.position.y, r.end.y, b[1], b[0], mat, surface_of(mat), 1,
				r.size.x > 2.0 and r.size.y > 2.0)


func _wall(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, mat: StringName, st: ZoneStyle,
		zn: LevelLayout.Zone, full: bool) -> void:
	var kind := wall_kind(x, z, s, dir)
	if kind == 0:
		return
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	var sp := edge_span(o, dir)
	var y_lo := -FOUNDATION if s == 0 else 0.0
	var top := wall_top(x, z, s, dir)
	var a_lo := T * 0.5
	var a_hi := C - T * 0.5
	if L.chamfer_at(x, z, s, dir, false) >= 0:
		a_lo = LevelLayout.CHAMFER_CUT + T * 0.5
	if L.chamfer_at(x, z, s, dir, true) >= 0:
		a_hi = C - LevelLayout.CHAMFER_CUT - T * 0.5
	if zn.type == &"yard":
		_yard_wall(d, x, z, s, sp, a_lo, a_hi, y_lo, mat)
		return
	var bands: Array = [[T * 0.25, T * 0.5, mat]]
	if kind == 2:
		bands.append([-T * 0.25, T * 0.5, facade_material(zn)])
	var openings: Array = []
	if L.has_door(x, z, s, dir):
		var span := door_span(x, z, s, dir)
		openings.append([span.x, span.y, 0.0, door_height(x, z, s, n, st)])
		if kind == 2 or L.idx(x, z, s) < L.idx(n.x, n.y, s):
			_door_frame(d, x, z, s, o, dir, openings.back())
	elif L.has_window(x, z, s, dir):
		if kind == 1:
			openings.append([1.2, C - 1.2, 1.05, 2.45])
			if L.idx(x, z, s) < L.idx(n.x, n.y, s):
				_interior_window(d, x, z, s, o, dir)
		elif zn.type in TALL:
			openings = _tall_window(d, x, z, s, sp, a_lo, a_hi, top, func(ss: int) -> bool: return L.has_window(x, z, ss, dir),
				hash([x, z, dir]), full)
		else:
			openings = _room_window(d, x, z, s, sp, a_lo, a_hi, st, full)
	elif kind == 2 and s == 0 and L.has_flag(x, z, s, LevelLayout.DOCK) and not L.is_enclosed(n.x, n.y, s):
		openings.append([1.2, C - 1.2, 0.0, 3.8])
		_shutter(d, x, z, s, o, dir)
	if L.has_gap(x, z, s, dir):
		openings.append_array(gap_openings(x, z, s, dir))
		_gap_dressing(d, x, z, s, sp, dir, mat)
	wall_run(d.geo, sp, a_lo, a_hi, y_lo, top, openings, bands)


# --- Breaches and vents ---------------------------------------------------------------------

const VENT_W := 1.0
const VENT_H := 1.25  # the crouching player fits, nobody standing does

## Random numbers shared by both sides of an edge.
func edge_rng(x: int, z: int, s: int, dir: int, purpose: int) -> RandomNumberGenerator:
	if dir == 0 or dir == 3:
		var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
		return rng(n.x, n.y, s, purpose * 4 + (dir + 2) % 4)
	return rng(x, z, s, purpose * 4 + dir)


func _narrow_either(x: int, z: int, s: int, dir: int) -> bool:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	return L.has_flag(x, z, s, LevelLayout.NARROW) or L.has_flag(n.x, n.y, s, LevelLayout.NARROW)


## The main opening of a breach or vent: Vector3(start, end, height) along the wall.
func gap_span(x: int, z: int, s: int, dir: int) -> Vector3:
	var r := edge_rng(x, z, s, dir, 31)
	var narrow := _narrow_either(x, z, s, dir)
	if L.has_vent(x, z, s, dir):
		var c := C * 0.5 if narrow else r.randf_range(1.8, C - 1.8)
		return Vector3(c - VENT_W * 0.5, c + VENT_W * 0.5, VENT_H)
	var w := r.randf_range(1.3, 1.9)
	if narrow:
		var pw := 99.0
		for c: Vector2i in [Vector2i(x, z), Vector2i(x, z) + LevelLayout.DIRS[dir]]:
			if L.has_flag(c.x, c.y, s, LevelLayout.NARROW):
				pw = minf(pw, L.style_at(c.x, c.y, s).passage_width)
		w = minf(w, pw - 0.4)
	var mid := C * 0.5 if narrow else r.randf_range(2.3, C - 2.3)
	return Vector3(mid - w * 0.5, mid + w * 0.5, r.randf_range(2.05, 2.6))


## Openings for a breach (a ragged hole: the main opening plus bites out of
## its top and sides) or a vent.
func gap_openings(x: int, z: int, s: int, dir: int) -> Array:
	var g := gap_span(x, z, s, dir)
	var out: Array = [[g.x, g.y, 0.0, g.z]]
	if L.has_vent(x, z, s, dir):
		return out
	var r := edge_rng(x, z, s, dir, 32)
	var w := g.y - g.x
	for i in r.randi_range(2, 3):
		var a := g.x + r.randf_range(0.0, w - 0.3)
		out.append([a, minf(a + r.randf_range(0.25, 0.6), g.y), g.z - 0.01, g.z + r.randf_range(0.15, 0.55)])
	for e in 2:
		if r.randf() < 0.7:
			var y0 := r.randf_range(0.2, 1.2)
			var bite := r.randf_range(0.15, 0.4)
			if e == 0:
				out.append([maxf(g.x - bite, 0.4), g.x + 0.01, y0, y0 + r.randf_range(0.3, 0.9)])
			else:
				out.append([g.y - 0.01, minf(g.y + bite, C - 0.4), y0, y0 + r.randf_range(0.3, 0.9)])
	return out


## This cell's side of a breach (rubble, rebar) or vent (a duct housing
## standing out from the wall, its grille knocked off).
func _gap_dressing(d: ChunkData, x: int, z: int, s: int, sp: Span, dir: int, mat: StringName) -> void:
	var g := gap_span(x, z, s, dir)
	var r := rng(x, z, s, 33 + dir)
	var geo := d.geo
	var mid := (g.x + g.y) * 0.5
	if L.has_vent(x, z, s, dir):
		if L.has_flag(x, z, s, LevelLayout.NARROW):
			return  # the crawl tunnel through the fill is the duct here
		var out := 0.55
		var off := T * 0.5 + out * 0.5
		sbox(geo, sp, g.x - 0.08, g.y + 0.08, VENT_H, VENT_H + 0.08, out, off, &"painted_steel", &"metal")
		for e: float in [g.x - 0.08, g.y]:
			sbox(geo, sp, e, e + 0.08, 0.0, VENT_H, out, off, &"painted_steel", &"metal")
		sbox(geo, sp, g.x - 0.12, g.y + 0.12, VENT_H + 0.08, VENT_H + 0.14, out + 0.04, off + 0.02, &"rusted_metal")  # lip
		var p := sp.origin + sp.u * mid + sp.m * (T * 0.5 + out + 0.6)
		if r.randf() < 0.6:
			geo.box(p + Vector3.UP * 0.02, Vector3(VENT_W, 0.03, 1.1), &"steel_grate", &"", false,
				Basis(Vector3.UP, r.randf_range(-0.6, 0.6)) * Basis(Vector3.RIGHT, 0.05))
		else:
			var hinge := sp.origin + sp.u * g.x + sp.m * (T * 0.5 + out + 0.03) + Vector3.UP * VENT_H
			geo.box(hinge + sp.u * (VENT_W * 0.5) + Vector3.DOWN * (VENT_H * 0.5) + sp.m * 0.25,
				Vector3(0.02, VENT_H, VENT_W) if absf(sp.u.z) > 0.5 else Vector3(VENT_W, VENT_H, 0.02), &"steel_grate", &"", false,
				Basis(sp.u, -1.15))
		return
	# Breach: broken masonry heaped at the foot, rebar poking out of the edge.
	for i in r.randi_range(4, 8):
		var p := sp.origin + sp.u * r.randf_range(g.x - 0.3, g.y + 0.3) + sp.m * r.randf_range(T * 0.5 + 0.1, 1.3)
		var size := Vector3(r.randf_range(0.12, 0.45), r.randf_range(0.08, 0.22), r.randf_range(0.1, 0.35))
		geo.box(p + Vector3.UP * size.y * 0.35, size, mat if r.randf() < 0.6 else &"concrete_dark", &"", false,
			Basis.from_euler(Vector3(r.randf_range(-0.5, 0.5), r.randf() * TAU, r.randf_range(-0.5, 0.5))))
	for i in r.randi_range(2, 5):
		var a := r.randf_range(g.x + 0.1, g.y - 0.1)
		var p := sp.origin + sp.u * a + Vector3.UP * (g.z + 0.05) + sp.m * r.randf_range(-0.1, 0.1)
		geo.cylinder(p, p + Vector3.DOWN * r.randf_range(0.2, 0.6) + sp.m * r.randf_range(-0.3, 0.3) + sp.u * r.randf_range(-0.2, 0.2),
			0.012, &"rusted_metal", 4)
	d.decals.append(["crack", Transform3D(Basis(sp.m.cross(Vector3.UP), sp.m, sp.m.cross(Vector3.UP).cross(sp.m)).orthonormalized(),
		sp.origin + sp.u * mid + sp.m * (T * 0.5) + Vector3.UP * (g.z * 0.6)), Vector3(g.y - g.x + 1.6, 0.4, g.z + 1.2)])


## Door opening along the wall (centred, pushed clear of a chamfered end).
func door_span(x: int, z: int, s: int, dir: int) -> Vector2:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	var w := door_width(x, z, s, n, L.style_at(x, z, s))
	var mid := C * 0.5
	if L.chamfer_at(x, z, s, dir, false) >= 0:
		mid = maxf(mid, LevelLayout.CHAMFER_CUT + 0.6 + w * 0.5)
	if L.chamfer_at(x, z, s, dir, true) >= 0:
		mid = minf(mid, C - LevelLayout.CHAMFER_CUT - 0.6 - w * 0.5)
	return Vector2(mid - w * 0.5, mid + w * 0.5)


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


## Axis-aligned box against the wall on `dir` (cell-local "along" a0..a1,
## storey-local heights), `inset` metres in from the edge line. Set pieces use
## it for skirting, bands and vents.
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


## Steel door frame round an opening. Jambs and head overlap the cut ends of
## the wall (never flush with them) and each other at different depths.
func _door_frame(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, op: Array) -> void:
	var a0: float = op[0]
	var a1: float = op[1]
	var h: float = op[3]
	var g := d.geo
	wall_box(g, o, dir, a0 - 0.06, a0 + 0.04, 0.0, h + 0.04, &"rusted_metal", false, T + 0.06)
	wall_box(g, o, dir, a1 - 0.04, a1 + 0.06, 0.0, h + 0.04, &"rusted_metal", false, T + 0.06)
	wall_box(g, o, dir, a0 - 0.08, a1 + 0.08, h - 0.04, h + 0.1, &"rusted_metal", false, T + 0.08)
	# Narrow doors keep a leaf: hanging open, half off its hinges, or flat on the floor.
	var w := a1 - a0
	if w > 1.6:
		return
	var r := rng(x, z, s, 20 + dir)
	var roll := r.randf()
	if roll < 0.35:
		return
	var hinge_a := a0 + 0.04 if r.randf() < 0.5 else a1 - 0.04
	var inward := -LevelLayout.dir_vector(dir)
	if r.randf() < 0.5:
		inward = -inward  # opens into the neighbour
	var along := LevelLayout.dir_vector((dir + 1) % 4)
	var edge := o + Vector3(C * 0.5, 0, C * 0.5) + LevelLayout.dir_vector(dir) * (C * 0.5)
	var hinge := edge + along * (hinge_a - C * 0.5) + inward * 0.2
	var toward := along * (1.0 if hinge_a < C * 0.5 else -1.0)
	var mat: StringName = [&"painted_steel_blue", &"painted_steel", &"wood_planks", &"painted_steel_green"][r.randi_range(0, 3)]
	if roll < 0.85:
		# Swung open, resting against the wall at 75-105 degrees.
		var ang := deg_to_rad(r.randf_range(75.0, 105.0))
		var leaf_dir := (toward * cos(ang) + inward * sin(ang)).normalized()
		var basis := Basis.looking_at(leaf_dir, Vector3.UP)
		var sag := r.randf_range(0.0, 0.06) if roll > 0.7 else 0.0
		g.box(hinge + leaf_dir * (w * 0.5 - 0.04) + Vector3.UP * (h * 0.5 - 0.02 - sag), Vector3(0.05, h - 0.08, w - 0.12), mat, &"", false,
			basis * Basis(Vector3.FORWARD, sag * 2.0))
	else:
		# Torn off, lying in the room.
		var p := edge + inward * r.randf_range(1.2, 1.8) + along * r.randf_range(-0.8, 0.8)
		var basis := Basis(Vector3.UP, r.randf() * TAU) * Basis(Vector3.RIGHT, r.randf_range(-0.12, 0.12))
		g.box(p + Vector3.UP * 0.04, Vector3(w - 0.04, 0.05, h - 0.06), mat, &"", false, basis)


## Glazed partition between two interior spaces: frame, mullions, some glass.
func _interior_window(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int) -> void:
	var g := d.geo
	var r := rng(x, z, s, 30 + dir)
	var a0 := 1.2
	var a1 := C - 1.2
	wall_box(g, o, dir, a0 - 0.06, a1 + 0.06, 0.98, 1.08, &"painted_steel", false, T + 0.12)  # sill
	wall_box(g, o, dir, a0 - 0.06, a1 + 0.06, 2.42, 2.52, &"painted_steel", false, T + 0.04)  # head
	var panes := 4
	var pw := (a1 - a0) / panes
	for i in panes + 1:
		var a := a0 + i * pw
		wall_box(g, o, dir, a - 0.04, a + 0.04, 1.08, 2.42, &"painted_steel", false, 0.08)
	for i in panes:
		var roll := r.randf()
		if roll < 0.4:
			wall_box(g, o, dir, a0 + i * pw + 0.04, a0 + (i + 1) * pw - 0.04, 1.08, 2.42, &"glass_dirty", false, 0.02)
		elif roll < 0.6:
			# Shards left in the bottom of the frame.
			wall_box(g, o, dir, a0 + i * pw + 0.04, a0 + (i + 1) * pw - 0.04, 1.08, 1.08 + r.randf_range(0.1, 0.4), &"glass_dirty", false, 0.02)
	# Blocks walking through, not bullets.
	wall_box(g, o, dir, a0, a1, 1.05, 2.45, &"", true, 0.1, 0.0, Layers.CLIP)


## Industrial steel window: mullions, transoms, what's left of the panes and
## a collider that stops walking (not bullets). y0..y1 is this storey's part.
func _glazing(g: GeoBuilder, sp: Span, a0: float, a1: float, y0: float, y1: float, r: RandomNumberGenerator,
		cols: int, row_h: float, base_y: float, arch: Callable = Callable()) -> void:
	var w := a1 - a0
	var tops: Array[float] = []
	for i in cols + 1:
		var a := a0 + w * i / cols
		var m0 := a - 0.03 if i > 0 else a
		var m1 := a + 0.03 if i < cols else a
		var mt := y1
		if arch.is_valid():
			mt = minf(y1, arch.call(clampf(a, a0 + 0.05, a1 - 0.05)) + 0.05)
		tops.append(mt)
		sbox(g, sp, m0, m1, y0, mt, 0.09, 0.0, &"rusted_metal")
	var k0 := ceili((y0 - base_y) / row_h + 0.001)
	var rows: Array[float] = [y0]
	var k := k0
	while base_y + k * row_h < y1 - 0.15:
		var y := base_y + k * row_h
		if not arch.is_valid() or y < arch.call(a0 + 0.05) - 0.1:
			sbox(g, sp, a0, a1, y - 0.03, y + 0.03, 0.07, 0.0, &"rusted_metal")
			rows.append(y)
		k += 1
	rows.append(y1)
	for i in cols:
		var p0 := a0 + w * i / cols + 0.03
		var p1 := a0 + w * (i + 1) / cols - 0.03
		for j in rows.size() - 1:
			var q0 := rows[j] + (0.03 if j > 0 else 0.0)
			var q1 := rows[j + 1] - (0.03 if j < rows.size() - 2 else 0.0)
			if arch.is_valid() and j == rows.size() - 2:
				q1 = minf(q1, minf(tops[i], tops[i + 1]) - 0.05)
			if q1 - q0 < 0.1:
				continue
			var roll := r.randf()
			if roll < 0.4:
				sbox(g, sp, p0, p1, q0, q1, 0.012, 0.0, &"glass_dirty")
			elif roll < 0.55:
				sbox(g, sp, p0, p1, q0, q0 + (q1 - q0) * r.randf_range(0.15, 0.45), 0.012, 0.0, &"glass_dirty")
	sbox(g, sp, a0, a1, y0, y1, 0.1, 0.0, &"", &"metal", Layers.CLIP)


## Tall arched window through every storey of a hall's outer wall that has
## the window flag (`has(storey)`), with daylight falling in at the bottom.
## Returns this storey's openings.
func _tall_window(d: ChunkData, x: int, z: int, s: int, sp: Span, a_lo: float, a_hi: float, top: float,
		has: Callable, key: int, full: bool) -> Array:
	var sb := s
	while sb > 0 and has.call(sb - 1):
		sb -= 1
	var se := s
	while se + 1 < L.storeys and has.call(se + 1):
		se += 1
	var w := minf(3.6, a_hi - a_lo - 1.4)
	if w < 1.0:
		return []
	var mid := (a_lo + a_hi) * 0.5
	var a0 := mid - w * 0.5
	var a1 := mid + w * 0.5
	var base := s * H
	var sill := sb * H + 1.2 - base
	var head := (se + 1) * H - 1.0 - base
	var rise := minf(0.8, w * 0.22)
	# A band of wall at each floor line between storeys of the window, which
	# the catwalk or floor inside rests against.
	var y0 := sill if s == sb else 0.0
	var y1 := head if s == se else top - 0.45
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, key, s, 11])
	var arch := Callable()
	if s == se:
		# Segmental arch: brick fills the top corners in slices.
		arch = func(a: float) -> float:
			var t := (a - a0) / w * 2.0 - 1.0
			return head - rise * t * t
		var slices := 12
		for i in slices:
			var s0 := a0 + w * i / slices
			var s1 := a0 + w * (i + 1) / slices
			var yc: float = arch.call((s0 + s1) * 0.5)
			sbox(d.geo, sp, s0, s1, yc, head, T, 0.0, &"brick", &"concrete")
		# Brick sill outside, lintel band inside.
	if s == sb:
		sbox(d.geo, sp, a0 - 0.1, a1 + 0.1, y0 - 0.08, y0 + 0.03, T + 0.12, -0.03, &"concrete_dark")
	_glazing(d.geo, sp, a0, a1, y0, y1, r, 3, 1.05, sill + base - s * H, arch)
	if full and s == sb and r.randf() < 0.5:
		_daylight(d, sp, (a0 + a1) * 0.5, y0, 3.2, r.randf() < 0.3)
	return [[a0, a1, y0, y1]]


## Windows in the outer wall of a room: one or two per cell edge (one in the
## end wall of a cramped passage).
func _room_window(d: ChunkData, x: int, z: int, s: int, sp: Span, a_lo: float, a_hi: float, st: ZoneStyle,
		full: bool) -> Array:
	var y0 := 1.0
	var y1 := 2.45
	var spans: Array[Vector2] = []
	var span := a_hi - a_lo
	if L.has_flag(x, z, s, LevelLayout.NARROW):
		var w := minf(st.passage_width - 0.6, 1.6)
		spans.append(Vector2(C * 0.5 - w * 0.5, C * 0.5 + w * 0.5))
	elif span >= 5.0:
		for f: float in [0.27, 0.73]:
			var c := a_lo + span * f
			spans.append(Vector2(c - 1.0, c + 1.0))
	elif span >= 2.4:
		var w := minf(2.0, span - 1.2)
		var c := (a_lo + a_hi) * 0.5
		spans.append(Vector2(c - w * 0.5, c + w * 0.5))
	var r := rng(x, z, s, 90 + int(sp.u.x * 3.0 + sp.m.z * 5.0 + sp.m.x * 7.0))
	var out: Array = []
	for v in spans:
		sbox(d.geo, sp, v.x - 0.06, v.y + 0.06, y0 - 0.06, y0 + 0.03, T + 0.1, 0.0, &"concrete_dark")  # sill
		sbox(d.geo, sp, v.x - 0.1, v.y + 0.1, y1 - 0.03, y1 + 0.12, T + 0.04, 0.0, &"concrete_dark")  # lintel
		_glazing(d.geo, sp, v.x, v.y, y0 + 0.03, y1 - 0.03, r, 2, 0.9, y0 + 0.03)
		out.append([v.x, v.y, y0, y1])
	if full and not spans.is_empty() and r.randf() < 0.3:
		_daylight(d, sp, (spans[0].x + spans[spans.size() - 1].y) * 0.5, y0, 1.8, false)
	return out


## Overcast daylight through a window: a soft spot from outside aimed at the
## floor inside.
func _daylight(d: ChunkData, sp: Span, along: float, sill: float, energy: float, shadow: bool) -> void:
	var p := sp.origin + sp.u * along
	d.lights.append({"type": "spot", "position": p - sp.m * 4.0 + Vector3.UP * (sill + 3.2),
		"target": p + sp.m * 4.5, "color": Color(0.78, 0.83, 0.9), "energy": energy, "range": 16.0,
		"angle": 48.0, "shadow": shadow, "fog": 2.0})


func _shutter(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int) -> void:
	var r := rng(x, z, s, 40 + dir)
	var open := r.randf()
	var bottom := 0.0
	if open < 0.3:
		bottom = r.randf_range(0.5, 1.4)  # jammed half open, light spills under it
	wall_box(d.geo, o, dir, 1.2, C - 1.2, bottom, 3.78, &"corrugated_metal", bottom < 0.4, 0.06, -0.21)
	wall_box(d.geo, o, dir, 1.0, C - 1.0, 3.72, 4.3, &"rusted_metal", true, 0.53, -0.085)  # head, proud of the wall inside
	for a: float in [1.23, C - 1.23]:
		wall_box(d.geo, o, dir, a - 0.13, a + 0.13, 0.0, 3.72, &"painted_steel_yellow", true, 0.2, -0.12)  # guides, over the jambs
	if bottom > 0.0:
		wall_box(d.geo, o, dir, 1.2, C - 1.2, 0.0, bottom, &"", true, 0.1, -0.21)  # nothing crawls out
		var out := LevelLayout.dir_vector(dir)
		var c := o + Vector3(C * 0.5, bottom, C * 0.5) + out * (C * 0.5 + 2.5)
		d.lights.append({"type": "spot", "position": c + Vector3.UP * 0.4, "target": c - out * 6.0,
			"color": Color(0.75, 0.8, 0.88), "energy": 5.0, "range": 12.0, "angle": 40.0, "shadow": true, "fog": 2.0})


## A yard's boundary wall: brick with a coping, broken down in places, or a
## chain-link fence on a kerb. Never lower than YARD_WALL for walking.
func _yard_wall(d: ChunkData, x: int, z: int, s: int, sp: Span, a_lo: float, a_hi: float, y_lo: float,
		mat: StringName) -> void:
	var g := d.geo
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, sp.origin, 81])
	var roll := r.randf()
	if roll < 0.2:
		sbox(g, sp, a_lo, a_hi, y_lo, 0.45, T, 0.0, &"concrete_dark", &"concrete")
		var posts := maxi(int(ceil((a_hi - a_lo) / 2.6)), 1)
		for i in posts + 1:
			var a := lerpf(a_lo + 0.05, a_hi - 0.05, float(i) / posts)
			sbox(g, sp, a - 0.04, a + 0.04, 0.45, 3.05, 0.08, 0.0, &"gun_metal", &"metal")
		sbox(g, sp, a_lo, a_hi, 0.5, 2.95, 0.015, 0.0, &"steel_grate")
		g.cylinder(sp.origin + sp.u * a_lo + Vector3.UP * 3.0, sp.origin + sp.u * a_hi + Vector3.UP * 3.0, 0.02, &"rusted_metal", 4)
		sbox(g, sp, a_lo, a_hi, 0.45, YARD_WALL, 0.1, 0.0, &"", &"metal", Layers.CLIP)
		return
	var bands: Array = [[0.0, T, mat]]
	if roll < 0.45:
		# Collapsed in steps; rubble at its foot.
		var n := 5
		for i in n:
			var s0 := lerpf(a_lo, a_hi, float(i) / n)
			var s1 := lerpf(a_lo, a_hi, float(i + 1) / n)
			var h := YARD_WALL if i == 0 or i == n - 1 else r.randf_range(1.1, YARD_WALL - 0.4)
			wall_run(g, sp, s0, s1, y_lo, h, [], bands)
		sbox(g, sp, a_lo, a_hi, 0.0, YARD_WALL, 0.1, 0.0, &"", &"concrete", Layers.CLIP)
		for i in 4:
			var p := sp.origin + sp.u * r.randf_range(a_lo + 0.8, a_hi - 0.8) + sp.m * r.randf_range(0.4, 1.2)
			var basis := Basis.from_euler(Vector3(r.randf_range(-0.4, 0.4), r.randf() * TAU, r.randf_range(-0.4, 0.4)))
			g.box(p + Vector3.UP * 0.12, Vector3(r.randf_range(0.3, 0.6), 0.22, r.randf_range(0.2, 0.4)), mat, &"", false, basis)
		return
	wall_run(g, sp, a_lo, a_hi, y_lo, YARD_WALL, [], bands)
	sbox(g, sp, a_lo, a_hi, YARD_WALL, YARD_WALL + 0.08, T + 0.08, 0.0, &"concrete_dark")


# --- Pillars, stubs, cut corners ----------------------------------------------------------

## The pillar at grid vertex (vx, vz) on storey s: [top, half size] or [] for
## none. Pillars stand wherever walls meet or end; tall halls get brick piers.
## Cell-local rect of a drop-down's hole (its corner of the cell).
func drop_rect(x: int, z: int, s: int) -> Rect2:
	const SIZE := 2.3
	const INSET := 0.45
	var k := _corner_point(L.drop_corner(x, z, s))
	var x0 := INSET if k.x < C * 0.5 else C - INSET - SIZE
	var z0 := INSET if k.y < C * 0.5 else C - INSET - SIZE
	return Rect2(x0, z0, SIZE, SIZE)


## The broken edge of a drop-down: chunks of slab along the rim, bent rebar
## reaching into the hole, a piece hanging down; below, the heap it made.
func _drop_edge(d: ChunkData, x: int, z: int, s: int, o: Vector3, thick: float) -> void:
	var r := rng(x, z, s, 160)
	var h := drop_rect(x, z, s)
	var g := d.geo
	var edges := [[Vector2(h.position.x, h.position.y), Vector2(h.end.x, h.position.y)],
		[Vector2(h.end.x, h.position.y), Vector2(h.end.x, h.end.y)],
		[Vector2(h.end.x, h.end.y), Vector2(h.position.x, h.end.y)],
		[Vector2(h.position.x, h.end.y), Vector2(h.position.x, h.position.y)]]
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var t := 0.12
		while t < 0.95:
			var p := a.lerp(b, t)
			var inward := (h.get_center() - p).normalized() * 0.08
			var sz := Vector3(r.randf_range(0.18, 0.4), r.randf_range(0.1, 0.22), r.randf_range(0.15, 0.3))
			g.box(o + Vector3(p.x - inward.x, -thick * 0.5, p.y - inward.y), sz, &"concrete_dark", &"", false,
				Basis.from_euler(Vector3(r.randf_range(-0.5, 0.5), r.randf() * TAU, r.randf_range(-0.5, 0.5))))
			if r.randf() < 0.45:
				var bar := Vector3(p.x, -thick * 0.6, p.y)
				var into := Vector3(h.get_center().x - p.x, 0, h.get_center().y - p.y).normalized()
				var tip := bar + into * r.randf_range(0.3, 0.7) + Vector3.DOWN * r.randf_range(0.0, 0.5)
				g.cylinder(o + bar, o + tip, 0.012, &"rusted_metal", 4)
			t += r.randf_range(0.18, 0.32)
	# A slab fragment still hanging by its bars.
	var c := h.get_center()
	g.box(o + Vector3(c.x + r.randf_range(-0.4, 0.4), -thick - 0.9, c.y + r.randf_range(-0.4, 0.4)), Vector3(1.0, 0.18, 0.8),
		&"concrete_dark", &"", false, Basis.from_euler(Vector3(r.randf_range(0.9, 1.3), r.randf() * TAU, 0.0)))


func pillar(vx: int, vz: int, s: int) -> Array:
	var cells: Array[Vector2i] = [Vector2i(vx - 1, vz - 1), Vector2i(vx, vz - 1), Vector2i(vx, vz), Vector2i(vx - 1, vz)]
	const CORNER_OF := [2, 3, 0, 1]
	const ARM_DIR := [1, 2, 3, 0]
	for i in 4:
		if L.has_chamfer(cells[i].x, cells[i].y, s, CORNER_OF[i]):
			return []
	var top := -INF
	var pier := -1
	for i in 4:
		var c := cells[i]
		var dir: int = ARM_DIR[i]
		var n := c + LevelLayout.DIRS[dir]
		for side: Array in [[c, dir], [n, (dir + 2) % 4]]:
			var p: Vector2i = side[0]
			var dd: int = side[1]
			var kind := wall_kind(p.x, p.y, s, dd)
			if kind == 0:
				continue
			top = maxf(top, wall_top(p.x, p.y, s, dd))
			var zn := L.zone_of(p.x, p.y, s)
			if kind == 2 and zn.type in [&"hall", &"foundry", &"warehouse"]:
				pier = zn.id
	if top == -INF:
		return []
	# A parapet's pillar stops at the storey top when the pillar above
	# carries on from there (they would overlap).
	if top > H + 0.01 and s + 1 < L.storeys and not pillar(vx, vz, s + 1).is_empty():
		top = H
	if pier >= 0:
		for c in cells:
			if is_building(c.x, c.y, s) and L.zone_at(c.x, c.y, s) != pier:
				pier = -1
				break
	return [top, 0.28 if pier >= 0 else T * 0.5]


## Builds the pillars this cell owns (the first built cell round a vertex).
func _pillars(d: ChunkData, x: int, z: int, s: int, mat: StringName) -> void:
	for corner in 4:
		var v := Vector2i(x + (1 if corner == 1 or corner == 2 else 0), z + (1 if corner >= 2 else 0))
		var owner := -1
		for c: Vector2i in [Vector2i(v.x - 1, v.y - 1), Vector2i(v.x, v.y - 1), Vector2i(v.x - 1, v.y), Vector2i(v.x, v.y)]:
			if L.is_enclosed(c.x, c.y, s) and L.zone_of(c.x, c.y, s).type != &"connector":
				owner = c.x + c.y * L.size.x
				break  # cells are listed in index order
		if owner != x + z * L.size.x:
			continue
		var p := pillar(v.x, v.y, s)
		if p.is_empty():
			continue
		var top: float = p[0]
		var half: float = p[1]
		var y0 := -FOUNDATION if s == 0 else 0.0
		var c := Vector3(v.x * C, s * H + (y0 + top) * 0.5, v.y * C)
		if half > T * 0.5:
			# Above the roofline the pier stands proud of the parapet it overlaps.
			var cap := 0.06 if top > H + 0.01 else 0.0
			d.geo.box(c + Vector3.UP * (cap * 0.5), Vector3(half * 2.0, top + cap - y0, half * 2.0), &"brick", &"concrete", false)
			continue
		# A quarter per cell round the vertex, so it matches the walls it joins:
		# the room's material inside, the facade outside.
		var cells: Array[Vector2i] = [Vector2i(v.x - 1, v.y - 1), Vector2i(v.x, v.y - 1), Vector2i(v.x, v.y), Vector2i(v.x - 1, v.y)]
		var facade := &""
		for q in cells:
			if is_building(q.x, q.y, s):
				for dir in 4:
					if wall_kind(q.x, q.y, s, dir) == 2:
						facade = facade_material(L.zone_of(q.x, q.y, s))
						break
			if facade != &"":
				break
		for i in 4:
			var q := cells[i]
			var m := mat
			if is_building(q.x, q.y, s):
				m = wall_material(L.zone_of(q.x, q.y, s).style, s, L.room_of(q.x, q.y, s))
			elif facade != &"":
				m = facade
			elif L.is_enclosed(q.x, q.y, s) and L.zone_of(q.x, q.y, s).type == &"yard":
				m = L.zone_of(q.x, q.y, s).style.wall_material
			var off := Vector3((0.5 if i == 1 or i == 2 else -0.5) * half, 0, (0.5 if i >= 2 else -0.5) * half)
			d.geo.box(c + off, Vector3(half, top - y0, half), m, surface_of(m), false)


## Stubs of wall partly dividing a room (built by the cell on the west or
## north side of the edge).
func _partials(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName) -> void:
	for dir in [1, 2]:
		if not L.has_partial(x, z, s, dir):
			continue
		var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
		if L.kind_at(x, z, s) != LevelLayout.Kind.FLOOR or L.kind_at(n.x, n.y, s) != LevelLayout.Kind.FLOOR:
			continue
		var r := rng(x, z, s, 60 + dir)
		var length := r.randf_range(2.4, 4.4)
		var a0 := T * 0.5
		if r.randf() < 0.5:
			a0 = C - T * 0.5 - length
		var a1 := a0 + length
		var top := H - 0.3 if slab_over(x, z, s) and slab_over(n.x, n.y, s) else 3.0
		var y0 := -FOUNDATION if s == 0 else 0.0
		var sp := edge_span(o, dir)
		var free_end := a1 if a0 < C * 0.5 else a0
		var s0 := a0 if a0 < C * 0.5 else a0 + 0.2
		var s1 := a1 - 0.2 if a0 < C * 0.5 else a1
		wall_run(d.geo, sp, s0, s1, y0, top, [], [[0.0, T, mat]])
		# A squat concrete pier finishes the free end.
		sbox(d.geo, sp, free_end - 0.2, free_end + 0.2, y0, top, 0.42, 0.0, &"concrete_dark", &"concrete")


## Corners of the cell cut at 45 degrees: a diagonal wall (with a window if
## the walls beside it have them) and posts where it meets the straight walls.
func _chamfers(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName, zn: LevelLayout.Zone,
		full: bool) -> void:
	for corner in 4:
		if not L.has_chamfer(x, z, s, corner):
			continue
		var dirs: Array = LevelLayout.CORNER_DIRS[corner]
		var k := _corner_point(corner)
		var sx := 1.0 if k.x < C * 0.5 else -1.0
		var sz := 1.0 if k.y < C * 0.5 else -1.0
		var cut := LevelLayout.CHAMFER_CUT
		var p1 := k + Vector2(cut * sx, 0.0)
		var p2 := k + Vector2(0.0, cut * sz)
		var w1 := o + Vector3(p1.x, 0, p1.y)
		var w2 := o + Vector3(p2.x, 0, p2.y)
		var u := (w2 - w1).normalized()
		var inward := Vector3(sx, 0, sz).normalized()
		var sp := Span.new(w1, u, inward, w1.distance_to(w2))
		var top := wall_top(x, z, s, dirs[0])
		var y0 := -FOUNDATION if s == 0 else 0.0
		var has := func(ss: int) -> bool:
			var r := RandomNumberGenerator.new()
			r.seed = hash([L.seed, x, z, corner, 71])
			return (L.has_window(x, z, ss, dirs[0]) or L.has_window(x, z, ss, dirs[1])) and r.randf() < 0.75 \
				and L.has_chamfer(x, z, ss, corner)
		var openings: Array = []
		if has.call(s):
			if zn.type in TALL:
				openings = _tall_window(d, x, z, s, sp, 0.0, sp.length, top, has, hash([x, z, corner]), full)
			else:
				var w := 1.6
				var c := sp.length * 0.5
				sbox(d.geo, sp, c - w * 0.5 - 0.06, c + w * 0.5 + 0.06, 0.94, 1.03, T + 0.1, 0.0, &"concrete_dark")
				sbox(d.geo, sp, c - w * 0.5 - 0.1, c + w * 0.5 + 0.1, 2.42, 2.57, T + 0.04, 0.0, &"concrete_dark")
				_glazing(d.geo, sp, c - w * 0.5, c + w * 0.5, 1.03, 2.42, rng(x, z, s, 75 + corner), 2, 0.9, 1.03)
				openings.append([c - w * 0.5, c + w * 0.5, 1.0, 2.45])
		wall_run(d.geo, sp, 0.0, sp.length, y0, top, openings,
			[[T * 0.25, T * 0.5, mat], [-T * 0.25, T * 0.5, facade_material(zn)]])
		# Posts at both ends; capped where they rise above the roof.
		var cap := 0.05 if top > H + 0.01 else 0.0
		for q in [p1, p2]:
			var qq: Vector2 = q
			d.geo.box(o + Vector3(qq.x, (y0 + top + cap) * 0.5, qq.y), Vector3(T, top + cap - y0, T), mat, surface_of(mat))


func _corner_point(corner: int) -> Vector2:
	match corner:
		0:
			return Vector2(0, 0)
		1:
			return Vector2(C, 0)
		2:
			return Vector2(C, C)
	return Vector2(0, C)


# --- Platforms and pits --------------------------------------------------------------------

const TREAD := 0.3

## The raised platform or sunken pit in this cell (deterministic), or {}:
## kind (&"podium" / &"pit"), rect (cell-local), h (height or depth), side
## (the edge its steps are on), n (risers), footprint (rect plus steps).
func level_feature(x: int, z: int, s: int) -> Dictionary:
	var ex := L.extra_at(x, z, s)
	if ex & (LevelLayout.PODIUM | LevelLayout.PIT) == 0:
		return {}
	var st := L.style_at(x, z, s)
	var blocked := pieces.base_blocked(x, z, s, st)
	var r := rng(x, z, s, 140)
	var pit := ex & LevelLayout.PIT != 0
	var h: float = [0.6, 0.9, 1.2][r.randi_range(0, 2)] if pit else [0.3, 0.45, 0.6, 0.9][r.randi_range(0, 3)]
	if not pit and ceiling_height(st, L.zone_of(x, z, s), L.room_of(x, z, s), x, z, s) - h < 2.5:
		h = 0.3
	var n := maxi(int(round(h / 0.16)), 2)
	var run := n * TREAD
	for attempt in 16:
		var w := r.randf_range(2.4, 5.0)
		var dp := r.randf_range(2.2, 4.4)
		var rect := Rect2(r.randf_range(0.9, C - 0.9 - w), r.randf_range(0.9, C - 0.9 - dp), w, dp)
		var room := [rect.position.y, C - rect.end.x, C - rect.end.y, rect.position.x]
		var side := 0
		for i in 4:
			if room[i] > room[side]:
				side = i
		var foot := rect
		if not pit:
			if room[side] < run + 0.5:
				continue
			match side:
				0:
					foot = Rect2(rect.position.x, rect.position.y - run, rect.size.x, rect.size.y + run)
				1:
					foot = Rect2(rect.position.x, rect.position.y, rect.size.x + run, rect.size.y)
				2:
					foot = Rect2(rect.position.x, rect.position.y, rect.size.x, rect.size.y + run)
				3:
					foot = Rect2(rect.position.x - run, rect.position.y, rect.size.x + run, rect.size.y)
		elif (rect.size.y if side % 2 == 0 else rect.size.x) < run + 1.2:
			continue
		var clear := true
		for b in blocked:
			if b.intersects(foot.grow(0.4)):
				clear = false
				break
		if clear:
			return {"kind": &"pit" if pit else &"podium", "rect": rect, "h": h, "side": side, "n": n, "footprint": foot}
	return {}


## Builds the cell's platform or pit.
func _level_feature(d: ChunkData, x: int, z: int, s: int, o: Vector3, floor_mat: StringName) -> void:
	var f := level_feature(x, z, s)
	if f.is_empty():
		return
	var g := d.geo
	var r := rng(x, z, s, 141)
	var rect: Rect2 = f["rect"]
	var h: float = f["h"]
	var side: int = f["side"]
	var n: int = f["n"]
	var out := LevelLayout.dir_vector(side)
	var lateral := LevelLayout.dir_vector((side + 1) % 4)
	var c := o + Vector3(rect.get_center().x, 0, rect.get_center().y)
	var half_out := (rect.size.y if side % 2 == 0 else rect.size.x) * 0.5  # centre to the step side
	var half_lat := (rect.size.x if side % 2 == 0 else rect.size.y) * 0.5
	var edge := c + out * half_out
	var ws := minf(1.6, half_lat * 2.0 - 0.5)
	if f["kind"] == &"podium":
		var steel := r.randf() < 0.45
		var top_mat: StringName = &"steel_grate" if steel else &"concrete_dark"
		if steel:
			# Grating deck on a frame, skirted in sheet steel.
			g.box(c + Vector3.UP * (h - 0.03), Vector3(rect.size.x, 0.06, rect.size.y), &"steel_grate", &"metal")
			g.box(c + Vector3.UP * ((h - 0.06) * 0.5), Vector3(rect.size.x - 0.04, h - 0.06, rect.size.y - 0.04), &"painted_steel", &"metal")
		else:
			g.box(c + Vector3.UP * (h * 0.5), Vector3(rect.size.x, h, rect.size.y), floor_mat if r.randf() < 0.5 else &"concrete_dark", &"concrete", true)
			# Hazard band round the edge, a hair proud of the sides.
			g.box(c + Vector3.UP * (h - 0.07), Vector3(rect.size.x + 0.02, 0.08, rect.size.y + 0.02), &"painted_steel_yellow")
		_steps(g, edge + out * (n - 1) * TREAD, -out, ws, 0.0, h, top_mat if steel else &"concrete_dark", steel)
		if h >= 0.6:
			_feature_rails(g, o, rect, h, side, ws, true)
		_podium_load(d, c + Vector3.UP * h, rect, side, r)
	else:
		# Pit: walls lining the hole, a floor down at -h, steps up to the rim.
		var wall := 0.2
		var bottom := -h
		var wm: StringName = &"concrete_dark"
		var inner := rect.grow(-wall)
		g.box(o + Vector3(rect.get_center().x, (bottom - 0.25) * 0.5, rect.position.y + wall * 0.5), Vector3(rect.size.x, -bottom + 0.25, wall), wm, &"concrete", true)
		g.box(o + Vector3(rect.get_center().x, (bottom - 0.25) * 0.5, rect.end.y - wall * 0.5), Vector3(rect.size.x, -bottom + 0.25, wall), wm, &"concrete", true)
		g.box(o + Vector3(rect.position.x + wall * 0.5, (bottom - 0.25) * 0.5, rect.get_center().y), Vector3(wall, -bottom + 0.25, inner.size.y), wm, &"concrete", true)
		g.box(o + Vector3(rect.end.x - wall * 0.5, (bottom - 0.25) * 0.5, rect.get_center().y), Vector3(wall, -bottom + 0.25, inner.size.y), wm, &"concrete", true)
		g.box(o + Vector3(inner.get_center().x, bottom - 0.125, inner.get_center().y), Vector3(inner.size.x, 0.25, inner.size.y), &"concrete_floor", &"concrete")
		var top_edge := c + out * (half_out - wall)
		_steps(g, top_edge - out * (n - 1) * TREAD, out, minf(ws, half_lat * 2.0 - wall * 2.0 - 0.2), bottom, 0.0, &"concrete_dark", false)
		if h >= 0.8:
			_feature_rails(g, o, rect, 0.0, side, ws, false)
		# What collects in a pit: standing water, a sump pump, junk.
		d.decals.append(["puddle", Transform3D(Basis(Vector3.UP, r.randf() * TAU), c + Vector3.UP * bottom - out * 0.6),
			Vector3(inner.size.x * 0.8, 0.5, inner.size.y * 0.8)])
		var pump := c + Vector3.UP * bottom - out * (half_out - wall - 0.5) + lateral * (half_lat - wall - 0.45)
		g.cylinder(pump, pump + Vector3.UP * 0.6, 0.22, &"painted_steel_blue", 10, true)
		g.box(pump + Vector3.UP * 0.3, Vector3(0.44, 0.6, 0.44), &"", &"metal")
		g.cylinder(pump + Vector3.UP * 0.5, pump + Vector3.UP * (-bottom + 0.3) + out * 0.3, 0.05, &"rusted_metal", 6)
		for i in r.randi_range(2, 6):
			var p := c + Vector3.UP * bottom + Vector3(r.randf_range(-inner.size.x, inner.size.x) * 0.4, 0, r.randf_range(-inner.size.y, inner.size.y) * 0.4)
			var size := Vector3(r.randf_range(0.1, 0.35), r.randf_range(0.05, 0.15), r.randf_range(0.1, 0.3))
			g.box(p + Vector3.UP * size.y * 0.4, size, &"concrete_dark", &"", false, Basis.from_euler(Vector3(r.randf_range(-0.4, 0.4), r.randf() * TAU, 0)))


## A flight of steps climbing `a` from foot (at height y0) to y1, `width`
## wide, with a walkable ramp collider over the noses (2 cm proud, as for the
## main stairs, so the top edge never stops anybody).
func _steps(g: GeoBuilder, foot: Vector3, a: Vector3, width: float, y0: float, y1: float, mat: StringName, open: bool) -> void:
	var rise := y1 - y0
	var n := maxi(int(round(rise / 0.16)), 2)
	var lateral := a.cross(Vector3.UP)
	for i in n - 1:
		var top := y0 + rise * (i + 1) / n
		var p := foot + a * (i * TREAD + TREAD * 0.5)
		if open:
			g.box(p + Vector3.UP * (top - 0.025), _oriented(a, Vector3(width, 0.05, TREAD + 0.02)), &"steel_grate", &"metal")
		else:
			g.box(p + Vector3.UP * ((y0 + top) * 0.5 - 0.01), _oriented(a, Vector3(width, top - y0 + 0.02, TREAD)), mat, &"concrete")
	if open:
		for e: float in [-1.0, 1.0]:
			var q0 := foot + lateral * (e * (width * 0.5 + 0.03)) + Vector3.UP * y0
			var q1 := q0 + a * ((n - 1) * TREAD) + Vector3.UP * rise
			beam(g, q0 + Vector3.UP * 0.05, q1 - Vector3.UP * 0.05, Vector2(0.05, 0.2), &"painted_steel_yellow")
	# Ramp from a tread's length before the first step to the top edge.
	var p0 := foot - a * TREAD + Vector3.UP * y0
	var p1 := foot + a * ((n - 1) * TREAD) + Vector3.UP * y1
	var length := p0.distance_to(p1) + 0.1
	var fwd := (p1 - p0).normalized()
	var up := lateral.cross(fwd).normalized()
	if up.y < 0.0:
		up = -up
	g.box((p0 + p1) * 0.5 + fwd * 0.05 - up * 0.04, Vector3(width, 0.12, length), &"", &"concrete", false,
		Basis(up.cross(fwd).normalized(), up, fwd))


## Railing round a platform's or pit's edge at height y, open where its
## steps are.
func _feature_rails(g: GeoBuilder, o: Vector3, rect: Rect2, y: float, side: int, gap: float, outward: bool) -> void:
	var inset := 0.08 if outward else -0.12  # on the platform's edge / just outside the pit
	var r := rect.grow(-inset)
	var corners := [Vector2(r.position.x, r.position.y), Vector2(r.end.x, r.position.y), Vector2(r.end.x, r.end.y), Vector2(r.position.x, r.end.y)]
	for sd in 4:
		var a: Vector2 = corners[sd]
		var b: Vector2 = corners[(sd + 1) % 4]
		var pa := o + Vector3(a.x, y, a.y)
		var pb := o + Vector3(b.x, y, b.y)
		if sd == side:
			var m := (pa + pb) * 0.5
			var t := (pb - pa).normalized()
			railing(g, pa, m - t * (gap * 0.5 + 0.1))
			railing(g, m + t * (gap * 0.5 + 0.1), pb)
		else:
			railing(g, pa, pb)


## Something on a platform: a press on its plinth, a control stand, stock.
func _podium_load(d: ChunkData, top: Vector3, rect: Rect2, side: int, r: RandomNumberGenerator) -> void:
	var roll := r.randf()
	var yaw := (PI * 0.5) * side
	if roll < 0.3 and minf(rect.size.x, rect.size.y) >= 2.7:
		kit(d, "vat", top, r.randf() * TAU)
	elif roll < 0.55:
		kit(d, "desk", top + Vector3(r.randf_range(-0.3, 0.3), 0, r.randf_range(-0.3, 0.3)), yaw + PI)
		kit(d, "electrical_cabinet", top + LevelLayout.dir_vector(side) * -0.9, yaw)
	elif roll < 0.8:
		for i in r.randi_range(1, 3):
			kit(d, ["crate_wood", "barrel_rust", "barrel_blue"][r.randi_range(0, 2)],
				top + Vector3((i - 1) * 1.1, 0, r.randf_range(-0.4, 0.4)), r.randf() * TAU)


# --- Cramped passages -------------------------------------------------------------------

## Fills the cell solid except a narrow cross of passages toward its open
## edges: service corridors and the hallways inside office blocks.
func _narrow(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, mat: StringName) -> void:
	# Tucked under the slab above (never level with its top), and clear of the
	# walls round the cell.
	var top := H - 0.3 if slab_over(x, z, s) and not L.has_flag(x, z, s + 1, LevelLayout.STAIR_ABOVE) else H
	if s < 0:
		top = H - BURIED
	var y0 := -FOUNDATION if s == 0 else 0.0
	var e := T * 0.5
	var solids := narrow_solids(x, z, s, st)
	# Crawl tunnels through the fill to a vent: fill each side and above.
	var tunnels: Array[Array] = []  # [rect, y0, y1]
	for dir in 4:
		if not L.has_vent(x, z, s, dir):
			continue
		var arm := narrow_arm(st, dir)
		var t0 := C * 0.5 - VENT_W * 0.5
		var t1 := C * 0.5 + VENT_W * 0.5
		if dir % 2 == 0:
			solids.append(Rect2(arm.position.x, arm.position.y, t0 - arm.position.x, arm.size.y))
			solids.append(Rect2(t1, arm.position.y, arm.end.x - t1, arm.size.y))
			tunnels.append([Rect2(t0, arm.position.y, VENT_W, arm.size.y), dir])
		else:
			solids.append(Rect2(arm.position.x, arm.position.y, arm.size.x, t0 - arm.position.y))
			solids.append(Rect2(arm.position.x, t1, arm.size.x, arm.end.y - t1))
			tunnels.append([Rect2(arm.position.x, t0, arm.size.x, VENT_W), dir])
	for tn in tunnels:
		var r: Rect2 = tn[0]
		if r.position.x < e and edge_top(x, z, s, 3) > -INF:
			r = Rect2(e, r.position.y, r.end.x - e, r.size.y)
		if r.end.x > C - e and edge_top(x, z, s, 1) > -INF:
			r.size.x = C - e - r.position.x
		if r.position.y < e and edge_top(x, z, s, 0) > -INF:
			r = Rect2(r.position.x, e, r.size.x, r.end.y - e)
		if r.end.y > C - e and edge_top(x, z, s, 2) > -INF:
			r.size.y = C - e - r.position.y
		d.geo.box(o + Vector3(r.get_center().x, (VENT_H + top) * 0.5, r.get_center().y), Vector3(r.size.x, top - VENT_H, r.size.y), mat,
			surface_of(mat), true)
		# Galvanised lining a hair inside the bore.
		var along_x: bool = (tn[1] as int) % 2 == 1
		var lin := Vector3(r.size.x, 0.02, r.size.y)
		d.geo.box(o + Vector3(r.get_center().x, VENT_H - 0.02, r.get_center().y), lin, &"painted_steel")
		for side: float in [-1.0, 1.0]:
			var c := r.get_center() + (Vector2(0, side * (VENT_W * 0.5 - 0.02)) if along_x else Vector2(side * (VENT_W * 0.5 - 0.02), 0))
			d.geo.box(o + Vector3(c.x, VENT_H * 0.5, c.y), Vector3(r.size.x, VENT_H - 0.05, 0.02) if along_x else Vector3(0.02, VENT_H - 0.05, r.size.y),
				&"painted_steel")
	for r in solids:
		var x0 := r.position.x
		var z0 := r.position.y
		var x1 := r.end.x
		var z1 := r.end.y
		if x0 < e and edge_top(x, z, s, 3) > -INF:
			x0 = e
		if x1 > C - e and edge_top(x, z, s, 1) > -INF:
			x1 = C - e
		if z0 < e and edge_top(x, z, s, 0) > -INF:
			z0 = e
		if z1 > C - e and edge_top(x, z, s, 2) > -INF:
			z1 = C - e
		if x1 - x0 < 0.01 or z1 - z0 < 0.01:
			continue
		d.geo.box(o + Vector3((x0 + x1) * 0.5, (y0 + top) * 0.5, (z0 + z1) * 0.5), Vector3(x1 - x0, top - y0, z1 - z0), mat,
			surface_of(mat), true)


## Edges a cramped passage runs to: its open edges, and windows in its outer
## walls (a short dead end with daylight).
func narrow_edges(x: int, z: int, s: int, crawl: bool = false) -> int:
	var m := L.open_edges(x, z, s)
	for dir in 4:
		if L.has_window(x, z, s, dir) and wall_kind(x, z, s, dir) == 2:
			m |= 1 << dir
		if crawl and L.has_vent(x, z, s, dir):
			m |= 1 << dir
	return m


## Cell-local rect of the arm of a cramped passage toward `dir`.
func narrow_arm(st: ZoneStyle, dir: int) -> Rect2:
	var w := st.passage_width
	var h0 := C * 0.5 - w * 0.5
	var h1 := C * 0.5 + w * 0.5
	match dir:
		0:
			return Rect2(h0, 0, w, h0)
		1:
			return Rect2(h1, h0, C - h1, w)
		2:
			return Rect2(h0, h1, w, C - h1)
	return Rect2(0, h0, h0, w)


## Cell-local rects of the solid fill around a cramped passage.
func narrow_solids(x: int, z: int, s: int, st: ZoneStyle) -> Array[Rect2]:
	var w := st.passage_width
	var h0 := C * 0.5 - w * 0.5
	var h1 := C * 0.5 + w * 0.5
	var open := narrow_edges(x, z, s, true)
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
	var open := narrow_edges(x, z, s) if L.zone_of(x, z, s).type != &"connector" else L.open_edges(x, z, s)
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


# --- Walkways -----------------------------------------------------------------------------

## A covered walkway across open ground (or a bridge between upper floors):
## a passage the corridor style's width with its own floor, walls with ribbon
## windows and a roof, standing free of the cell edges except where it meets
## a building or the next walkway cell. Steel legs carry bridges.
func _connector(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle) -> void:
	var g := d.geo
	var w := st.passage_width
	var h0 := C * 0.5 - w * 0.5
	var h1 := C * 0.5 + w * 0.5
	var open := L.open_edges(x, z, s)
	var xs: Array[float] = [0.0, h0 - T, h0, h1, h1 + T, C]
	# 5x5 grid over the cell: 1 passage, 2 wall, 0 open air.
	var grid := PackedInt32Array()
	grid.resize(25)
	for j in 5:
		for i in 5:
			var p := (i == 2 and j == 2) or (i == 2 and j < 2 and open & 1) or (i > 2 and j == 2 and open & 2) \
				or (i == 2 and j > 2 and open & 4) or (i < 2 and j == 2 and open & 8)
			grid[j * 5 + i] = 1 if p else 0
	for j in 5:
		for i in 5:
			if grid[j * 5 + i] != 0:
				continue
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var a := i + di
					var b := j + dj
					if a >= 0 and b >= 0 and a < 5 and b < 5 and grid[b * 5 + a] == 1:
						grid[j * 5 + i] = 2
	var cover: Array[Rect2] = []
	for j in 5:
		for i in 5:
			if grid[j * 5 + i] > 0:
				cover.append(Rect2(xs[i], xs[j], xs[i + 1] - xs[i], xs[j + 1] - xs[j]))
	emit_slab(d, o, slab_pieces(x, z, s - 1, cover, s), 0.0, 0.25 if s == 0 else 0.3, st.floor_material, false)
	emit_slab(d, o, slab_pieces(x, z, -1, cover, s), PASSAGE + 0.25, 0.25, st.ceiling_material, true)
	var r := rng(x, z, s, 85)
	var glazed := [r.randf() < 0.7, r.randf() < 0.7, r.randf() < 0.7, r.randf() < 0.7]
	var mat := st.wall_material
	for j in 5:
		for i in 5:
			if grid[j * 5 + i] != 2:
				continue
			var rect := Rect2(xs[i], xs[j], xs[i + 1] - xs[i], xs[j + 1] - xs[j])
			var ns := (j > 0 and grid[(j - 1) * 5 + i] == 1) or (j < 4 and grid[(j + 1) * 5 + i] == 1)
			var ew := (i > 0 and grid[j * 5 + i - 1] == 1) or (i < 4 and grid[j * 5 + i + 1] == 1)
			var sp: Span
			if ns and not ew:
				# Runs along X; the passage is north or south of it.
				var inward := Vector3(0, 0, 1) if j < 4 and grid[(j + 1) * 5 + i] == 1 else Vector3(0, 0, -1)
				sp = Span.new(o + Vector3(rect.position.x, 0, rect.get_center().y), Vector3(1, 0, 0), inward, rect.size.x)
			elif ew and not ns:
				var inward := Vector3(1, 0, 0) if i < 4 and grid[j * 5 + i + 1] == 1 else Vector3(-1, 0, 0)
				sp = Span.new(o + Vector3(rect.get_center().x, 0, rect.position.y), Vector3(0, 0, 1), inward, rect.size.y)
			var side := -1
			if sp:
				side = (0 if sp.m.z > 0.5 else 2) if absf(sp.m.z) > 0.5 else (3 if sp.m.x > 0.5 else 1)
			if sp == null or sp.length < 0.8 or not glazed[side]:
				g.box(o + Vector3(rect.get_center().x, PASSAGE * 0.5, rect.get_center().y), Vector3(rect.size.x, PASSAGE, rect.size.y),
					mat, surface_of(mat), rect.size.x > 2.0 or rect.size.y > 2.0)
				continue
			# Ribbon window along the passage.
			wall_run(g, sp, 0.0, sp.length, 0.0, PASSAGE, [[0.0, sp.length, 1.05, 2.35]], [[0.0, T, mat]])
			sbox(g, sp, 0.0, sp.length, 0.99, 1.08, T + 0.08, 0.0, &"concrete_dark")
			sbox(g, sp, 0.0, sp.length, 2.3, 2.42, T + 0.04, 0.0, &"concrete_dark")
			_glazing(g, sp, 0.0, sp.length, 1.08, 2.3, r, maxi(int(round(sp.length / 1.2)), 1), 0.61, 1.08)
	if s >= 1 and not is_building(x, z, s - 1):
		# Legs down to the ground and a cross beam under the deck.
		var along_x := open & 10 != 0
		var across := Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0)
		var c := o + Vector3(C * 0.5, 0, C * 0.5)
		var depth := s * H + 0.1
		for e: float in [-1.0, 1.0]:
			var p := c + across * (e * (w * 0.5 + T * 0.5))
			g.box(p + Vector3.UP * (-0.3 - (depth - 0.3) * 0.5), Vector3(0.3, depth - 0.3, 0.3), &"painted_steel", &"metal")
		g.box(c + Vector3.UP * -0.42, Vector3(0.2, 0.24, w + T) if along_x else Vector3(w + T, 0.24, 0.2), &"painted_steel")


# --- Ceilings and columns -----------------------------------------------------------------

func ceiling_height(st: ZoneStyle, zn: LevelLayout.Zone, room: LevelLayout.Room, x: int, z: int, s: int) -> float:
	if s < 0:
		return H - BURIED
	if zn.type == &"connector":
		return st.drop_ceiling if st.drop_ceiling > 0.0 and st.drop_ceiling < PASSAGE else PASSAGE
	if st.drop_ceiling > 0.0 and not L.has_flag(x, z, s, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) \
			and L.kind_at(x, z, s) == LevelLayout.Kind.FLOOR and not (room and room.use in [&"stairwell", &"boiler"]) \
			and zn.type not in TALL and L.flags_at(x, z, s) & (15 * LevelLayout.CHAMFER) == 0:
		return st.drop_ceiling
	if zn.type in TALL and s == 0:
		return (zn.top + 1) * H
	return H


func _ceiling(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone, flags: int,
		full: bool) -> void:
	var room := L.room_of(x, z, s)
	var hc := ceiling_height(st, zn, room, x, z, s)
	if hc < H - 0.01 and s >= 0:
		_drop_ceiling(d, x, z, s, o, st, hc)
	if not needs_ceiling(x, z, s, zn):
		return
	if flags & LevelLayout.ROOF_HOLE:
		var r := rng(x, z, s, 6)
		# What's left of the roof: a ragged edge, a sheet hanging in.
		var done: Array[Rect2] = []
		for side in 4:
			if r.randf() < 0.5:
				var sr := strip(side, r.randf_range(0.5, 1.8))
				emit_slab(d, o, slab_pieces(x, z, s, subtract_all(sr, done), s), H, 0.3, st.ceiling_material, false)
				done.append(sr)
		var tilt := Basis.from_euler(Vector3(r.randf_range(0.6, 1.1), r.randf() * TAU, r.randf_range(-0.3, 0.3)))
		d.geo.box(o + Vector3(r.randf_range(1.0, 7.0), H - 1.2, r.randf_range(1.0, 7.0)), Vector3(3.5, 0.1, 2.0),
			&"corrugated_metal", &"metal", false, tilt)
		if full:
			var hole := o + Vector3(C * 0.5, H, C * 0.5)
			var sun := sun_dir()
			d.lights.append({"type": "spot", "position": hole - sun * 10.0, "target": hole + sun * 6.0,
				"color": Color(0.78, 0.83, 0.92), "energy": 8.0, "range": 40.0, "angle": 17.0,
				"shadow": true, "fog": 4.0})
		return
	if s < 0:
		emit_slab(d, o, slab_pieces(x, z, s, _rects(Rect2(0, 0, C, C)), s), H - BURIED_ROOF, BURIED - BURIED_ROOF, st.ceiling_material, true)
		return
	emit_slab(d, o, slab_pieces(x, z, s, _rects(Rect2(0, 0, C, C)), s), H, 0.3, st.ceiling_material, true)
	if L.flags_at(x, z, s) & (15 * LevelLayout.CHAMFER):
		return
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
	var hole := drop_rect(x, z, s + 1) if L.has_drop(x, z, s + 1) else Rect2()
	for area in areas:
		var nx := int(round(area.size.x / tile.x)) if area.size.x >= tile.x else 1
		var nz := int(round(area.size.y / tile.y)) if area.size.y >= tile.y else 1
		var tw := area.size.x / nx
		var tz := area.size.y / nz
		for i in nx:
			for j in nz:
				var p := o + Vector3(area.position.x + (i + 0.5) * tw, hc + 0.01, area.position.y + (j + 0.5) * tz)
				var roll := r.randf()
				if hole.has_area() and hole.intersects(Rect2(area.position.x + i * tw, area.position.y + j * tz, tw, tz)):
					continue  # the floor above came down through here
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
	if (x - r.position.x) % 2 != 0 or (z - r.position.y) % 2 != 0:
		return
	for c: Vector2i in [Vector2i(x - 1, z - 1), Vector2i(x, z - 1), Vector2i(x - 1, z), Vector2i(x, z)]:
		if not zn.cols.has(c):
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


static func box_aabb(center: Vector3, size: Vector3, basis: Basis) -> AABB:
	var ext := Vector3.ZERO
	for i in 3:
		ext += (basis[i] * size[i] * 0.5).abs()
	return AABB(center - ext, ext * 2.0)


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
		d.taken.append(box_aabb(xform * (Vector3.UP * float(fp[1])), size, xform.basis))
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
	# Tunnels keep their caged bulkhead lamps, on the roof of the passage.
	if (narrow and zn.type != &"tunnel") or (room and room.use in [&"cubicles", &"offices", &"meeting", &"archive", &"washroom", &"lab"]):
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
			var oe := narrow_edges(x, z, s) if narrow else 0
			var run := 0 if oe & 10 == 0 else (1 if oe & 5 == 0 else -1)  # 0 along z, 1 along x
			if narrow and run >= 0:
				# On a side wall of a straight tunnel passage, under the pipes.
				var side := 1.0 if r.randf() < 0.5 else -1.0
				var inward := Vector3(-side, 0, 0) if run == 0 else Vector3(0, 0, -side)
				pos = o + Vector3(C * 0.5, minf(hc - 1.2, 2.3), C * 0.5) - inward * (st.passage_width * 0.5) \
					+ inward * Detailer.NUDGE + inward.cross(Vector3.UP) * r.randf_range(-1.0, 1.0)
				yaw = atan2(inward.x, inward.z)
			elif wall >= 0:
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
			# Flush under a tiled ceiling; otherwise on its rods (below ground the
			# ceiling is solid: on rods too).
			var tiled := hc < H - 0.01 and s >= 0
			var pos := o + Vector3(C * 0.5, hc - (0.07 if tiled else 1.0), C * 0.5)
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
		and not L.has_gap(x, z, s, dir) \
		and not (L.stair_sides(x, z, s) & (1 << dir)) and not L.has_flag(x, z, s, LevelLayout.NARROW) \
		and L.chamfer_at(x, z, s, dir, false) < 0 and L.chamfer_at(x, z, s, dir, true) < 0 \
		and L.zone_of(x, z, s).type != &"yard"
