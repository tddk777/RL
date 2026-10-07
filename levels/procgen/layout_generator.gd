class_name LayoutGenerator
extends RefCounted
## Builds a LevelLayout from a LevelProfile and a seed. Same seed, same level.
##
## The complex grows like a real site does: buildings are added one at a
## time next to ones already there, either built against them or joined by a
## covered walkway across open ground, so it ends up an irregular cluster with
## yards and gaps instead of a filled grid.
##
## Steps:
##  1. Districts: a few centres, each a family (factory, interior, storage).
##  2. Buildings: a loading dock on the edge of the site to start in, then
##     irregular buildings (rectangles with wings, notches and lower annexes)
##     grown from it, styled by the district they land in. Each joins its
##     parent wall to wall or through a walkway one to three cells long.
##  3. Courtyards in the gaps the buildings mostly enclose; a few bridges
##     between the upper floors of neighbouring buildings.
##  4. Fill buildings: tall spaces (halls with catwalk rings and bridges,
##     foundries, warehouses, docks) or storeyed blocks of rooms off a cramped
##     hallway (offices, maintenance, storage, processing).
##  5. Doors (along every join first), stairs, chamfered corners, windows,
##     partial walls, collapse.
##  6. Spawn in the dock; connect everything reachable from it.
##  7. Exits far away (open / hidden / locked), enemies, pickups, anomalies.

const FAMILIES: Array[StringName] = [&"factory", &"interior", &"storage"]
const TALL_TYPES: Array[StringName] = [&"hall", &"foundry", &"warehouse", &"loading_dock"]
const ROOM_TYPES: Array[StringName] = [&"office", &"maintenance", &"storage", &"processing"]
const FREE := -1
const WALKWAY := -2
const YARD := -3

var profile: LevelProfile
var L: LevelLayout
var rng := RandomNumberGenerator.new()
## Per column: FREE, WALKWAY, YARD or the index of a building.
var _occ := PackedInt32Array()
## Buildings: {zone, cols (Vector2i -> top), primary (Rect2i), tall, ring, proc_hall}
var _buildings: Array[Dictionary] = []
## Ground walkways: {cells: Array[Vector2i], fam}
var _walkways: Array[Dictionary] = []
## Doors to make: [Vector2i a, Vector2i b, storey]
var _links: Array = []
var _bridge_cells: Array = []  # [Vector2i, family]
var _yard_cells: Array[Vector2i] = []
var _district_centres: Array[Vector2] = []
var _district_family: Array[int] = []
var _hallways: Dictionary = {}  # zone id -> Dictionary of hallway columns
var _stairwells: Dictionary = {}  # zone id -> Vector2i column
var _connector_zone: Dictionary = {}  # Vector2i(storey, family) -> zone id


static func generate(p: LevelProfile, level_seed: int) -> LevelLayout:
	var g := LayoutGenerator.new()
	return g._run(p, level_seed)


func _run(p: LevelProfile, level_seed: int) -> LevelLayout:
	profile = p
	rng.seed = level_seed
	L = LevelLayout.new()
	L.setup(p, level_seed)
	_occ.resize(L.size.x * L.size.y)
	_occ.fill(FREE)
	_make_districts()
	_place_buildings()
	_make_yards()
	_make_air_bridges()
	for b in _buildings:
		_fill_building(b)
	_fill_walkways()
	_make_bridges()
	_link_doors()
	_make_stairs()
	_make_doors()
	_make_chamfers()
	_make_windows()
	_make_partials()
	_collapse()
	_choose_spawn()
	_connect_all()
	_compute_distances()
	_place_exits()
	_place_enemies()
	_place_pickups()
	_place_anomalies()
	return L


## Seeded Fisher-Yates (Array.shuffle() uses the global RNG).
func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


func _col(c: Vector2i) -> int:
	return c.y * L.size.x + c.x


func _in(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < L.size.x and c.y < L.size.y


func _occ_at(c: Vector2i) -> int:
	return _occ[_col(c)] if _in(c) else FREE


func _add_zone(type: StringName, style: ZoneStyle, rect: Rect2i, base: int, top: int, district: int) -> int:
	var z := LevelLayout.Zone.new()
	z.id = L.zones.size()
	z.type = type
	z.style = style
	z.rect = rect
	z.base = base
	z.top = top
	z.district = district
	L.zones.append(z)
	return z.id


func _add_room(zone_id: int, s: int, rect: Rect2i, use: StringName) -> LevelLayout.Room:
	var r := LevelLayout.Room.new()
	r.id = L.rooms.size() + 1
	r.zone = zone_id
	r.storey = s
	r.rect = rect
	r.use = use
	L.rooms.append(r)
	return r


func _put(x: int, z: int, s: int, kind: int, zone_id: int, room_id: int = 0) -> void:
	var i := L.idx(x, z, s)
	L.kind[i] = kind
	L.zone[i] = zone_id
	L.room[i] = room_id


# --- 1. Districts ------------------------------------------------------------------------

func _make_districts() -> void:
	var n := maxi(profile.districts, 1)
	var fams: Array = []
	for i in n:
		fams.append(i % FAMILIES.size())
	_shuffle(fams)
	var w := Vector2(L.size)
	_district_centres.append(Vector2(rng.randf_range(0.15, 0.85) * w.x, rng.randf_range(0.15, 0.85) * w.y))
	for i in range(1, n):
		var best := Vector2.ZERO
		var best_d := -1.0
		for k in 40:
			var c := Vector2(rng.randf_range(0.1, 0.9) * w.x, rng.randf_range(0.1, 0.9) * w.y)
			var d := INF
			for e in _district_centres:
				d = minf(d, c.distance_to(e))
			if d > best_d:
				best_d = d
				best = c
		_district_centres.append(best)
	for f in fams:
		_district_family.append(f)
	var phase := Vector2(rng.randf() * TAU, rng.randf() * TAU)
	for z in L.size.y:
		for x in L.size.x:
			# Wobbly borders: warp the point before finding the nearest centre.
			var p := Vector2(x + 0.5, z + 0.5)
			p += Vector2(sin(z * 0.45 + phase.x), cos(x * 0.45 + phase.y)) * 1.8
			var best := 0
			var best_d := INF
			for i in _district_centres.size():
				var d := p.distance_to(_district_centres[i])
				if d < best_d:
					best_d = d
					best = i
			L.district[z * L.size.x + x] = _district_family[best]


# --- 2. Buildings ------------------------------------------------------------------------

func _place_buildings() -> void:
	var target := int(L.size.x * L.size.y * profile.coverage)
	_place_first_dock()
	var covered := 0
	for b in _buildings:
		covered += (b["cols"] as Dictionary).size()
	var attempts := 0
	while covered < target and attempts < 1200 and _buildings.size() < profile.max_buildings:
		attempts += 1
		var added := _try_grow()
		if added > 0:
			covered += added


## The loading dock the player starts in, on one edge of the site.
func _place_first_dock() -> void:
	var style := profile.style_for(&"loading_dock")
	if style == null:
		style = profile.buildings[0]
	var side := rng.randi_range(0, 3)
	var long := rng.randi_range(3, 4)
	var deep := rng.randi_range(2, 3)
	var along_x := side % 2 == 0
	var w := long if along_x else deep
	var h := deep if along_x else long
	var pos := Vector2i.ZERO
	match side:
		0:
			pos = Vector2i(rng.randi_range(2, L.size.x - w - 2), 0)
		1:
			pos = Vector2i(L.size.x - w, rng.randi_range(2, L.size.y - h - 2))
		2:
			pos = Vector2i(rng.randi_range(2, L.size.x - w - 2), L.size.y - h)
		_:
			pos = Vector2i(0, rng.randi_range(2, L.size.y - h - 2))
	var cols := {}
	var top := clampi(rng.randi_range(style.extra_storeys.x, style.extra_storeys.y), 0, L.storeys - 1)
	for x in range(pos.x, pos.x + w):
		for z in range(pos.y, pos.y + h):
			cols[Vector2i(x, z)] = top
	_commit_building(style, cols, Rect2i(pos, Vector2i(w, h)), false)


## Adds a building beside a random existing one. Returns the cells it covers.
func _try_grow() -> int:
	var parent: Dictionary = _buildings[rng.randi_range(0, _buildings.size() - 1)]
	var options: Array = []
	for c: Vector2i in parent["cols"]:
		for d in 4:
			var n := c + LevelLayout.DIRS[d]
			if _in(n) and _occ_at(n) == FREE:
				options.append([c, d])
	if options.is_empty():
		return 0
	# Grow toward open ground so the complex spreads over the site.
	var weights: Array[float] = []
	var total := 0.0
	for o: Array in options:
		var ahead: Vector2i = (o[0] as Vector2i) + LevelLayout.DIRS[o[1]] * 3
		var free := 0
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var q := ahead + Vector2i(dx, dz)
				if _in(q) and _occ_at(q) == FREE:
					free += 1
		var w := float(free * free) + 1.0
		weights.append(w)
		total += w
	var roll := rng.randf() * total
	var pick: Array = options.back()
	for i in options.size():
		roll -= weights[i]
		if roll <= 0.0:
			pick = options[i]
			break
	var b: Vector2i = pick[0]
	var d: int = pick[1]
	var nv := LevelLayout.DIRS[d]
	var gap := 0 if rng.randf() < profile.touch_chance else rng.randi_range(1, profile.max_gap)
	var e := b + nv * (gap + 1)
	var probe := (e + nv * 2).clamp(Vector2i.ZERO, L.size - Vector2i.ONE)
	var fam := L.district_at(probe.x, probe.y)
	var style := _pick_style(fam)
	if style == null or (style.type == &"loading_dock" and rng.randf() < 0.6):
		return 0
	var shape := _make_shape(style)
	var cells: Dictionary = shape["cols"]
	var anchors: Array = []
	for c: Vector2i in cells:
		if not cells.has(c - nv):
			anchors.append(c)
	_shuffle(anchors)
	var abut := rng.randf() < profile.abut_chance
	for k in mini(anchors.size(), 5):
		var off: Vector2i = e - (anchors[k] as Vector2i)
		if not _fits(cells, off, b, d, gap, parent, abut):
			continue
		var placed := {}
		for c: Vector2i in cells:
			placed[c + off] = cells[c]
		var primary: Rect2i = shape["primary"]
		var idx := _commit_building(style, placed, Rect2i(primary.position + off, primary.size), shape["proc_hall"])
		if gap == 0:
			_links.append([b, e, 0])
		else:
			var walk: Array[Vector2i] = []
			for i in range(1, gap + 1):
				var w := b + nv * i
				walk.append(w)
				_occ[_col(w)] = WALKWAY
			_walkways.append({"cells": walk, "fam": L.district_at(walk[0].x, walk[0].y)})
			_links.append([b, walk[0], 0])
			_links.append([walk[walk.size() - 1], e, 0])
		return placed.size() + gap
	return 0


func _fits(cells: Dictionary, off: Vector2i, b: Vector2i, d: int, gap: int, parent: Dictionary, abut: bool) -> bool:
	var nv := LevelLayout.DIRS[d]
	var walk := {}
	for i in range(1, gap + 1):
		var w := b + nv * i
		if not _in(w) or _occ_at(w) != FREE:
			return false
		# Walkways cross open ground: nothing built alongside them.
		for side in [(d + 1) % 4, (d + 3) % 4]:
			var n := w + LevelLayout.DIRS[side]
			if _in(n) and _occ_at(n) != FREE:
				return false
		walk[w] = true
	var parent_cols: Dictionary = parent["cols"]
	for c: Vector2i in cells:
		var p := c + off
		if not _in(p) or _occ_at(p) != FREE or walk.has(p):
			return false
	for c: Vector2i in cells:
		var p := c + off
		for dd in 4:
			var n := p + LevelLayout.DIRS[dd]
			if cells.has(n - off) or not _in(n) or walk.has(n):
				continue
			var o := _occ_at(n)
			if o == FREE:
				continue
			if gap == 0 and parent_cols.has(n):
				continue
			if o >= 0 and abut:
				continue
			return false
	return true


func _commit_building(style: ZoneStyle, cols: Dictionary, primary: Rect2i, proc_hall: bool) -> int:
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := -lo
	var top := 0
	for c: Vector2i in cols:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		top = maxi(top, cols[c])
	var center := (lo + hi) / 2
	var fam := FAMILIES.find(style.family)
	if fam < 0:
		fam = L.district_at(center.x, center.y)
	var type := style.type
	var tall := type in TALL_TYPES or proc_hall
	if tall and top < 1 and type in [&"hall", &"foundry"] and L.storeys > 1:
		top = 1
		for c: Vector2i in cols:
			cols[c] = 1
	var id := _add_zone(type, style, Rect2i(lo, hi - lo + Vector2i.ONE), 0, top, fam)
	L.zones[id].cols = cols
	var index := _buildings.size()
	_buildings.append({"zone": id, "cols": cols, "primary": primary, "tall": tall,
		"ring": type == &"hall" or proc_hall, "proc_hall": proc_hall})
	for c: Vector2i in cols:
		_occ[_col(c)] = index
	return index


func _pick_style(fam: int) -> ZoneStyle:
	var options: Array[ZoneStyle] = []
	for s in profile.buildings:
		if s.family == FAMILIES[fam]:
			options.append(s)
	if options.is_empty():
		options = profile.buildings.duplicate()
	if options.is_empty():
		return null
	var total := 0.0
	for s in options:
		total += s.weight
	var roll := rng.randf() * total
	for s in options:
		roll -= s.weight
		if roll <= 0.0:
			return s
	return options.back()


## Footprint of a building of this style, in cells relative to its corner:
## a main block plus wings (L, T and U shapes), a notch now and then, and
## lower wings on storeyed buildings so the roofline steps.
func _make_shape(style: ZoneStyle) -> Dictionary:
	var t := style.type
	var top := clampi(rng.randi_range(style.extra_storeys.x, style.extra_storeys.y), 0, L.storeys - 1)
	var size := Vector2i(3, 2)
	var wings := 0
	match t:
		&"hall":
			size = Vector2i(rng.randi_range(4, 6), rng.randi_range(3, 4))
			wings = 1 if rng.randf() < 0.3 else 0
		&"foundry":
			size = Vector2i(rng.randi_range(3, 5), 3)
		&"warehouse":
			size = Vector2i(rng.randi_range(4, 6), rng.randi_range(3, 4))
			wings = 1 if rng.randf() < 0.25 else 0
		&"loading_dock":
			size = Vector2i(rng.randi_range(3, 4), rng.randi_range(2, 3))
		&"processing":
			size = Vector2i(rng.randi_range(3, 4), rng.randi_range(2, 3))
			wings = 1 if rng.randf() < 0.4 else 0
		&"office":
			size = Vector2i(rng.randi_range(3, 5), rng.randi_range(2, 3))
			wings = (1 if rng.randf() < 0.65 else 0) + (1 if rng.randf() < 0.3 else 0)
		_:
			size = Vector2i(rng.randi_range(2, 4), rng.randi_range(2, 3))
			wings = (1 if rng.randf() < 0.55 else 0) + (1 if rng.randf() < 0.15 else 0)
	if rng.randf() < 0.5:
		size = Vector2i(size.y, size.x)
	var proc_hall := t == &"processing" and size.x * size.y >= 9 and mini(size.x, size.y) >= 3 and rng.randf() < 0.5
	var tall := t in TALL_TYPES or proc_hall
	var cols := {}
	for x in size.x:
		for z in size.y:
			cols[Vector2i(x, z)] = top
	for i in wings:
		var side := rng.randi_range(0, 3)
		var length := rng.randi_range(1, 3)
		var depth := rng.randi_range(1, 2)
		var wing_top := top if tall else rng.randi_range(0, top)
		var along_n := size.x if side % 2 == 0 else size.y
		var start := rng.randi_range(-(length - 1), along_n - 1)
		for a in length:
			for k in depth:
				var c := Vector2i.ZERO
				match side:
					0:
						c = Vector2i(start + a, -1 - k)
					1:
						c = Vector2i(size.x + k, start + a)
					2:
						c = Vector2i(start + a, size.y + k)
					_:
						c = Vector2i(-1 - k, start + a)
				if not cols.has(c):
					cols[c] = wing_top
	# Notch a corner off the main block of a storeyed building.
	if not tall and size.x >= 3 and size.y >= 3 and rng.randf() < 0.3:
		var corner := [Vector2i(0, 0), Vector2i(size.x - 1, 0), Vector2i(0, size.y - 1), Vector2i(size.x - 1, size.y - 1)][rng.randi_range(0, 3)] as Vector2i
		var outward := 0
		for d in LevelLayout.DIRS:
			if cols.has(corner + d) and not Rect2i(Vector2i.ZERO, size).has_point(corner + d):
				outward += 1
		if outward == 0:
			cols.erase(corner)
	return {"cols": cols, "primary": Rect2i(Vector2i.ZERO, size), "proc_hall": proc_hall}


# --- 3. Courtyards and bridges -------------------------------------------------------------

## Open-air yards in gaps the buildings mostly enclose.
func _make_yards() -> void:
	var made := 0
	for attempt in profile.yards:
		var best: Rect2i
		var best_score := 0.0
		for z in L.size.y:
			for x in L.size.x:
				for w in range(2, 5):
					for h in range(2, 5):
						var r := Rect2i(x, z, w, h)
						var score := _yard_score(r)
						if score > 0.0:
							score *= rng.randf_range(0.85, 1.0)
							if score > best_score:
								best_score = score
								best = r
		if best_score <= 0.0:
			break
		for x in range(best.position.x, best.end.x):
			for z in range(best.position.y, best.end.y):
				_occ[_col(Vector2i(x, z))] = YARD
				_yard_cells.append(Vector2i(x, z))
		made += 1


func _yard_score(r: Rect2i) -> float:
	if r.end.x > L.size.x or r.end.y > L.size.y:
		return 0.0
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			if _occ_at(Vector2i(x, z)) != FREE:
				return 0.0
	var perimeter := 0
	var built := 0
	var near := {}
	for x in range(r.position.x - 1, r.end.x + 1):
		for z in range(r.position.y - 1, r.end.y + 1):
			var p := Vector2i(x, z)
			if r.has_point(p):
				continue
			var corner := (x < r.position.x or x >= r.end.x) and (z < r.position.y or z >= r.end.y)
			if corner:
				continue
			perimeter += 1
			var o := _occ_at(p)
			if o == WALKWAY or o == YARD:
				return 0.0  # keep yards off walkways and other yards
			if o >= 0:
				built += 1
				near[o] = true
	if near.size() < 2 and built < 5:
		return 0.0
	var enclosure := float(built) / perimeter
	if enclosure < 0.4:
		return 0.0
	return enclosure + r.get_area() * 0.02


## Bridges between the upper floors of two buildings across open ground.
func _make_air_bridges() -> void:
	var candidates: Array = []
	for bi in _buildings.size():
		var b: Dictionary = _buildings[bi]
		if b["tall"]:
			continue
		var cols: Dictionary = b["cols"]
		for c: Vector2i in cols:
			if cols[c] < 1:
				continue
			for d in 4:
				var nv := LevelLayout.DIRS[d]
				for g in range(1, 4):
					var ok := true
					for i in range(1, g + 1):
						var o := _occ_at(c + nv * i)
						if not _in(c + nv * i) or (o != FREE and o != YARD):
							ok = false
							break
					if not ok:
						break
					var m := c + nv * (g + 1)
					var o2 := _occ_at(m)
					if o2 < 0 or o2 == bi:
						continue
					var other: Dictionary = _buildings[o2]
					if other["tall"] or (other["cols"] as Dictionary).get(m, 0) < 1:
						continue
					candidates.append([c, d, g, m])
	_shuffle(candidates)
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[2] > b[2])
	var used := {}
	var made := 0
	for cand in candidates:
		if made >= profile.bridges:
			break
		var c: Vector2i = cand[0]
		var d: int = cand[1]
		var g: int = cand[2]
		var nv := LevelLayout.DIRS[d]
		var clash := false
		for i in range(0, g + 2):
			for dd in LevelLayout.DIRS:
				if used.has(c + nv * i + dd):
					clash = true
		if clash:
			continue
		for i in range(1, g + 1):
			var w := c + nv * i
			used[w] = true
			_bridge_cells.append([w, L.district_at(w.x, w.y)])
		_links.append([c, c + nv, 1])
		_links.append([c + nv * g, cand[3], 1])
		made += 1


# --- 4. Filling buildings ------------------------------------------------------------------

func _fill_building(b: Dictionary) -> void:
	var id: int = b["zone"]
	var zn := L.zones[id]
	var cols: Dictionary = b["cols"]
	if b["tall"]:
		_fill_tall(cols, id, zn.top, b["ring"])
		if zn.type == &"foundry":
			_deck(b, id, zn.top)
	elif zn.type == &"office" or zn.type == &"maintenance":
		_fill_rooms(b, 2, true)
	else:
		_fill_rooms(b, 3, rng.randf() < 0.5)


## Tall open space: floor at ground level, open air above. Rings put catwalk
## strips along every wall on the upper storeys.
func _fill_tall(cols: Dictionary, id: int, top: int, ring: bool) -> void:
	for c: Vector2i in cols:
		_put(c.x, c.y, 0, LevelLayout.Kind.FLOOR, id)
		for s in range(1, top + 1):
			_put(c.x, c.y, s, LevelLayout.Kind.VOID, id)
	if not ring or top < 1:
		return
	var ring_top := maxi(1, top - 1)
	for s in range(1, ring_top + 1):
		for c: Vector2i in cols:
			var sides := 0
			for d in 4:
				if not cols.has(c + LevelLayout.DIRS[d]):
					sides |= 1 << d
			if sides != 0:
				_put(c.x, c.y, s, LevelLayout.Kind.CATWALK, id)
				L.flags[L.idx(c.x, c.y, s)] |= sides << 4


## Foundry charging deck: a catwalk along one long wall of the main block.
func _deck(b: Dictionary, id: int, top: int) -> void:
	if top < 1:
		return
	var r: Rect2i = b["primary"]
	var cols: Dictionary = b["cols"]
	var side := (0 if rng.randf() < 0.5 else 2) if r.size.x >= r.size.y else (1 if rng.randf() < 0.5 else 3)
	for c: Vector2i in cols:
		if not r.has_point(c):
			continue
		var on := (side == 0 and c.y == r.position.y) or (side == 2 and c.y == r.end.y - 1) \
			or (side == 1 and c.x == r.end.x - 1) or (side == 3 and c.x == r.position.x)
		if on and not cols.has(c + LevelLayout.DIRS[side]):
			_put(c.x, c.y, 1, LevelLayout.Kind.CATWALK, id)
			L.flags[L.idx(c.x, c.y, 1)] |= (1 << side) << 4


## Storeyed building: a cramped hallway down the main block, rooms around it
## (split, some merged into L-shapes), wings as rooms, a stairwell column.
func _fill_rooms(b: Dictionary, max_size: int, hallway: bool) -> void:
	var id: int = b["zone"]
	var zn := L.zones[id]
	var cols: Dictionary = b["cols"]
	var r: Rect2i = b["primary"]
	var hall := {}
	var short := mini(r.size.x, r.size.y)
	if hallway and short >= 3 or (short >= 2 and maxi(r.size.x, r.size.y) >= 5):
		if r.size.x >= r.size.y:
			var row := r.position.y + rng.randi_range(1, maxi(r.size.y - 2, 1)) if r.size.y >= 3 else r.position.y + rng.randi_range(0, 1)
			for x in range(r.position.x, r.end.x):
				if cols.has(Vector2i(x, row)):
					hall[Vector2i(x, row)] = true
		else:
			var col := r.position.x + rng.randi_range(1, maxi(r.size.x - 2, 1)) if r.size.x >= 3 else r.position.x + rng.randi_range(0, 1)
			for z in range(r.position.y, r.end.y):
				if cols.has(Vector2i(col, z)):
					hall[Vector2i(col, z)] = true
	_hallways[id] = hall
	var well := Vector2i(-1, -1)
	if zn.top >= 1:
		well = _pick_stairwell(b, hall)
		if well.x >= 0:
			_stairwells[id] = well
	for s in range(0, zn.top + 1):
		var cells := {}
		for c: Vector2i in cols:
			if cols[c] >= s:
				cells[c] = true
		var hall_cells: Array[Vector2i] = []
		for c: Vector2i in hall:
			if cells.has(c):
				hall_cells.append(c)
		if not hall_cells.is_empty():
			var lo := hall_cells[0]
			var hi := hall_cells[0]
			for c in hall_cells:
				lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
				hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
			var hroom := _add_room(id, s, Rect2i(lo, hi - lo + Vector2i.ONE), &"hallway")
			for c in hall_cells:
				_put(c.x, c.y, s, LevelLayout.Kind.FLOOR, id, hroom.id)
				L.flags[L.idx(c.x, c.y, s)] |= LevelLayout.NARROW
				cells.erase(c)
		if well.x >= 0 and cells.has(well):
			var sw := _add_room(id, s, Rect2i(well, Vector2i.ONE), &"stairwell")
			_put(well.x, well.y, s, LevelLayout.Kind.FLOOR, id, sw.id)
			cells.erase(well)
		var made: Array[LevelLayout.Room] = []
		for rect in _rects_of(cells):
			var parts: Array[Rect2i] = []
			_split_rooms(rect, parts, max_size)
			for rr in parts:
				var room := _add_room(id, s, rr, &"")
				made.append(room)
				for x in range(rr.position.x, rr.end.x):
					for z in range(rr.position.y, rr.end.y):
						_put(x, z, s, LevelLayout.Kind.FLOOR, id, room.id)
		_merge_rooms(made, s)
		for room in made:
			if room.use == &"":
				room.use = _room_use(zn.type, room)


## Splits a set of cells into rectangles (greedy row runs).
func _rects_of(cells: Dictionary) -> Array[Rect2i]:
	var left := cells.duplicate()
	var out: Array[Rect2i] = []
	var keys := left.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for k: Vector2i in keys:
		if not left.has(k):
			continue
		var w := 1
		while left.has(k + Vector2i(w, 0)):
			w += 1
		var h := 1
		var grow := true
		while grow:
			for i in w:
				if not left.has(k + Vector2i(i, h)):
					grow = false
					break
			if grow:
				h += 1
		for i in w:
			for j in h:
				left.erase(k + Vector2i(i, j))
		out.append(Rect2i(k, Vector2i(w, h)))
	return out


func _pick_stairwell(b: Dictionary, hall: Dictionary) -> Vector2i:
	var r: Rect2i = b["primary"]
	var cols: Dictionary = b["cols"]
	var zn := L.zones[b["zone"]]
	var options: Array[Vector2i] = []
	for c: Vector2i in cols:
		if not r.has_point(c) or hall.has(c) or cols[c] < zn.top:
			continue
		var ok := hall.is_empty()
		for d in LevelLayout.DIRS:
			if hall.has(c + d):
				ok = true
		if ok:
			options.append(c)
	if options.is_empty():
		return Vector2i(-1, -1)
	return options[rng.randi_range(0, options.size() - 1)]


func _split_rooms(r: Rect2i, out: Array[Rect2i], max_size: int) -> void:
	var can_x := r.size.x >= 2
	var can_z := r.size.y >= 2
	var too_big := r.size.x > max_size or r.size.y > max_size
	if not (can_x or can_z) or (not too_big and rng.randf() < 0.5):
		out.append(r)
		return
	var along_x := (r.size.x >= r.size.y) if can_x and can_z else can_x
	if along_x:
		var c := rng.randi_range(r.position.x + 1, r.end.x - 1)
		_split_rooms(Rect2i(r.position.x, r.position.y, c - r.position.x, r.size.y), out, max_size)
		_split_rooms(Rect2i(c, r.position.y, r.end.x - c, r.size.y), out, max_size)
	else:
		var c := rng.randi_range(r.position.y + 1, r.end.y - 1)
		_split_rooms(Rect2i(r.position.x, r.position.y, r.size.x, c - r.position.y), out, max_size)
		_split_rooms(Rect2i(r.position.x, c, r.size.x, r.end.y - c), out, max_size)


## Now and then two touching rooms become one L-shaped (or longer) room.
func _merge_rooms(made: Array[LevelLayout.Room], s: int) -> void:
	for a in made:
		if a.extra.size() > 0 or rng.randf() > 0.35:
			continue
		for b in made:
			if b == a or b.extra.size() > 0 or b.use == &"merged" or not _touching(a.rect, b.rect):
				continue
			if L.room[L.idx(b.rect.position.x, b.rect.position.y, s)] != b.id:
				continue
			a.extra.append(b.rect)
			for x in range(b.rect.position.x, b.rect.end.x):
				for z in range(b.rect.position.y, b.rect.end.y):
					L.room[L.idx(x, z, s)] = a.id
			b.use = &"merged"
			break


func _touching(a: Rect2i, b: Rect2i) -> bool:
	return ((a.end.x == b.position.x or b.end.x == a.position.x) and a.position.y < b.end.y and b.position.y < a.end.y) \
		or ((a.end.y == b.position.y or b.end.y == a.position.y) and a.position.x < b.end.x and b.position.x < a.end.x)


func _room_use(type: StringName, room: LevelLayout.Room) -> StringName:
	var area := room.rect.get_area()
	for e in room.extra:
		area += e.get_area()
	var pick := func(options: Array) -> StringName:
		return options[rng.randi_range(0, options.size() - 1)]
	match type:
		&"office":
			if area >= 6:
				return &"cubicles"
			if area >= 3:
				return pick.call([&"cubicles", &"cubicles", &"meeting", &"offices"])
			if area == 2:
				return pick.call([&"offices", &"meeting", &"archive", &"cubicles"])
			return pick.call([&"offices", &"archive", &"offices"])
		&"maintenance":
			if area >= 2:
				return pick.call([&"boiler", &"electrical", &"lockers", &"workshop", &"washroom", &"boiler"])
			return pick.call([&"closet", &"electrical", &"washroom", &"lockers"])
		&"storage":
			return pick.call([&"parts", &"cages", &"parts", &"workshop"] if area >= 2 else [&"parts", &"cages", &"closet"])
		&"processing":
			return pick.call([&"vats", &"pumps", &"vats", &"lab"])
	return &"empty"


## Covered walkways across open ground, bridges between upper floors, yards.
func _fill_walkways() -> void:
	for w in _walkways:
		for c: Vector2i in w["cells"]:
			_put_connector(c, 0, w["fam"])
	for bc in _bridge_cells:
		_put_connector(bc[0], 1, bc[1])
	if not _yard_cells.is_empty() and profile.yard:
		var lo := _yard_cells[0]
		var hi := _yard_cells[0]
		for c in _yard_cells:
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
			hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		var id := _add_zone(&"yard", profile.yard, Rect2i(lo, hi - lo + Vector2i.ONE), 0, 0, L.district_at(lo.x, lo.y))
		for c in _yard_cells:
			_put(c.x, c.y, 0, LevelLayout.Kind.FLOOR, id)
			L.zones[id].cols[c] = 0


func _put_connector(c: Vector2i, s: int, fam: int) -> void:
	var key := Vector2i(s, fam)
	if not _connector_zone.has(key):
		var style := profile.corridor_for(FAMILIES[fam])
		_connector_zone[key] = _add_zone(&"connector", style, Rect2i(Vector2i.ZERO, L.size), s, s, fam)
	_put(c.x, c.y, s, LevelLayout.Kind.FLOOR, _connector_zone[key])
	L.flags[L.idx(c.x, c.y, s)] |= LevelLayout.NARROW
	L.zones[_connector_zone[key]].cols[c] = s


## Catwalk bridges across the middle of factory halls.
func _make_bridges() -> void:
	for b in _buildings:
		var zn := L.zones[b["zone"]]
		if zn.type != &"hall" or zn.top < 1:
			continue
		var r: Rect2i = b["primary"]
		var axes: Array[int] = []
		if r.size.x >= 5:
			axes.append(0)
		if r.size.y >= 5 and (axes.is_empty() or rng.randf() < 0.4):
			axes.append(1)
		for axis in axes:
			if axis == 0:
				var z := r.position.y + r.size.y / 2
				for x in range(r.position.x, r.end.x):
					_bridge_cell(x, z, LevelLayout.BRIDGE_X, zn.id)
			else:
				var x := r.position.x + r.size.x / 2
				for z in range(r.position.y, r.end.y):
					_bridge_cell(x, z, LevelLayout.BRIDGE_Z, zn.id)


func _bridge_cell(x: int, z: int, flag: int, zone_id: int) -> void:
	var i := L.idx(x, z, 1)
	if L.zone[i] != zone_id:
		return
	if L.kind[i] == LevelLayout.Kind.VOID:
		L.kind[i] = LevelLayout.Kind.CATWALK
	if L.kind[i] == LevelLayout.Kind.CATWALK:
		L.flags[i] |= flag


# --- 5. Doors, stairs, corners, windows -------------------------------------------------------

func _door(x: int, z: int, s: int, dir: int) -> void:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	L.set_flag(x, z, s, LevelLayout.DOOR << dir)
	L.set_flag(n.x, n.y, s, LevelLayout.DOOR << ((dir + 2) % 4))


## A door can go here: walls on both sides of the edge belong to walkable cells,
## a catwalk only opens on its own strip side and stair strips stay closed.
func _door_ok(x: int, z: int, s: int, dir: int) -> bool:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	if not (L.is_walkable(x, z, s) and L.is_walkable(n.x, n.y, s)):
		return false
	for c in [[x, z, dir], [n.x, n.y, (dir + 2) % 4]]:
		var k := L.kind_at(c[0], c[1], s)
		if k == LevelLayout.Kind.CATWALK and not ((L.flags_at(c[0], c[1], s) >> 4) & (1 << c[2])):
			return false
		if L.stair_sides(c[0], c[1], s) & (1 << c[2]):
			return false
		if L.has_window(c[0], c[1], s, c[2]):
			return false
	return L.has_wall(x, z, s, dir)


func _dir_between(a: Vector2i, b: Vector2i) -> int:
	for d in 4:
		if a + LevelLayout.DIRS[d] == b:
			return d
	return -1


## Doors along every join: building to building, building to walkway or bridge.
func _link_doors() -> void:
	for link in _links:
		var a: Vector2i = link[0]
		var b: Vector2i = link[1]
		var s: int = link[2]
		var d := _dir_between(a, b)
		if d < 0:
			continue
		if _door_ok(a.x, a.y, s, d):
			_door(a.x, a.y, s, d)
			continue
		# Wall to wall: try elsewhere along the shared wall.
		var za := L.zone_at(a.x, a.y, s)
		var zb := L.zone_at(b.x, b.y, s)
		var options: Array = []
		var cols: Dictionary = L.zones[za].cols if za >= 0 else {}
		for c: Vector2i in cols:
			for dd in 4:
				var n := c + LevelLayout.DIRS[dd]
				if L.zone_at(n.x, n.y, s) == zb and _door_ok(c.x, c.y, s, dd):
					options.append([c, dd])
		if not options.is_empty():
			var o: Array = options[rng.randi_range(0, options.size() - 1)]
			_door(o[0].x, o[0].y, s, o[1])


## A flight in (x, z, s) along `side`, climbing toward `dir`, landing in the
## same column one storey up.
func _place_stair(x: int, z: int, s: int, dir: int, side: int) -> bool:
	if not L.inside(x, z, s + 1):
		return false
	var i := L.idx(x, z, s)
	var a := L.idx(x, z, s + 1)
	if L.flags[i] & LevelLayout.STAIR or L.flags[a] & LevelLayout.STAIR_ABOVE:
		return false
	if L.flags[i] & LevelLayout.STAIR_ABOVE and L.hole_side(x, z, s) == side:
		return false
	if L.flags[a] & LevelLayout.STAIR and L.stair_side(x, z, s + 1) == side:
		return false
	if L.has_door(x, z, s, side) or L.has_door(x, z, s + 1, side):
		return false
	var above := L.kind[a]
	if above == LevelLayout.Kind.CATWALK:
		if not ((L.flags[a] >> 4) & (1 << side)):
			return false
	elif above != LevelLayout.Kind.FLOOR:
		return false
	var code := dir | (side << 2)
	L.flags[i] |= LevelLayout.STAIR
	L.stair[i] = (L.stair[i] & 0xF0) | code
	L.flags[a] |= LevelLayout.STAIR_ABOVE
	L.stair[a] = (L.stair[a] & 0x0F) | (code << 4)
	return true


func _make_stairs() -> void:
	for b in _buildings:
		var zn := L.zones[b["zone"]]
		if _stairwells.has(zn.id):
			_stairwell(zn, _stairwells[zn.id])
		elif b["tall"] and (b["ring"] or zn.type == &"foundry"):
			_catwalk_stairs(zn)


## Switchback stairwell in one cell: flights alternate sides and directions,
## each landing at the end where the next one starts.
func _stairwell(z: LevelLayout.Zone, c: Vector2i) -> void:
	var hall: Dictionary = _hallways.get(z.id, {})
	# Strips run along the two lateral walls, so doors can only be on the
	# ends: climb along the axis that points at the hallway (or, without
	# one, at the rest of the building).
	var dir := -1
	for d in 4:
		if hall.has(c + LevelLayout.DIRS[d]):
			dir = d
	if dir < 0:
		for d in 4:
			if z.cols.has(c + LevelLayout.DIRS[d]):
				dir = d
				break
	if dir < 0:
		return
	var sides := [(dir + 1) % 4, (dir + 3) % 4]
	for s in range(0, z.top):
		var d := dir if s % 2 == 0 else (dir + 2) % 4
		_place_stair(c.x, c.y, s, d, sides[s % 2])


## Stairs from the floor up to a catwalk strip along a wall; the landing joins
## the next strip cell along the same wall.
func _catwalk_stairs(z: LevelLayout.Zone) -> void:
	for s in range(1, z.top + 1):
		var candidates: Array = []
		for c: Vector2i in z.cols:
			var x := c.x
			var zz := c.y
			if L.kind_at(x, zz, s) != LevelLayout.Kind.CATWALK or L.has_flag(x, zz, s, LevelLayout.BRIDGE_X | LevelLayout.BRIDGE_Z):
				continue
			var sides := (L.flags_at(x, zz, s) >> 4) & 15
			if L.kind_at(x, zz, s - 1) != LevelLayout.Kind.FLOOR:
				continue
			for wall in 4:
				if sides != (1 << wall):
					continue
				for d in [(wall + 1) % 4, (wall + 3) % 4]:
					var t := Vector2i(x, zz) + LevelLayout.DIRS[d]
					if L.kind_at(t.x, t.y, s) == LevelLayout.Kind.CATWALK and (L.flags_at(t.x, t.y, s) >> 4) & (1 << wall) \
							and not L.has_flag(t.x, t.y, s, LevelLayout.STAIR_ABOVE):
						candidates.append([x, zz, d, wall])
		if candidates.is_empty():
			continue
		var count := 2 if candidates.size() > 10 else 1
		_shuffle(candidates)
		var placed: Array[Vector2i] = []
		for c in candidates:
			var p := Vector2i(c[0], c[1])
			var close := false
			for q in placed:
				if p.distance_to(q) < 3.0:
					close = true
			if close:
				continue
			if _place_stair(c[0], c[1], s - 1, c[2], c[3]):
				placed.append(p)
				if placed.size() >= count:
					break


func _make_doors() -> void:
	for zn in L.zones:
		if zn.type in [&"connector", &"yard"]:
			continue
		for s in range(zn.base, zn.top + 1):
			# Into yards: one or two doors per building facing one.
			var to_yard: Array = []
			var to_other: Dictionary = {}  # neighbour zone -> edges
			for c: Vector2i in zn.cols:
				if L.zone_at(c.x, c.y, s) != zn.id:
					continue
				for d in 4:
					var n := c + LevelLayout.DIRS[d]
					var nz := L.zone_of(n.x, n.y, s)
					if nz == null or nz.id == zn.id or not _door_ok(c.x, c.y, s, d):
						continue
					if nz.type == &"yard":
						to_yard.append([c, d])
					elif nz.type != &"connector":
						if not to_other.has(nz.id):
							to_other[nz.id] = []
						to_other[nz.id].append([c, d])
			if not to_yard.is_empty() and not _has_door_to(zn, s, &"yard"):
				_shuffle(to_yard)
				for i in mini(1 + (1 if to_yard.size() >= 4 and rng.randf() < 0.5 else 0), to_yard.size()):
					_door(to_yard[i][0].x, to_yard[i][0].y, s, to_yard[i][1])
			# Buildings built against each other: now and then another way through.
			for other: int in to_other:
				var edges: Array = to_other[other]
				if rng.randf() < (0.35 if s == 0 else 0.5):
					var e: Array = edges[rng.randi_range(0, edges.size() - 1)]
					_door(e[0].x, e[0].y, s, e[1])
			_room_doors(zn, s)


func _has_door_to(zn: LevelLayout.Zone, s: int, type: StringName) -> bool:
	for c: Vector2i in zn.cols:
		for d in 4:
			if L.has_door(c.x, c.y, s, d) and L.zone_name(c.x + LevelLayout.DIRS[d].x, c.y + LevelLayout.DIRS[d].y, s) == String(type):
				return true
	return false


## Every room off the hallway gets a door to it; the rest join through a
## spanning tree of doors between rooms, plus a few loops.
func _room_doors(zn: LevelLayout.Zone, s: int) -> void:
	var pairs := {}  # "a:b" -> Array of [x, z, dir]
	for c: Vector2i in zn.cols:
		for d in [1, 2]:
			var n := c + LevelLayout.DIRS[d]
			if L.zone_at(n.x, n.y, s) != zn.id or L.zone_at(c.x, c.y, s) != zn.id:
				continue
			var a := L.room[L.idx(c.x, c.y, s)]
			var b := L.room[L.idx(n.x, n.y, s)]
			if a == b or not _door_ok(c.x, c.y, s, d):
				continue
			var key := "%d:%d" % [mini(a, b), maxi(a, b)]
			if not pairs.has(key):
				pairs[key] = []
			pairs[key].append([c.x, c.y, d])
	var parent := {}
	var find := func(a: int) -> int:
		while parent.get(a, a) != a:
			a = parent[a]
		return a
	var keys := pairs.keys()
	_shuffle(keys)
	keys.sort_custom(func(a: String, b: String) -> bool: return _is_hall_pair(a) and not _is_hall_pair(b))
	for key: String in keys:
		var ab := key.split(":")
		var ra: int = find.call(int(ab[0]))
		var rb: int = find.call(int(ab[1]))
		var spots: Array = pairs[key]
		var spot: Array = spots[rng.randi_range(0, spots.size() - 1)]
		if ra != rb:
			parent[ra] = rb
			_door(spot[0], spot[1], s, spot[2])
		elif rng.randf() < 0.15:
			_door(spot[0], spot[1], s, spot[2])


func _is_hall_pair(key: String) -> bool:
	for part in key.split(":"):
		var id := int(part)
		if id > 0 and L.rooms[id - 1].use in [&"hallway", &"stairwell"]:
			return true
	return false


## 45-degree cuts across some outer corners of buildings, through every storey.
func _make_chamfers() -> void:
	for b in _buildings:
		var zn := L.zones[b["zone"]]
		if zn.type == &"loading_dock":
			continue
		var cols: Dictionary = b["cols"]
		for c: Vector2i in cols:
			var options: Array[int] = []
			for corner in 4:
				var dirs: Array = LevelLayout.CORNER_DIRS[corner]
				var diag: Vector2i = c + LevelLayout.DIRS[dirs[0]] + LevelLayout.DIRS[dirs[1]]
				var ok := true
				for s in range(0, cols[c] + 1):
					var k := L.kind_at(c.x, c.y, s)
					if (k != LevelLayout.Kind.FLOOR and k != LevelLayout.Kind.VOID) \
							or L.has_flag(c.x, c.y, s, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE | LevelLayout.NARROW | LevelLayout.DOCK) \
							or not L.is_outside(c.x, c.y, s, dirs[0]) or not L.is_outside(c.x, c.y, s, dirs[1]) \
							or L.is_enclosed(diag.x, diag.y, s) or L.has_door(c.x, c.y, s, dirs[0]) and L.has_door(c.x, c.y, s, dirs[1]):
						ok = false
						break
					var rm := L.room_of(c.x, c.y, s)
					if rm and rm.use == &"stairwell":
						ok = false
						break
				for s in range(cols[c] + 1, L.storeys):
					if L.is_enclosed(c.x, c.y, s):
						ok = false
				if ok:
					options.append(corner)
			if options.is_empty() or rng.randf() > profile.chamfer_chance:
				continue
			var corner: int = options[rng.randi_range(0, options.size() - 1)]
			for s in range(0, cols[c] + 1):
				L.set_flag(c.x, c.y, s, LevelLayout.CHAMFER << corner)


## Windows: every outer wall of a tall space (full height, both storeys),
## many outer walls of rooms, hallway ends, walls onto yards; glass
## partitions between offices and onto the factory floor.
func _make_windows() -> void:
	var tall := {}
	for b in _buildings:
		if b["tall"]:
			tall[b["zone"]] = true
	for zn in L.zones:
		if not tall.has(zn.id):
			continue
		for c: Vector2i in zn.cols:
			for d in 4:
				if not L.is_outside(c.x, c.y, 0, d) or (L.has_flag(c.x, c.y, 0, LevelLayout.DOCK)) or rng.randf() > 0.8:
					continue
				for s in range(0, zn.top + 1):
					if L.zone_at(c.x, c.y, s) == zn.id and L.is_outside(c.x, c.y, s, d) and not L.has_door(c.x, c.y, s, d) \
							and not (L.stair_sides(c.x, c.y, s) & (1 << d)):
						L.set_flag(c.x, c.y, s, LevelLayout.WINDOW << d)
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if not L.is_walkable(x, z, s):
					continue
				var a := L.zone_of(x, z, s)
				if a == null or a.type == &"connector":
					continue
				for d in 4:
					if L.has_door(x, z, s, d) or L.has_window(x, z, s, d) or L.stair_sides(x, z, s) & (1 << d):
						continue
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					if L.is_outside(x, z, s, d):
						if tall.has(a.id) or a.type == &"yard" or (L.has_flag(x, z, s, LevelLayout.DOCK) and s == 0):
							continue
						var chance := 0.65 if L.has_flag(x, z, s, LevelLayout.NARROW) else 0.5
						if rng.randf() < chance:
							L.set_flag(x, z, s, LevelLayout.WINDOW << d)
						continue
					if d != 1 and d != 2:
						continue
					if not L.is_enclosed(n.x, n.y, s) or not L.has_wall(x, z, s, d):
						continue
					if L.has_flag(x, z, s, LevelLayout.NARROW) or L.has_flag(n.x, n.y, s, LevelLayout.NARROW):
						continue
					if L.stair_sides(n.x, n.y, s) & (1 << ((d + 2) % 4)) or L.has_door(n.x, n.y, s, (d + 2) % 4):
						continue
					var b := L.zone_of(n.x, n.y, s)
					if b == null or b.type == &"connector":
						continue
					var chance := 0.0
					var a_open := a.type in TALL_TYPES or L.room_at(x, z, s) == 0
					var b_open := b.type in TALL_TYPES or L.room_at(n.x, n.y, s) == 0
					if a.type == &"yard" or b.type == &"yard":
						chance = 0.55
					elif (a.type in ROOM_TYPES and b_open) or (b.type in ROOM_TYPES and a_open):
						chance = 0.45
					elif a == b and a.type == &"office":
						chance = 0.15
					if L.kind_at(x, z, s) == LevelLayout.Kind.CATWALK or L.kind_at(n.x, n.y, s) == LevelLayout.Kind.CATWALK:
						chance *= 0.5
					if chance > 0.0 and rng.randf() < chance:
						L.set_flag(x, z, s, LevelLayout.WINDOW << d)
						L.set_flag(n.x, n.y, s, LevelLayout.WINDOW << ((d + 2) % 4))


## Stubs of wall inside bigger rooms and halls, so spaces aren't plain boxes.
func _make_partials() -> void:
	var per_room := {}
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if L.kind_at(x, z, s) != LevelLayout.Kind.FLOOR or L.has_flag(x, z, s, LevelLayout.NARROW):
					continue
				var zn := L.zone_of(x, z, s)
				if zn == null or zn.type in [&"connector", &"yard", &"loading_dock"]:
					continue
				for d in [1, 2]:
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					if L.kind_at(n.x, n.y, s) != LevelLayout.Kind.FLOOR or L.has_wall(x, z, s, d) \
							or L.has_flag(n.x, n.y, s, LevelLayout.NARROW):
						continue
					if L.stair_sides(x, z, s) or L.stair_sides(n.x, n.y, s):
						continue
					var key := L.room_at(x, z, s) if L.room_at(x, z, s) > 0 else -zn.id - 1
					var chance := profile.partial_chance if L.room_at(x, z, s) > 0 else profile.partial_chance * 0.25
					if per_room.get(key, 0) >= (1 if L.room_at(x, z, s) > 0 else 2) or rng.randf() > chance:
						continue
					per_room[key] = per_room.get(key, 0) + 1
					L.set_flag(x, z, s, LevelLayout.PARTIAL << d)
					L.set_flag(n.x, n.y, s, LevelLayout.PARTIAL << ((d + 2) % 4))


# --- 5b. Collapse ------------------------------------------------------------------------

func _collapse() -> void:
	for x in L.size.x:
		for z in L.size.y:
			for s in L.storeys:
				var i := L.idx(x, z, s)
				var zn := L.zone_of(x, z, s)
				if zn == null or zn.type in [&"yard", &"connector"]:
					continue
				var style := zn.style
				# Roof holes at the top of tall spaces and top floors.
				var above := L.kind_at(x, z, s + 1)
				if above == LevelLayout.Kind.EMPTY and style.roof_hole_chance > 0.0 and rng.randf() < style.roof_hole_chance \
						and L.kind[i] != LevelLayout.Kind.CATWALK and not (L.flags[i] & LevelLayout.NARROW) and not _has_any_chamfer(x, z, s):
					L.flags[i] |= LevelLayout.ROOF_HOLE
				# Floors fallen through onto the storey below.
				if s >= 1 and L.kind[i] == LevelLayout.Kind.FLOOR and style.collapse_chance > 0.0 \
						and rng.randf() < style.collapse_chance and L.flags[i] & (LevelLayout.STAIR | LevelLayout.STAIR_ABOVE | LevelLayout.NARROW) == 0 \
						and L.kind_at(x, z, s - 1) == LevelLayout.Kind.FLOOR \
						and not L.has_flag(x, z, s - 1, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE | LevelLayout.NARROW) \
						and not _near_stair(x, z, s) and L.room_of(x, z, s) and L.room_of(x, z, s).use != &"stairwell" \
						and not _has_any_chamfer(x, z, s):
					L.kind[i] = LevelLayout.Kind.HOLE


func _has_any_chamfer(x: int, z: int, s: int) -> bool:
	return L.flags_at(x, z, s) & (15 * LevelLayout.CHAMFER) != 0


func _near_stair(x: int, z: int, s: int) -> bool:
	for d in LevelLayout.DIRS:
		var n := Vector2i(x, z) + d
		for ss in [s - 1, s]:
			if L.has_flag(n.x, n.y, ss, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
				return true
	return false


# --- 6. Spawn and connectivity --------------------------------------------------------------

func _choose_spawn() -> void:
	var docks: Array = []
	for zn in L.zones:
		if zn.type == &"loading_dock":
			docks.append(zn)
	for zn in docks:
		for c: Vector2i in zn.cols:
			for d in 4:
				if L.is_outside(c.x, c.y, 0, d) and not L.has_door(c.x, c.y, 0, d):
					L.set_flag(c.x, c.y, 0, LevelLayout.DOCK)
					L.set_flag(c.x, c.y, 0, LevelLayout.WINDOW << d, false)
	var start: LevelLayout.Zone = docks[0] if not docks.is_empty() else null
	var cell := Vector2i(L.size.x / 2, L.size.y / 2)
	var inward := 0
	if start:
		var options: Array = []
		for c: Vector2i in start.cols:
			for d in 4:
				if L.is_outside(c.x, c.y, 0, d) and not L.has_door(c.x, c.y, 0, d):
					options.append([c.x, c.y, (d + 2) % 4])
		if not options.is_empty():
			var o: Array = options[rng.randi_range(0, options.size() - 1)]
			cell = Vector2i(o[0], o[1])
			inward = o[2]
	else:
		for zn in L.zones:
			if not zn.cols.is_empty() and zn.type != &"connector":
				cell = zn.cols.keys()[0]
				break
	L.spawn_cell = Vector3i(cell.x, cell.y, 0)
	L.spawn_position = L.cell_center(cell.x, cell.y, 0) - LevelLayout.dir_vector(inward) * 1.5 + Vector3.UP * 0.05
	var f := LevelLayout.dir_vector(inward)
	L.spawn_yaw = atan2(-f.x, -f.z)


func _bfs(from: Vector3i) -> Dictionary:
	var seen := {from: 0}
	var queue: Array[Vector3i] = [from]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for n in L.links(c.x, c.y, c.z):
			if not seen.has(n):
				seen[n] = seen[c] + 1
				queue.append(n)
	return seen


## Opens doors until everything walkable is reachable from the spawn;
## whatever still can't be reached is sealed off.
func _connect_all() -> void:
	for attempt in 60:
		var reached := _bfs(L.spawn_cell)
		var added := 0
		for s in L.storeys:
			for x in L.size.x:
				for z in L.size.y:
					var c := Vector3i(x, z, s)
					if reached.has(c) or not L.is_walkable(x, z, s):
						continue
					for d in 4:
						var n := Vector2i(x, z) + LevelLayout.DIRS[d]
						if reached.has(Vector3i(n.x, n.y, s)) and _door_ok(x, z, s, d) and not L.has_door(x, z, s, d):
							if L.has_partial(x, z, s, d):
								continue
							_door(x, z, s, d)
							reached[c] = 0
							added += 1
							break
		if added == 0:
			break
	var reached := _bfs(L.spawn_cell)
	for s in L.storeys:
		for x in L.size.x:
			for z in L.size.y:
				if L.is_walkable(x, z, s) and not reached.has(Vector3i(x, z, s)):
					var i := L.idx(x, z, s)
					var zn := L.zone_of(x, z, s)
					# Catwalks nobody can reach stay up (out of reach, not missing).
					if zn.type == &"connector":
						L.kind[i] = LevelLayout.Kind.EMPTY
						L.zone[i] = -1
						L.flags[i] = 0
						zn.cols.erase(Vector2i(x, z))
						for d in 4:
							var n := Vector2i(x, z) + LevelLayout.DIRS[d]
							if L.inside(n.x, n.y, s):
								L.set_flag(n.x, n.y, s, LevelLayout.DOOR << ((d + 2) % 4), false)
	# Stairs whose landing got sealed off go too.
	for s in L.storeys:
		for x in L.size.x:
			for z in L.size.y:
				if L.has_flag(x, z, s, LevelLayout.STAIR) and not L.is_walkable(x, z, s + 1):
					L.set_flag(x, z, s, LevelLayout.STAIR, false)
					L.stair[L.idx(x, z, s)] &= 0xF0
					if L.inside(x, z, s + 1):
						L.set_flag(x, z, s + 1, LevelLayout.STAIR_ABOVE, false)
						L.stair[L.idx(x, z, s + 1)] &= 0x0F


func _compute_distances() -> void:
	var reached := _bfs(L.spawn_cell)
	for c: Vector3i in reached:
		var dist: int = reached[c]
		L.distance[L.idx(c.x, c.y, c.z)] = dist
		L.max_distance = maxi(L.max_distance, dist)


# --- 7. Exits, enemies, pickups, anomalies ----------------------------------------------------

func _reachable_floor_cells() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if L.kind_at(x, z, s) == LevelLayout.Kind.FLOOR and L.distance[L.idx(x, z, s)] >= 0:
					out.append(Vector3i(x, z, s))
	return out


## Walls of this cell that can carry a fixture (no door, window, stair strip,
## chamfer or shutter; cramped passages, walkways and yards have none).
func _free_walls(c: Vector3i) -> Array[int]:
	var out: Array[int] = []
	if L.has_flag(c.x, c.y, c.z, LevelLayout.NARROW):
		return out
	var zn := L.zone_of(c.x, c.y, c.z)
	if zn == null or zn.type in [&"yard", &"connector"]:
		return out
	var strips := L.stair_sides(c.x, c.y, c.z)
	for d in 4:
		if L.has_wall(c.x, c.y, c.z, d) and not L.has_door(c.x, c.y, c.z, d) and not L.has_window(c.x, c.y, c.z, d) \
				and not (strips & (1 << d)) and not L.has_flag(c.x, c.y, c.z, LevelLayout.DOCK) \
				and L.chamfer_at(c.x, c.y, c.z, d, false) < 0 and L.chamfer_at(c.x, c.y, c.z, d, true) < 0:
			out.append(d)
	return out


func _dist(c: Vector3i) -> int:
	return L.distance[L.idx(c.x, c.y, c.z)]


func _world(c: Vector3i) -> Vector3:
	return L.cell_center(c.x, c.y, c.z)


func _place_exits() -> void:
	var count := rng.randi_range(profile.exits_min, profile.exits_max)
	var candidates: Array[Vector3i] = []
	for c in _reachable_floor_cells():
		if _dist(c) >= int(L.max_distance * 0.45) and not L.has_flag(c.x, c.y, c.z, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
			var walls := _free_walls(c)
			if not walls.is_empty():
				candidates.append(c)
	var chosen: Array[Vector3i] = []
	for i in count:
		var best := Vector3i(-1, -1, -1)
		var best_score := -1.0
		for c in candidates:
			var score := _world(c).distance_to(L.spawn_position) * 0.5 + _dist(c) * 2.0
			for e in chosen:
				score = minf(score, _world(c).distance_to(_world(e)) * 1.5)
			score *= rng.randf_range(0.85, 1.0)
			if score > best_score:
				best_score = score
				best = c
		if best.x < 0:
			break
		chosen.append(best)
		candidates.erase(best)
	var kinds := [&"open"]
	for i in range(1, chosen.size()):
		kinds.append([&"hidden", &"locked"][rng.randi_range(0, 1)])
	for i in chosen.size():
		var c := chosen[i]
		var walls := _free_walls(c)
		var dir: int = walls[rng.randi_range(0, walls.size() - 1)]
		L.set_flag(c.x, c.y, c.z, LevelLayout.EXIT)
		var exit := {"cell": c, "dir": dir, "kind": kinds[i], "unlocked": kinds[i] != &"locked",
			"position": L.wall_point(c.x, c.y, c.z, dir, 0.0), "lever": {}}
		if kinds[i] == &"locked":
			exit["lever"] = _lever_near(c)
			if exit["lever"].is_empty():
				exit["kind"] = &"open"
				exit["unlocked"] = true
		L.exits.append(exit)


func _lever_near(from: Vector3i) -> Dictionary:
	var dist := _bfs(from)
	var options: Array = []
	for c: Vector3i in dist:
		var d: int = dist[c]
		if d >= 3 and d <= 9 and L.kind_at(c.x, c.y, c.z) == LevelLayout.Kind.FLOOR and not L.has_flag(c.x, c.y, c.z, LevelLayout.EXIT):
			var walls := _free_walls(c)
			if not walls.is_empty():
				options.append([c, walls[rng.randi_range(0, walls.size() - 1)]])
	if options.is_empty():
		return {}
	var o: Array = options[rng.randi_range(0, options.size() - 1)]
	var c: Vector3i = o[0]
	return {"cell": c, "dir": o[1], "position": L.wall_point(c.x, c.y, c.z, o[1], 1.3, rng.randf_range(-2.0, 2.0))}


## Random point in a cell, kept off stair strips and inside cramped passages.
## (ProceduralLevel snaps it onto the navigation mesh once the level is built.)
func _scatter(c: Vector3i, margin: float = 1.6) -> Vector3:
	var o := L.cell_origin(c.x, c.y, c.z)
	if L.has_flag(c.x, c.y, c.z, LevelLayout.NARROW):
		var open := L.open_edges(c.x, c.y, c.z)
		var arms: Array[int] = []
		for d in 4:
			if open & (1 << d):
				arms.append(d)
		var p := L.cell_center(c.x, c.y, c.z)
		if not arms.is_empty():
			p += LevelLayout.dir_vector(arms[rng.randi_range(0, arms.size() - 1)]) * rng.randf_range(0.0, 2.5)
		return p + Vector3.UP * 0.05
	var strips := L.stair_sides(c.x, c.y, c.z)
	for i in 10:
		var p := Vector2(rng.randf_range(margin, L.cell - margin), rng.randf_range(margin, L.cell - margin))
		var ok := true
		for side in 4:
			if not (strips & (1 << side)):
				continue
			var v := LevelLayout.DIRS[side]
			var lateral := p.x if v.x != 0 else p.y
			if (v.x > 0 or v.y > 0) and lateral > L.cell - LevelLayout.STRIP - 0.4:
				ok = false
			if (v.x < 0 or v.y < 0) and lateral < LevelLayout.STRIP + 0.4:
				ok = false
		if ok:
			return o + Vector3(p.x, 0.05, p.y)
	return L.cell_center(c.x, c.y, c.z) + Vector3.UP * 0.05


func _place_enemies() -> void:
	var cells := _reachable_floor_cells().filter(func(c: Vector3i) -> bool: return _dist(c) >= 5)
	_shuffle(cells)
	var placed: Array[Vector3i] = []
	for c: Vector3i in cells:
		if placed.size() >= profile.enemy_count:
			break
		var close := false
		for q in placed:
			if Vector2i(q.x, q.y).distance_to(Vector2i(c.x, c.y)) < 4.0:
				close = true
				break
		if close:
			continue
		placed.append(c)
		var patrol: Array = []
		var cur := c
		for step in rng.randi_range(3, 6):
			var options := L.links(cur.x, cur.y, cur.z).filter(func(n: Vector3i) -> bool:
				return n.z == cur.z and L.kind_at(n.x, n.y, n.z) == LevelLayout.Kind.FLOOR)
			if options.is_empty():
				break
			cur = options[rng.randi_range(0, options.size() - 1)]
			patrol.append(_scatter(cur, 2.0))
		L.enemies.append({"position": _scatter(c, 2.0), "yaw": rng.randf() * TAU, "patrol": patrol,
			"id": profile.enemy_id, "alive": true})


func _place_pickups() -> void:
	var cells := _reachable_floor_cells()
	var far := cells.filter(func(c: Vector3i) -> bool: return _dist(c) >= int(L.max_distance * 0.2))
	_shuffle(far)
	var used := {}
	var i := 0
	for id in profile.weapon_pickups:
		while i < far.size() and used.has(far[i]):
			i += 1
		if i >= far.size():
			break
		used[far[i]] = true
		L.pickups.append({"kind": &"weapon", "id": StringName(id), "position": _scatter(far[i]),
			"yaw": rng.randf() * TAU, "taken": false})
		i += far.size() / maxi(profile.weapon_pickups.size(), 1) / 2
	var total := 0.0
	for cal in profile.ammo_table:
		total += profile.ammo_table[cal][0]
	_shuffle(cells)
	var near := cells.filter(func(c: Vector3i) -> bool: return _dist(c) <= int(L.max_distance * 0.25) and _dist(c) >= 1)
	for n in profile.ammo_pickups:
		var cal: String = ".45ACP"
		var pool: Array = near if n < 3 and not near.is_empty() else cells
		if n >= 3:
			var roll := rng.randf() * total
			for key: String in profile.ammo_table:
				roll -= profile.ammo_table[key][0]
				if roll <= 0.0:
					cal = key
					break
		var entry: Array = profile.ammo_table[cal]
		var c: Vector3i = pool[rng.randi_range(0, pool.size() - 1)]
		L.pickups.append({"kind": &"ammo", "id": StringName(cal), "amount": rng.randi_range(entry[1], entry[2]),
			"position": _scatter(c), "yaw": rng.randf() * TAU, "taken": false})


func _place_anomalies() -> void:
	var cells := _reachable_floor_cells().filter(func(c: Vector3i) -> bool: return _dist(c) >= 4)
	_shuffle(cells)
	var take := func(filter: Callable) -> Vector3i:
		for j in cells.size():
			if filter.call(cells[j]):
				var c: Vector3i = cells[j]
				cells.remove_at(j)
				return c
		return Vector3i(-1, -1, -1)
	var with_wall := func(c: Vector3i) -> bool: return not _free_walls(c).is_empty()
	for n in profile.symbols:
		var c: Vector3i = take.call(func(c2: Vector3i) -> bool:
			return with_wall.call(c2) and L.zone_of(c2.x, c2.y, c2.z).type in [&"office", &"processing", &"maintenance", &"storage"])
		if c.x < 0:
			break
		var walls := _free_walls(c)
		var dir: int = walls[rng.randi_range(0, walls.size() - 1)]
		L.anomalies.append({"kind": &"symbol", "cell": c, "dir": dir, "variant": rng.randi_range(0, 5),
			"position": L.wall_point(c.x, c.y, c.z, dir, rng.randf_range(1.3, 2.0), rng.randf_range(-2.0, 2.0))})
	for n in profile.odd_corpses:
		var c: Vector3i = take.call(with_wall)
		if c.x < 0:
			break
		var walls := _free_walls(c)
		var dir: int = walls[rng.randi_range(0, walls.size() - 1)]
		L.anomalies.append({"kind": &"odd_corpse", "cell": c, "dir": dir, "variant": n % 2,
			"position": L.wall_point(c.x, c.y, c.z, dir, 0.0) - LevelLayout.dir_vector(dir) * (0.45 if n % 2 == 1 else 2.6)})
	for n in profile.odd_containers:
		var c: Vector3i = take.call(func(c2: Vector3i) -> bool:
			return with_wall.call(c2) and L.zone_of(c2.x, c2.y, c2.z).type in [&"processing", &"warehouse", &"office", &"storage", &"maintenance"])
		if c.x < 0:
			break
		var walls := _free_walls(c)
		var dir: int = walls[rng.randi_range(0, walls.size() - 1)]
		L.anomalies.append({"kind": &"odd_container", "cell": c, "dir": dir, "variant": 0,
			"position": L.wall_point(c.x, c.y, c.z, dir, 0.0, rng.randf_range(-1.5, 1.5)) - LevelLayout.dir_vector(dir) * 0.45})
	for n in profile.corpses:
		var c: Vector3i = take.call(func(_c: Vector3i) -> bool: return true)
		if c.x < 0:
			break
		L.corpses.append({"position": _scatter(c), "yaw": rng.randf() * TAU})
