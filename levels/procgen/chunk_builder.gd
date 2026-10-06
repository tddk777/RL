class_name ChunkBuilder
extends RefCounted
## Turns the cells of one chunk of a LevelLayout into geometry and placements.
## Reads the layout only, keeps no mutable state between calls, and creates no
## nodes, so build() can run on worker threads.
##
## Every random choice comes from a per-cell RNG seeded from (level seed,
## cell, purpose), so a chunk always rebuilds identically and the navigation
## pass (which also builds neighbouring cells) matches the visible one.

const T := 0.3  # wall thickness
const RAMP := 3.2  # width of a stair strip
const CATWALK := 3.0  # depth of a catwalk strip
const TALL := [&"hall", &"warehouse", &"loading_dock"]
const SUN_DIR := Vector3(0.38, -1.0, 0.22)

## Kit prop footprints for navigation: id -> [size, center height].
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
}

const SURFACES := {
	&"wood_planks": &"wood", &"corrugated_metal": &"metal", &"painted_steel": &"metal",
	&"painted_steel_yellow": &"metal", &"painted_steel_red": &"metal", &"rusted_metal": &"metal",
	&"steel_grate": &"metal",
}


class ChunkData:
	var coord: Vector2i
	var bounds: AABB
	var geo: GeoBuilder
	## [kit id, Transform3D, options Dictionary]
	var props: Array = []
	## Dictionaries: type, position, rotation, color, energy, range, angle, shadow, flicker, pulse, buzz, prop
	var lights: Array = []
	## [texture name, Transform3D, size Vector3]
	var decals: Array = []
	## Dictionaries: position (drip origin), floor (y)
	var leaks: Array = []
	var nav_faces := PackedVector3Array()


var L: LevelLayout
var C: float
var H: float
var N: int
var _ibeam: Dictionary  # material -> [verts, normals], unit height


## Must be created on the main thread (builds the shared I-beam mesh).
func _init(layout: LevelLayout) -> void:
	L = layout
	C = layout.cell
	H = layout.storey_height
	N = layout.profile.chunk_cells
	_ibeam = _make_ibeam()


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
	# Navigation source: this chunk plus a one-cell ring, clipped to the
	# chunk bounds grown by the bake border, so neighbouring tiles line up.
	var nd := ChunkData.new()
	nd.geo = GeoBuilder.new()
	nd.geo.visuals = false
	nd.geo.nav_bounds = d.bounds.grow(1.5)
	for x in range(coord.x * N - 1, (coord.x + 1) * N + 1):
		for z in range(coord.y * N - 1, (coord.y + 1) * N + 1):
			for s in L.storeys:
				_cell(nd, x, z, s, false)
	d.nav_faces = nd.geo.packed_nav()
	d.geo.finalize()
	return d


# --- Per cell -------------------------------------------------------------------------

func _rng(x: int, z: int, s: int, purpose: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([L.seed, x, z, s, purpose])
	return r


func _cell(d: ChunkData, x: int, z: int, s: int, full: bool) -> void:
	var k := L.kind_at(x, z, s)
	if k == LevelLayout.Kind.EMPTY:
		return
	var zn := L.zone_of(x, z, s)
	var st := zn.style
	var o := L.cell_origin(x, z, s)
	var flags := L.flags_at(x, z, s)
	var floor_mat := st.floor_material if s == 0 else st.upper_floor_material
	var wall_mat := st.wall_material if s == 0 else st.upper_wall_material
	match k:
		LevelLayout.Kind.FLOOR:
			_floor(d, x, z, s, o, floor_mat, flags)
		LevelLayout.Kind.CATWALK:
			_catwalk(d, o, flags)
		LevelLayout.Kind.HOLE:
			_broken_floor(d, x, z, s, o, floor_mat)
	if flags & LevelLayout.STAIR:
		_ramp(d, x, z, s, o)
	if flags & LevelLayout.STAIR_ABOVE and k == LevelLayout.Kind.FLOOR:
		_ramp_hole_rails(d, x, z, s, o)
	for dir in 4:
		_wall(d, x, z, s, o, dir, wall_mat, st, zn, full)
	_ceiling(d, x, z, s, o, st, zn, flags, full)
	if s == 0 and zn.type in TALL:
		_column(d, x, z, zn)
	if k == LevelLayout.Kind.FLOOR:
		_dressing(d, x, z, s, o, st, zn, flags)
		if full:
			_lights(d, x, z, s, o, st, zn, flags)


func _surface_of(mat: StringName) -> StringName:
	return SURFACES.get(mat, &"concrete")


## Cell-local rectangle (x, z in 0..C) of a strip along one side.
func _strip(side: int, depth: float) -> Rect2:
	match side:
		0:
			return Rect2(0, 0, C, depth)
		1:
			return Rect2(C - depth, 0, depth, C)
		2:
			return Rect2(0, C - depth, C, depth)
		_:
			return Rect2(0, 0, depth, C)


func _rest(side: int, depth: float) -> Rect2:
	match side:
		0:
			return Rect2(0, depth, C, C - depth)
		1:
			return Rect2(0, 0, C - depth, C)
		2:
			return Rect2(0, 0, C, C - depth)
		_:
			return Rect2(depth, 0, C - depth, C)


func _slab(g: GeoBuilder, o: Vector3, r: Rect2, top: float, thick: float, mat: StringName, occlude: bool) -> void:
	g.box(o + Vector3(r.position.x + r.size.x * 0.5, top - thick * 0.5, r.position.y + r.size.y * 0.5),
		Vector3(r.size.x, thick, r.size.y), mat, _surface_of(mat), occlude)


func _floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName, flags: int) -> void:
	var thick := 0.5 if s == 0 else 0.3
	if flags & LevelLayout.STAIR_ABOVE:
		_slab(d.geo, o, _rest(L.stair_side(x, z, s), RAMP), 0.0, thick, mat, true)
	else:
		_slab(d.geo, o, Rect2(0, 0, C, C), 0.0, thick, mat, s > 0)


func _catwalk(d: ChunkData, o: Vector3, flags: int) -> void:
	var sides := (flags >> 4) & 15
	for side in 4:
		if not (sides & (1 << side)):
			continue
		var r := _strip(side, CATWALK)
		_slab(d.geo, o, r, 0.0, 0.08, &"steel_grate", false)
		# Inner edge: support beam and railing, trimmed where other strips meet.
		var lateral := Vector3(LevelLayout.dir_vector((side + 1) % 4))
		var inward := -LevelLayout.dir_vector(side)
		var edge_center := o + Vector3(C * 0.5, 0, C * 0.5) - inward * (C * 0.5 - CATWALK)
		var a0 := -C * 0.5
		var a1 := C * 0.5
		var minus_side := (side + 3) % 4
		var plus_side := (side + 1) % 4
		if sides & (1 << minus_side):
			a0 += CATWALK
		if sides & (1 << plus_side):
			a1 -= CATWALK
		# lateral points toward plus_side
		var p0 := edge_center + lateral * a0
		var p1 := edge_center + lateral * a1
		_beam(d.geo, p0 + Vector3.DOWN * 0.24, p1 + Vector3.DOWN * 0.24, Vector2(0.14, 0.32), &"painted_steel")
		_railing(d.geo, p0, p1)


func _broken_floor(d: ChunkData, x: int, z: int, s: int, o: Vector3, mat: StringName) -> void:
	var r := _rng(x, z, s, 4)
	# Jagged remains of the slab along a couple of edges.
	for side in 4:
		if r.randf() < 0.55:
			var strip := _strip(side, r.randf_range(0.6, 1.6))
			_slab(d.geo, o, strip, 0.0, 0.3, mat, false)
	if r.randf() < 0.7:
		var tilt := Basis.from_euler(Vector3(r.randf_range(-0.6, 0.6), r.randf() * TAU, r.randf_range(-0.5, 0.5)))
		d.geo.box(o + Vector3(r.randf_range(2.5, 5.5), -1.6, r.randf_range(2.5, 5.5)), Vector3(2.4, 0.25, 1.8), mat, &"", false, tilt)
	for i in 4:
		var a := o + Vector3(r.randf_range(0.5, 7.5), -0.15, r.randf_range(0.5, 7.5))
		d.geo.cylinder(a, a + Vector3(r.randf_range(-0.6, 0.6), r.randf_range(-1.2, -0.3), r.randf_range(-0.6, 0.6)), 0.012, &"gun_metal", 4)


func _ramp(d: ChunkData, x: int, z: int, s: int, o: Vector3) -> void:
	var dir := L.stair_dir(x, z, s)
	var side := L.stair_side(x, z, s)
	var strip := _strip(side, RAMP)
	var center := o + Vector3(strip.position.x + strip.size.x * 0.5, 0.0, strip.position.y + strip.size.y * 0.5)
	var a := LevelLayout.dir_vector(dir)
	var lateral := a.cross(Vector3.UP).normalized()
	var length := sqrt(C * C + H * H)
	var forward := (a * C + Vector3.UP * H).normalized()
	var up := lateral.cross(forward).normalized()
	if up.y < 0.0:
		up = -up
		lateral = -lateral
	var basis := Basis(lateral, up, forward)
	var mid := center + Vector3.UP * (H * 0.5)
	# Walkable ramp collider just under the step noses.
	d.geo.box(mid - up * 0.07, Vector3(RAMP - 0.3, 0.12, length), &"", &"metal", false, basis)
	# Treads
	var steps := int(round(H / 0.2))
	var width := RAMP - 0.35
	for i in steps:
		var t := (i + 0.5) / steps - 0.5
		var p := center + a * (t * C) + Vector3.UP * ((i + 1) * H / steps - 0.025)
		d.geo.box(p, _oriented(a, Vector3(width, 0.05, C / steps + 0.03)), &"steel_grate")
	# Stringers and handrails on both edges
	for e: float in [-1.0, 1.0]:
		var off := lateral * (e * (width * 0.5 + 0.04))
		d.geo.box(mid + off - up * 0.1, Vector3(0.07, 0.32, length), &"painted_steel_yellow", &"", false, basis)
		var r0 := center + off - a * (C * 0.5) + Vector3.UP * 1.0
		var r1 := center + off + a * (C * 0.5) + Vector3.UP * (H + 1.0)
		d.geo.cylinder(r0, r1, 0.025, &"painted_steel_yellow", 6)
	# Clip guard on the open (inner) edge of the upper part of the ramp
	var inner := _inner_lateral(side, lateral)
	var gmid := center + inner * (width * 0.5 + 0.1) + a * (C * 0.2) + Vector3.UP * (H * 0.7 + 0.5)
	d.geo.box(gmid, Vector3(0.1, 1.2, length * 0.6), &"", &"metal", false, basis, Layers.CLIP)


## Unit vector pointing from the ramp strip toward the middle of the cell.
func _inner_lateral(side: int, lateral: Vector3) -> Vector3:
	var to_wall := LevelLayout.dir_vector(side)
	return -to_wall if absf(to_wall.dot(lateral)) > 0.5 else lateral


func _oriented(along: Vector3, size: Vector3) -> Vector3:
	## size is (width, height, length along `along`) -> world axis-aligned size.
	return Vector3(size.z, size.y, size.x) if absf(along.x) > 0.5 else size


## Railings around the ramp opening on the storey above a stair.
func _ramp_hole_rails(d: ChunkData, x: int, z: int, s: int, o: Vector3) -> void:
	var side := L.stair_side(x, z, s)
	var dir := L.stair_dir(x, z, s)
	var a := LevelLayout.dir_vector(dir)
	var inward := -LevelLayout.dir_vector(side)
	var cc := o + Vector3(C * 0.5, 0.0, C * 0.5)
	var edge := cc - inward * (C * 0.5 - RAMP)
	# Long inner edge
	_railing(d.geo, edge - a * (C * 0.5), edge + a * (C * 0.5))
	# Across the far (low) end of the opening
	var wall_point := cc + LevelLayout.dir_vector(side) * (C * 0.5)
	var low_end := -a * (C * 0.5)
	_railing(d.geo, edge + low_end, wall_point + low_end)


func _railing(g: GeoBuilder, p0: Vector3, p1: Vector3) -> void:
	var length := p0.distance_to(p1)
	if length < 0.2:
		return
	var posts := maxi(int(ceil(length / 1.6)), 1)
	for i in posts + 1:
		var p := p0.lerp(p1, float(i) / posts)
		g.box(p + Vector3.UP * 0.55, Vector3(0.05, 1.1, 0.05), &"painted_steel_yellow")
	for h in [0.55, 1.08]:
		g.cylinder(p0 + Vector3.UP * h, p1 + Vector3.UP * h, 0.022, &"painted_steel_yellow", 6)
	var dir := (p1 - p0).normalized()
	var basis := Basis.looking_at(dir, Vector3.UP)
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.06, Vector3(0.012, 0.12, length), &"painted_steel", &"", false, basis)
	g.box((p0 + p1) * 0.5 + Vector3.UP * 0.6, Vector3(0.08, 1.2, length), &"", &"metal", false, basis, Layers.CLIP)


func _beam(g: GeoBuilder, p0: Vector3, p1: Vector3, section: Vector2, mat: StringName) -> void:
	var length := p0.distance_to(p1)
	if length < 0.05:
		return
	var basis := Basis.looking_at((p1 - p0).normalized(), Vector3.UP)
	g.box((p0 + p1) * 0.5, Vector3(section.x, section.y, length), mat, _surface_of(mat), false, basis)


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
	var trims: Array = []
	var exterior := not n_enclosed
	if L.has_door(x, z, s, dir):
		var w := _door_width(x, z, s, n, st)
		var h := _door_height(x, z, s, n, st)
		openings.append([C * 0.5 - w * 0.5, C * 0.5 + w * 0.5, 0.0, h])
		if owns_trim:
			trims.append(openings.back())
	elif s == 0 and exterior and L.has_flag(x, z, s, LevelLayout.DOCK):
		openings.append([1.2, C - 1.2, 0.0, 4.6])
		_shutter(d, o, dir)
	elif exterior and st.windows and s >= 1 and zn.type in TALL:
		openings.append([1.4, C - 1.4, 1.9, 4.5])
		_window(d, x, z, s, o, dir, full)
	_wall_with_openings(d.geo, o, dir, openings, mat, depth, inset)
	for t in trims:
		_door_frame(d.geo, o, dir, t)


func _door_width(x: int, z: int, s: int, n: Vector2i, st: ZoneStyle) -> float:
	var w := st.ground_door_width if s == 0 else st.door_width
	var other := L.style_at(n.x, n.y, s)
	if other:
		w = maxf(w, other.ground_door_width if s == 0 else other.door_width)
	return w


func _door_height(x: int, z: int, s: int, n: Vector2i, st: ZoneStyle) -> float:
	var h := st.ground_door_height if s == 0 else st.door_height
	var other := L.style_at(n.x, n.y, s)
	if other:
		h = maxf(h, other.ground_door_height if s == 0 else other.door_height)
	return minf(h, H - 0.6)


## Wall on the `dir` edge of the cell, minus openings [a0, a1, y0, y1] in
## cell-local "along the wall" coordinates (0..C, left to right seen from
## inside) and storey-local heights.
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
			_wall_box(g, o, dir, e0, e1, sp.x, sp.y, mat, true, depth, inset)


func _wall_box(g: GeoBuilder, o: Vector3, dir: int, a0: float, a1: float, y0: float, y1: float, mat: StringName,
		collide: bool, depth: float = T, inset: float = 0.0) -> void:
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
	g.box(o + center, size, mat, _surface_of(mat) if collide else &"", collide)


func _door_frame(g: GeoBuilder, o: Vector3, dir: int, op: Array) -> void:
	var a0: float = op[0]
	var a1: float = op[1]
	var h: float = op[3]
	_wall_box(g, o, dir, a0 - 0.08, a0, 0.0, h + 0.08, &"rusted_metal", false, T + 0.06)
	_wall_box(g, o, dir, a1, a1 + 0.08, 0.0, h + 0.08, &"rusted_metal", false, T + 0.06)
	_wall_box(g, o, dir, a0 - 0.08, a1 + 0.08, h, h + 0.1, &"rusted_metal", false, T + 0.06)


func _shutter(d: ChunkData, o: Vector3, dir: int) -> void:
	_wall_box(d.geo, o, dir, 1.2, C - 1.2, 0.0, 4.6, &"corrugated_metal", true, 0.12, -0.12)
	_wall_box(d.geo, o, dir, 1.0, C - 1.0, 4.6, 5.2, &"rusted_metal", true, 0.5, -0.1)
	for a in [1.1, C - 1.1]:
		_wall_box(d.geo, o, dir, a - 0.1, a + 0.1, 0.0, 4.6, &"painted_steel_yellow", true, 0.4, 0.05)  # bumpers / guides


func _window(d: ChunkData, x: int, z: int, s: int, o: Vector3, dir: int, full: bool) -> void:
	var r := _rng(x, z, s, 10 + dir)
	for a in [C / 3.0, C * 2.0 / 3.0]:
		_wall_box(d.geo, o, dir, a - 0.05, a + 0.05, 1.9, 4.5, &"rusted_metal", false, 0.1)
	_wall_box(d.geo, o, dir, 1.4, C - 1.4, 3.15, 3.25, &"rusted_metal", false, 0.1)
	for pane in 6:
		if r.randf() < 0.35:
			var a := 1.4 + (pane % 3) * (C - 2.8) / 3.0
			var y := 1.9 if pane < 3 else 3.25
			_wall_box(d.geo, o, dir, a + 0.06, a + (C - 2.8) / 3.0 - 0.06, y + 0.05, y + 1.2, &"glass_dirty", false, 0.02)
	if full and r.randf() < 0.3:
		var out := LevelLayout.dir_vector(dir)
		var c := o + Vector3(C * 0.5, 3.2, C * 0.5) + out * (C * 0.5)
		var target := c - out * 5.0 + Vector3.DOWN * 3.5
		d.lights.append({"type": "spot", "position": c + out * 6.0 + Vector3.UP * 3.0, "target": target,
			"color": Color(0.74, 0.8, 0.9), "energy": 9.0, "range": 26.0, "angle": 20.0, "shadow": true,
			"fog": 3.0})


# --- Ceilings and columns -----------------------------------------------------------------

func _ceiling(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone, flags: int,
		full: bool) -> void:
	var above := L.kind_at(x, z, s + 1)
	var above_zone := L.zone_at(x, z, s + 1)
	var need := above == LevelLayout.Kind.EMPTY or (above_zone != zn.id and above != LevelLayout.Kind.FLOOR
		and above != LevelLayout.Kind.CATWALK)
	if not need:
		return
	if flags & LevelLayout.ROOF_HOLE:
		var r := _rng(x, z, s, 6)
		var tilt := Basis.from_euler(Vector3(r.randf_range(0.6, 1.1), r.randf() * TAU, r.randf_range(-0.3, 0.3)))
		d.geo.box(o + Vector3(r.randf_range(1.0, 7.0), H - 1.2, r.randf_range(1.0, 7.0)), Vector3(3.5, 0.1, 2.0),
			&"corrugated_metal", &"metal", false, tilt)
		if full:
			var hole := o + Vector3(C * 0.5, H, C * 0.5)
			var sun := SUN_DIR.normalized()
			d.lights.append({"type": "spot", "position": hole - sun * 10.0, "target": hole + sun * 6.0,
				"color": Color(0.78, 0.83, 0.92), "energy": 14.0, "range": 45.0, "angle": 17.0,
				"shadow": true, "fog": 4.0})
		return
	_slab(d.geo, o, Rect2(0, 0, C, C), H, 0.3, st.ceiling_material, true)
	if zn.type in TALL:
		# Roof trusses
		d.geo.box(o + Vector3(C * 0.5, H - 0.7, C * 0.5), Vector3(C, 0.45, 0.22), &"painted_steel")
		d.geo.box(o + Vector3(C * 0.5, H - 0.42, 0.0), Vector3(C, 0.12, 0.12), &"rusted_metal")


func _column(d: ChunkData, x: int, z: int, zn: LevelLayout.Zone) -> void:
	var r := zn.rect
	if x == r.position.x or z == r.position.y or (x - r.position.x) % 2 != 0 or (z - r.position.y) % 2 != 0:
		return
	var height := (zn.top + 1) * H - 0.3
	var base := L.cell_origin(x, z, 0)
	d.geo.mesh(_ibeam, Transform3D(Basis.from_scale(Vector3(1, height, 1)), base))
	d.geo.box(base + Vector3(0, height * 0.5, 0), Vector3(0.32, height, 0.32), &"", &"metal")


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


# --- Dressing ---------------------------------------------------------------------------

func _prop(d: ChunkData, id: String, pos: Vector3, yaw: float, options: Dictionary = {}) -> int:
	var xform := Transform3D(Basis(Vector3.UP, yaw), pos)
	if FOOTPRINTS.has(id):
		var fp: Array = FOOTPRINTS[id]
		d.geo.nav_box(pos + Vector3.UP * float(fp[1]), fp[0], xform.basis)
	if d.geo.visuals:
		d.props.append([id, xform, options])
		return d.props.size() - 1
	return -1


func _wall_free(x: int, z: int, s: int, dir: int, wide_ok: bool = false) -> bool:
	if not L.has_wall(x, z, s, dir):
		return false
	if L.has_door(x, z, s, dir):
		var st := L.style_at(x, z, s)
		var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
		return wide_ok and _door_width(x, z, s, n, st) < 2.5
	return true


func _dressing(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone, flags: int) -> void:
	var r := _rng(x, z, s, 1)
	var stairs := flags & (LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) != 0
	if L.kind_at(x, z, s + 1) == LevelLayout.Kind.HOLE:
		_prop(d, "rubble", o + Vector3(C * 0.5, 0, C * 0.5), r.randf() * TAU)
	if r.randf() < st.pipe_chance:
		_pipes(d, x, z, s, o, st)
	if stairs:
		return
	var interior := true
	for dir in 4:
		var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
		if L.zone_at(n.x, n.y, s) != zn.id or L.kind_at(n.x, n.y, s) != LevelLayout.Kind.FLOOR or L.has_wall(x, z, s, dir) \
				or L.has_flag(n.x, n.y, s, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
			interior = false
	var center := o + Vector3(C * 0.5, 0, C * 0.5)
	match zn.type:
		&"warehouse":
			if s == 0:
				for side in [0, 2]:
					if L.has_door(x, z, s, side):
						continue
					var zz := 1.0 if side == 0 else C - 1.0
					for xx in [2.2, 5.8]:
						_prop(d, "shelf", o + Vector3(xx, 0, zz), 0.0 if side == 2 else PI)
				return
		&"hall":
			if interior:
				var roll := r.randf()
				if roll < 0.28:
					_prop(d, "machine_press", center, (PI * 0.5) * r.randi_range(0, 1))
				elif roll < 0.4:
					_prop(d, "tank", center, 0.0 if r.randf() < 0.5 else PI * 0.5)
				elif roll < 0.55:
					_prop(d, "conveyor", center, 0.0 if r.randf() < 0.5 else PI * 0.5)
				return
		&"loading_dock":
			if interior and r.randf() < 0.4:
				_prop(d, "shipping_container", center, (PI * 0.5) * r.randi_range(0, 1) + r.randf_range(-0.06, 0.06))
				return
		&"processing":
			if r.randf() < 0.3:
				var q := Vector3(2.1 if r.randf() < 0.5 else C - 2.1, 0, 2.1 if r.randf() < 0.5 else C - 2.1)
				_prop(d, "vat", o + q, r.randf() * TAU)
	# Wall-side props in the corners of the cell
	if st.props.is_empty():
		return
	for q in 4:
		if r.randf() > st.prop_density:
			continue
		var qx := q % 2
		var qz := q / 2
		var wall_z := 0 if qz == 0 else 2
		var wall_x := 3 if qx == 0 else 1
		var against := -1
		if _wall_free(x, z, s, wall_z):
			against = wall_z
		elif _wall_free(x, z, s, wall_x):
			against = wall_x
		if against < 0 and not interior:
			continue
		var id := _weighted(r, st.props)
		var fp: Array = FOOTPRINTS.get(id, [Vector3.ONE, 0.5])
		var size: Vector3 = fp[0]
		var local := Vector3(2.0 if qx == 0 else C - 2.0, 0, 2.0 if qz == 0 else C - 2.0)
		var yaw := r.randf() * TAU
		if against >= 0:
			var depth := size.z * 0.5 + T * 0.5 + 0.05
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
		_prop(d, id, o + local, yaw)
		# Stack a second crate now and then
		if id.begins_with("crate") and r.randf() < 0.3:
			_prop(d, "crate_small", o + local + Vector3.UP * size.y, r.randf() * TAU)


func _weighted(r: RandomNumberGenerator, table: Dictionary) -> String:
	var total := 0.0
	for k in table:
		total += float(table[k])
	var roll := r.randf() * total
	for k in table:
		roll -= float(table[k])
		if roll <= 0.0:
			return String(k)
	return String(table.keys().back())


## Overhead pipe runs along a consistent side so they join up cell to cell.
func _pipes(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle) -> void:
	var r := _rng(x, z, s, 2)
	var along_x := L.zone_at(x - 1, z, s) == L.zone_at(x, z, s) or L.zone_at(x + 1, z, s) == L.zone_at(x, z, s)
	if L.zone_at(x, z - 1, s) == L.zone_at(x, z, s) and L.zone_at(x, z + 1, s) == L.zone_at(x, z, s):
		along_x = false
	var specs := [[0.13, H - 0.55, 0.45], [0.08, H - 0.85, 0.75], [0.06, H - 1.15, 0.45]]
	for spec in specs:
		var radius: float = spec[0]
		var y: float = spec[1]
		var inset: float = spec[2]
		var a: Vector3
		var b: Vector3
		if along_x:
			a = o + Vector3(0, y, inset)
			b = o + Vector3(C, y, inset)
		else:
			a = o + Vector3(inset, y, 0)
			b = o + Vector3(inset, y, C)
		d.geo.cylinder(a, b, radius, &"rusted_metal", 10)
	for i in 3:
		var t := (i + 0.5) / 3.0
		var p := o + (Vector3(C * t, H - 0.35, 0.45) if along_x else Vector3(0.45, H - 0.35, C * t))
		d.geo.box(p + Vector3.DOWN * 0.4, Vector3(0.06, 0.9, 0.06), &"gun_metal")
	if r.randf() < st.leak_chance:
		var t := r.randf_range(0.2, 0.8)
		var drip := o + (Vector3(C * t, H - 0.7, 0.45) if along_x else Vector3(0.45, H - 0.7, C * t))
		d.leaks.append({"position": drip, "floor": o.y})
		d.decals.append(["puddle", Transform3D(Basis(Vector3.UP, r.randf() * TAU), Vector3(drip.x, o.y, drip.z)),
			Vector3(r.randf_range(1.4, 2.4), 0.3, r.randf_range(1.2, 2.0))])


# --- Lights -----------------------------------------------------------------------------

func _lights(d: ChunkData, x: int, z: int, s: int, o: Vector3, st: ZoneStyle, zn: LevelLayout.Zone, flags: int) -> void:
	var r := _rng(x, z, s, 3)
	if r.randf() > st.light_chance:
		return
	var working := r.randf() < st.light_working
	var flicker := working and r.randf() < st.flicker_chance
	match st.light_kind:
		&"cage":
			var dirs := [0, 1, 2, 3]
			var wall := -1
			for i in 4:
				var dir: int = dirs[(i + r.randi_range(0, 3)) % 4]
				if _wall_free(x, z, s, dir):
					wall = dir
					break
			var pos: Vector3
			var yaw := 0.0
			if wall >= 0:
				pos = L.wall_point(x, z, s, wall, 3.1, r.randf_range(-1.5, 1.5)) - LevelLayout.dir_vector(wall) * 0.0
				var inward := -LevelLayout.dir_vector(wall)
				yaw = atan2(inward.x, inward.z)
			else:
				pos = o + Vector3(C * 0.5, H - 0.4, C * 0.5)
			var prop := _prop(d, "cage_lamp", pos, yaw, {"dead": not working})
			if working:
				d.lights.append({"type": "omni", "position": pos + Basis(Vector3.UP, yaw) * Vector3(0, -0.1, 0.25),
					"color": st.light_color, "energy": st.light_energy, "range": 10.0, "shadow": r.randf() < 0.15,
					"flicker": 0.85 if flicker else 0.0, "prop": prop, "emissive": "Bulb", "fog": 1.2})
		&"fluorescent":
			var pos := o + Vector3(C * 0.5, H - 1.35, C * 0.5)
			var yaw := 0.0 if r.randf() < 0.5 else PI * 0.5
			var prop := _prop(d, "fluorescent", pos, yaw, {"dead": not working})
			if working:
				d.lights.append({"type": "omni", "position": pos + Vector3.DOWN * 0.25, "color": st.light_color,
					"energy": st.light_energy, "range": 10.0, "shadow": r.randf() < 0.25,
					"flicker": 0.9 if flicker else 0.0, "prop": prop, "emissive": "Tubes", "buzz": true, "fog": 1.0})
			if zn.type == &"processing" and r.randf() < 0.05:
				d.lights.append({"type": "omni", "position": L.wall_point(x, z, s, r.randi_range(0, 3), H - 1.0),
					"color": Color(1.0, 0.15, 0.08), "energy": 1.5, "range": 6.0, "pulse": true, "fog": 1.5})
		&"hanging":
			if s != 0 or (x + z) % 2 != 0:
				return
			var top := (zn.top + 1) * H
			var pos := o + Vector3(C * 0.5, top - 2.8, C * 0.5)
			var prop := _prop(d, "lamp_hanging", pos, 0.0, {"dead": not working})
			if working:
				d.lights.append({"type": "spot", "position": pos + Vector3.DOWN * 0.15, "target": pos + Vector3.DOWN * 10.0,
					"color": st.light_color, "energy": st.light_energy, "range": top + 4.0, "angle": 58.0,
					"shadow": r.randf() < 0.55, "flicker": 0.85 if flicker else 0.0, "prop": prop, "emissive": "Bulb",
					"fog": 1.4})
