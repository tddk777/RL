class_name LayoutGenerator
extends RefCounted
## Builds a LevelLayout from a LevelProfile and a seed. Same seed, same level.
##
## Steps:
##  1. Cut the footprint into building blocks (BSP); the cuts become corridors.
##  2. Districts: a few centres, each a family (factory, interior, storage).
##     Every block takes a style from its district; blocks straddling two
##     districts sometimes take the neighbour's, so districts blend.
##  3. Fill blocks: tall spaces (factory halls with catwalk rings and bridges,
##     foundries with a charging deck, warehouses, loading docks) or storeyed
##     buildings split into rooms off a cramped central hallway (offices,
##     maintenance, storage, processing). Rooms get a use (cubicles, boiler...).
##  4. Corridors on every storey with buildings beside them; cramped in the
##     interior district.
##  5. Stairs (stairwells, hall and deck stairs, corridor stairs), doors,
##     interior windows.
##  6. Collapse: floor holes and roof holes.
##  7. Spawn in a loading dock; connect everything reachable from it.
##  8. Exits far away (open / hidden / locked), enemies, pickups, anomalies.

const FAMILIES: Array[StringName] = [&"factory", &"interior", &"storage"]
const TALL_TYPES: Array[StringName] = [&"hall", &"foundry", &"warehouse", &"loading_dock"]
const ROOM_TYPES: Array[StringName] = [&"office", &"maintenance", &"storage", &"processing"]

var profile: LevelProfile
var L: LevelLayout
var rng := RandomNumberGenerator.new()
var _corridor_cells: Dictionary = {}  # Vector2i -> true
var _leaves: Array[Rect2i] = []
var _corridor_zone: Dictionary = {}  # Vector2i(storey, family index) -> zone id
var _district_centres: Array[Vector2] = []
var _district_family: Array[int] = []
var _hallways: Dictionary = {}  # zone id -> Rect2i of its hallway (or absent)
var _stairwells: Dictionary = {}  # zone id -> Vector2i cell


static func generate(p: LevelProfile, level_seed: int) -> LevelLayout:
	var g := LayoutGenerator.new()
	return g._run(p, level_seed)


func _run(p: LevelProfile, level_seed: int) -> LevelLayout:
	profile = p
	rng.seed = level_seed
	L = LevelLayout.new()
	L.setup(p, level_seed)
	_split(Rect2i(Vector2i.ZERO, L.size))
	_make_districts()
	_make_buildings()
	_make_corridors()
	_make_bridges()
	_make_stairs()
	_make_doors()
	_make_windows()
	_collapse()
	_choose_spawn()
	_connect_all()
	_compute_distances()
	_place_exits()
	_place_enemies()
	_place_pickups()
	_place_anomalies()
	return L


# --- 1. Blocks and corridors -----------------------------------------------------------

func _split(r: Rect2i) -> void:
	var mn := profile.min_block
	var can_x := r.size.x >= mn * 2 + 1
	var can_z := r.size.y >= mn * 2 + 1
	var must := r.size.x > profile.max_block or r.size.y > profile.max_block
	var stop_chance := 0.5 if r.size.x * r.size.y >= 25 else 0.3
	if not (can_x or can_z) or (not must and rng.randf() < stop_chance):
		_leaves.append(r)
		return
	var along_x: bool
	if can_x and can_z:
		along_x = r.size.x > r.size.y if absi(r.size.x - r.size.y) > 2 else rng.randf() < 0.5
	else:
		along_x = can_x
	if along_x:
		var c := rng.randi_range(r.position.x + mn, r.end.x - mn - 1)
		for z in range(r.position.y, r.end.y):
			_corridor_cells[Vector2i(c, z)] = true
		_split(Rect2i(r.position.x, r.position.y, c - r.position.x, r.size.y))
		_split(Rect2i(c + 1, r.position.y, r.end.x - c - 1, r.size.y))
	else:
		var c := rng.randi_range(r.position.y + mn, r.end.y - mn - 1)
		for x in range(r.position.x, r.end.x):
			_corridor_cells[Vector2i(x, c)] = true
		_split(Rect2i(r.position.x, r.position.y, r.size.x, c - r.position.y))
		_split(Rect2i(r.position.x, c + 1, r.size.x, r.end.y - c - 1))


## Seeded Fisher-Yates (Array.shuffle() uses the global RNG).
func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


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


# --- 2. Districts ------------------------------------------------------------------------

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


func _family_counts(r: Rect2i) -> Array[int]:
	var counts: Array[int] = [0, 0, 0]
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			counts[L.district_at(x, z)] += 1
	return counts


# --- 3. Buildings ----------------------------------------------------------------------

func _make_buildings() -> void:
	var have_dock := false
	for r: Rect2i in _leaves:
		var counts := _family_counts(r)
		var fam := 0
		for i in 3:
			if counts[i] > counts[fam]:
				fam = i
		# Blend at district borders.
		for i in 3:
			if i != fam and counts[i] * 4 >= r.size.x * r.size.y and rng.randf() < profile.blend_chance:
				fam = i
		var style := _pick_style(r, fam, not have_dock)
		if style == null:
			continue
		have_dock = have_dock or style.type == &"loading_dock"
		_build_block(r, style, fam)
	if not have_dock:
		# Guarantee a loading dock to start in: convert an edge block.
		var dock := profile.style_for(&"loading_dock")
		var best: LevelLayout.Zone = null
		for z in L.zones:
			if _on_edge(z.rect) and (best == null or (z.district == 2 and best.district != 2)):
				best = z
		if dock and best:
			_clear_zone(best)
			best.type = &"loading_dock"
			best.style = dock
			best.top = mini(1, L.storeys - 1)
			_fill_tall(best.rect, best.id, best.top, false)


func _build_block(r: Rect2i, style: ZoneStyle, fam: int) -> void:
	var top := clampi(rng.randi_range(style.extra_storeys.x, style.extra_storeys.y), 0, L.storeys - 1)
	var id := _add_zone(style.type, style, r, 0, top, fam)
	match style.type:
		&"hall":
			_fill_tall(r, id, top, true)
		&"foundry":
			_fill_tall(r, id, top, false)
			_deck(r, id, top)
		&"warehouse", &"loading_dock":
			_fill_tall(r, id, top, false)
		&"processing":
			if r.size.x * r.size.y >= 16 and mini(r.size.x, r.size.y) >= 4 and rng.randf() < 0.5:
				L.zones[id].type = &"processing"
				_fill_tall(r, id, maxi(top, 1) if L.storeys > 1 else 0, true)
				L.zones[id].top = maxi(top, 1) if L.storeys > 1 else 0
			else:
				_fill_rooms(r, id, top, 3, false)
		&"office":
			_fill_rooms(r, id, top, 2, true)
		&"maintenance":
			_fill_rooms(r, id, top, 2, true)
		_:
			_fill_rooms(r, id, top, 3, rng.randf() < 0.5)


func _pick_style(r: Rect2i, fam: int, want_dock: bool) -> ZoneStyle:
	var area := r.size.x * r.size.y
	var mn := mini(r.size.x, r.size.y)
	var edge := _on_edge(r)
	var fits := func(s: ZoneStyle) -> bool:
		match s.type:
			&"hall":
				return mn >= 3 and area >= 15
			&"foundry":
				return mn >= 3 and area >= 12
			&"processing":
				return area >= 6
			&"office", &"maintenance":
				return area <= 48
			&"warehouse":
				return mn >= 3 and area >= 12
			&"storage":
				return area <= 40
			&"loading_dock":
				return edge and mn >= 3 and area >= 9 and area <= 48
		return true
	var options: Array[ZoneStyle] = []
	for s in profile.buildings:
		if s.family == FAMILIES[fam] and fits.call(s):
			options.append(s)
	if options.is_empty():
		for s in profile.buildings:
			if fits.call(s) and s.type != &"loading_dock":
				options.append(s)
	if options.is_empty():
		return profile.buildings[0] if not profile.buildings.is_empty() else null
	if want_dock and edge:
		for s in options:
			if s.type == &"loading_dock":
				return s
	var total := 0.0
	for s in options:
		total += s.weight
	var roll := rng.randf() * total
	for s in options:
		roll -= s.weight
		if roll <= 0.0:
			return s
	return options.back()


func _on_edge(r: Rect2i) -> bool:
	return r.position.x == 0 or r.position.y == 0 or r.end.x == L.size.x or r.end.y == L.size.y


func _clear_zone(z: LevelLayout.Zone) -> void:
	for s in L.storeys:
		for x in range(z.rect.position.x, z.rect.end.x):
			for zz in range(z.rect.position.y, z.rect.end.y):
				var i := L.idx(x, zz, s)
				L.kind[i] = LevelLayout.Kind.EMPTY
				L.zone[i] = -1
				L.room[i] = 0
				L.flags[i] = 0
				L.stair[i] = 0
	_hallways.erase(z.id)
	_stairwells.erase(z.id)


## Tall open space: floor at ground level, open air above. Rings put catwalk
## strips along every wall on the upper storeys.
func _fill_tall(r: Rect2i, id: int, top: int, ring: bool) -> void:
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			_put(x, z, 0, LevelLayout.Kind.FLOOR, id)
			for s in range(1, top + 1):
				_put(x, z, s, LevelLayout.Kind.VOID, id)
	if not ring or top < 1:
		return
	var ring_top := maxi(1, top - 1)
	for s in range(1, ring_top + 1):
		for x in range(r.position.x, r.end.x):
			for z in range(r.position.y, r.end.y):
				var sides := 0
				if z == r.position.y:
					sides |= 1
				if x == r.end.x - 1:
					sides |= 2
				if z == r.end.y - 1:
					sides |= 4
				if x == r.position.x:
					sides |= 8
				if sides != 0:
					_put(x, z, s, LevelLayout.Kind.CATWALK, id)
					L.flags[L.idx(x, z, s)] |= sides << 4


## Foundry charging deck: a catwalk along one long wall.
func _deck(r: Rect2i, id: int, top: int) -> void:
	if top < 1:
		return
	var side := (0 if rng.randf() < 0.5 else 2) if r.size.x >= r.size.y else (1 if rng.randf() < 0.5 else 3)
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			var on := (side == 0 and z == r.position.y) or (side == 2 and z == r.end.y - 1) \
				or (side == 1 and x == r.end.x - 1) or (side == 3 and x == r.position.x)
			if on:
				_put(x, z, 1, LevelLayout.Kind.CATWALK, id)
				L.flags[L.idx(x, z, 1)] |= (1 << side) << 4


## Storeyed building: on every floor a cramped hallway (optional) with rooms
## either side; a stairwell column joins the floors.
func _fill_rooms(r: Rect2i, id: int, top: int, max_size: int, hallway: bool) -> void:
	var zn := L.zones[id]
	var hall_rect := Rect2i()
	if hallway and mini(r.size.x, r.size.y) >= 3:
		if r.size.x >= r.size.y:
			hall_rect = Rect2i(r.position.x, r.position.y + rng.randi_range(1, r.size.y - 2), r.size.x, 1)
		else:
			hall_rect = Rect2i(r.position.x + rng.randi_range(1, r.size.x - 2), r.position.y, 1, r.size.y)
		_hallways[id] = hall_rect
	var well := Vector2i(-1, -1)
	if top >= 1:
		well = _pick_stairwell(r, hall_rect)
		if well.x >= 0:
			_stairwells[id] = well
	for s in range(0, top + 1):
		var parts: Array[Rect2i] = []
		if hall_rect.size != Vector2i.ZERO:
			var hall := _add_room(id, s, hall_rect, &"hallway")
			for x in range(hall_rect.position.x, hall_rect.end.x):
				for z in range(hall_rect.position.y, hall_rect.end.y):
					_put(x, z, s, LevelLayout.Kind.FLOOR, id, hall.id)
					L.flags[L.idx(x, z, s)] |= LevelLayout.NARROW
			if hall_rect.size.y == 1:
				parts.append(Rect2i(r.position.x, r.position.y, r.size.x, hall_rect.position.y - r.position.y))
				parts.append(Rect2i(r.position.x, hall_rect.end.y, r.size.x, r.end.y - hall_rect.end.y))
			else:
				parts.append(Rect2i(r.position.x, r.position.y, hall_rect.position.x - r.position.x, r.size.y))
				parts.append(Rect2i(hall_rect.end.x, r.position.y, r.end.x - hall_rect.end.x, r.size.y))
		else:
			parts.append(r)
		var rects: Array[Rect2i] = []
		for part in parts:
			if part.size.x > 0 and part.size.y > 0:
				_split_rooms(part, rects, max_size)
		var made: Array[LevelLayout.Room] = []
		for rr in rects:
			var room := _add_room(id, s, rr, &"")
			made.append(room)
			for x in range(rr.position.x, rr.end.x):
				for z in range(rr.position.y, rr.end.y):
					_put(x, z, s, LevelLayout.Kind.FLOOR, id, room.id)
		_merge_rooms(made, s)
		for room in made:
			if room.use == &"":
				room.use = _room_use(zn.type, room)
		if well.x >= 0:
			var sw := _add_room(id, s, Rect2i(well, Vector2i.ONE), &"stairwell")
			_put(well.x, well.y, s, LevelLayout.Kind.FLOOR, id, sw.id)


func _pick_stairwell(r: Rect2i, hall: Rect2i) -> Vector2i:
	var options: Array[Vector2i] = []
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			var p := Vector2i(x, z)
			if hall.has_point(p):
				continue
			# Next to the hallway (or anywhere when there is none).
			var ok := hall.size == Vector2i.ZERO
			for d in LevelLayout.DIRS:
				if hall.has_point(p + d):
					ok = true
			if ok:
				options.append(p)
	if options.is_empty():
		return Vector2i(-1, -1)
	return options[rng.randi_range(0, options.size() - 1)]


func _split_rooms(r: Rect2i, out: Array[Rect2i], max_size: int) -> void:
	var can_x := r.size.x >= 2
	var can_z := r.size.y >= 2
	var too_big := r.size.x > max_size or r.size.y > max_size
	if not (can_x or can_z) or (not too_big and rng.randf() < 0.45):
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
		if a.extra.size() > 0 or rng.randf() > 0.2:
			continue
		for b in made:
			if b == a or b.extra.size() > 0 or not _touching(a.rect, b.rect):
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
	var g := a.grow(1)
	return g.intersects(b) and not a.intersects(b) and \
		((a.end.x == b.position.x or b.end.x == a.position.x) and a.position.y < b.end.y and b.position.y < a.end.y
		or (a.end.y == b.position.y or b.end.y == a.position.y) and a.position.x < b.end.x and b.position.x < a.end.x)


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


# --- 4. Corridors ------------------------------------------------------------------------

func _make_corridors() -> void:
	for s in L.storeys:
		for c: Vector2i in _corridor_cells:
			var keep := s == 0
			if not keep:
				for d in LevelLayout.DIRS:
					var n := c + d
					var zn := L.zone_of(n.x, n.y, s)
					if zn and zn.type != &"corridor" and zn.top >= s:
						keep = true
						break
			if not keep:
				continue
			var fam := L.district_at(c.x, c.y)
			var key := Vector2i(s, fam)
			var style := profile.corridor_for(FAMILIES[fam])
			if not _corridor_zone.has(key):
				_corridor_zone[key] = _add_zone(&"corridor", style, Rect2i(Vector2i.ZERO, L.size), s, s, fam)
			_put(c.x, c.y, s, LevelLayout.Kind.FLOOR, _corridor_zone[key])
			if style and style.narrow:
				L.flags[L.idx(c.x, c.y, s)] |= LevelLayout.NARROW


## Catwalk bridges across the middle of factory halls.
func _make_bridges() -> void:
	for zn in L.zones:
		if zn.type != &"hall" or zn.top < 1:
			continue
		var r := zn.rect
		var axes: Array[int] = []
		if r.size.x >= 5:
			axes.append(0)
		if r.size.y >= 5 and (axes.is_empty() or rng.randf() < 0.4):
			axes.append(1)
		for axis in axes:
			if axis == 0:
				var z := r.position.y + r.size.y / 2
				for x in range(r.position.x, r.end.x):
					_bridge_cell(x, z, LevelLayout.BRIDGE_X)
			else:
				var x := r.position.x + r.size.x / 2
				for z in range(r.position.y, r.end.y):
					_bridge_cell(x, z, LevelLayout.BRIDGE_Z)


func _bridge_cell(x: int, z: int, flag: int) -> void:
	var i := L.idx(x, z, 1)
	if L.kind[i] == LevelLayout.Kind.VOID:
		L.kind[i] = LevelLayout.Kind.CATWALK
	if L.kind[i] == LevelLayout.Kind.CATWALK:
		L.flags[i] |= flag


# --- 5. Stairs, doors and windows ---------------------------------------------------------

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
	for z in L.zones:
		if _stairwells.has(z.id):
			_stairwell(z, _stairwells[z.id])
		elif z.type in [&"hall", &"foundry", &"processing"]:
			_catwalk_stairs(z)
	_corridor_stairs()


## Switchback stairwell in one cell: flights alternate sides and directions,
## each landing at the end where the next one starts.
func _stairwell(z: LevelLayout.Zone, c: Vector2i) -> void:
	var hall: Rect2i = _hallways.get(z.id, Rect2i())
	# Strips run along the two lateral walls, so doors can only be on the
	# ends: climb along the axis that points at the hallway (or, without
	# one, at the rest of the building).
	var dir := -1
	for d in 4:
		if hall.has_point(c + LevelLayout.DIRS[d]):
			dir = d
	if dir < 0:
		for d in 4:
			if z.rect.has_point(c + LevelLayout.DIRS[d]):
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
	var r := z.rect
	for s in range(1, z.top + 1):
		var candidates: Array = []
		for x in range(r.position.x, r.end.x):
			for zz in range(r.position.y, r.end.y):
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


## Stairs in wide corridors, along a wall where there is one.
func _corridor_stairs() -> void:
	for s in range(0, L.storeys - 1):
		var candidates: Array = []
		for c: Vector2i in _corridor_cells:
			var a := L.zone_of(c.x, c.y, s)
			var b := L.zone_of(c.x, c.y, s + 1)
			if a == null or b == null or a.type != &"corridor" or b.type != &"corridor" or a.district != b.district:
				continue
			if L.has_flag(c.x, c.y, s, LevelLayout.NARROW | LevelLayout.STAIR_ABOVE) or L.has_flag(c.x, c.y, s + 1, LevelLayout.NARROW):
				continue
			for side in 4:
				if not L.has_wall(c.x, c.y, s, side) or not L.has_wall(c.x, c.y, s + 1, side):
					continue
				for d in [(side + 1) % 4, (side + 3) % 4]:
					candidates.append([c.x, c.y, d, side])
		_shuffle(candidates)
		var want := clampi(candidates.size() / 30, 2, 5)
		var placed: Array[Vector2i] = []
		for c in candidates:
			var p := Vector2i(c[0], c[1])
			var close := false
			for q in placed:
				if p.distance_to(q) < 6.0:
					close = true
					break
			if close:
				continue
			if _place_stair(c[0], c[1], s, c[2], c[3]):
				placed.append(p)
				if placed.size() >= want:
					break


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


func _make_doors() -> void:
	for zn in L.zones:
		if zn.type == &"corridor":
			continue
		for s in range(zn.base, zn.top + 1):
			# Building <-> corridor doors, grouped per side
			var by_side := {0: [], 1: [], 2: [], 3: []}
			var r := zn.rect
			for x in range(r.position.x, r.end.x):
				for z in range(r.position.y, r.end.y):
					for d in 4:
						var n := Vector2i(x, z) + LevelLayout.DIRS[d]
						if r.has_point(n):
							continue
						var nz := L.zone_of(n.x, n.y, s)
						if nz and nz.type == &"corridor" and _door_ok(x, z, s, d):
							by_side[d].append(Vector2i(x, z))
			for d in 4:
				var cells: Array = by_side[d]
				if cells.is_empty():
					continue
				_shuffle(cells)
				# Hallway ends get the doors when the hallway reaches this side.
				var hall: Rect2i = _hallways.get(zn.id, Rect2i())
				cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return hall.has_point(a) and not hall.has_point(b))
				var count := 1 + (1 if cells.size() >= 5 and rng.randf() < 0.5 else 0)
				if s > 0 and rng.randf() < 0.35:
					count = 0 if d != _first_side(by_side) else 1
				for i in mini(count, cells.size()):
					_door(cells[i].x, cells[i].y, s, d)
			if L.room_at(r.position.x, r.position.y, s) != 0 or _hallways.has(zn.id) or _stairwells.has(zn.id):
				_room_doors(zn, s)


func _first_side(by_side: Dictionary) -> int:
	for d in 4:
		if not (by_side[d] as Array).is_empty():
			return d
	return -1


## Every room off the hallway gets a door to it; the rest join through a
## spanning tree of doors between rooms, plus a few loops.
func _room_doors(zn: LevelLayout.Zone, s: int) -> void:
	var pairs := {}  # "a:b" -> Array of [x, z, dir]
	var r := zn.rect
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			for d in [1, 2]:
				var n := Vector2i(x, z) + LevelLayout.DIRS[d]
				if not r.has_point(n):
					continue
				var a := L.room[L.idx(x, z, s)]
				var b := L.room[L.idx(n.x, n.y, s)]
				if a == b or not _door_ok(x, z, s, d):
					continue
				var key := "%d:%d" % [mini(a, b), maxi(a, b)]
				if not pairs.has(key):
					pairs[key] = []
				pairs[key].append([x, z, d])
	var parent := {}
	var find := func(a: int) -> int:
		while parent.get(a, a) != a:
			a = parent[a]
		return a
	var keys := pairs.keys()
	_shuffle(keys)
	# Hallway doors first.
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


## Interior windows: offices and service rooms looking out over the factory
## floor, glass partitions between offices.
func _make_windows() -> void:
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if not L.is_walkable(x, z, s):
					continue
				for d in [1, 2]:
					var n := Vector2i(x, z) + LevelLayout.DIRS[d]
					if not L.inside(n.x, n.y, s) or not L.is_enclosed(n.x, n.y, s):
						continue
					if not L.has_wall(x, z, s, d) or L.has_door(x, z, s, d):
						continue
					if L.has_flag(x, z, s, LevelLayout.NARROW) or L.has_flag(n.x, n.y, s, LevelLayout.NARROW):
						continue
					if L.stair_sides(x, z, s) & (1 << d) or L.stair_sides(n.x, n.y, s) & (1 << ((d + 2) % 4)):
						continue
					var a := L.zone_of(x, z, s)
					var b := L.zone_of(n.x, n.y, s)
					if a == null or b == null:
						continue
					var chance := 0.0
					var a_tall := a.type in TALL_TYPES or L.room_at(x, z, s) == 0
					var b_tall := b.type in TALL_TYPES or L.room_at(n.x, n.y, s) == 0
					if (a.type in ROOM_TYPES and b_tall) or (b.type in ROOM_TYPES and a_tall):
						chance = 0.45
					elif a == b and a.type == &"office":
						chance = 0.15
					elif (a.type == &"corridor" and b_tall) or (b.type == &"corridor" and a_tall):
						chance = 0.15
					if a.type == &"corridor" and b.type == &"corridor":
						chance = 0.0
					if L.kind_at(x, z, s) == LevelLayout.Kind.CATWALK or L.kind_at(n.x, n.y, s) == LevelLayout.Kind.CATWALK:
						chance *= 0.5
					if chance > 0.0 and rng.randf() < chance:
						L.set_flag(x, z, s, LevelLayout.WINDOW << d)
						L.set_flag(n.x, n.y, s, LevelLayout.WINDOW << ((d + 2) % 4))


# --- 6. Collapse --------------------------------------------------------------------------

func _collapse() -> void:
	for x in L.size.x:
		for z in L.size.y:
			for s in L.storeys:
				var i := L.idx(x, z, s)
				var zn := L.zone_of(x, z, s)
				if zn == null:
					continue
				var style := zn.style
				# Roof holes at the top of tall spaces and top floors.
				var above := L.kind_at(x, z, s + 1)
				if above == LevelLayout.Kind.EMPTY and style.roof_hole_chance > 0.0 and rng.randf() < style.roof_hole_chance \
						and L.kind[i] != LevelLayout.Kind.CATWALK and not (L.flags[i] & LevelLayout.NARROW):
					L.flags[i] |= LevelLayout.ROOF_HOLE
				# Floors fallen through onto the storey below.
				if s >= 1 and L.kind[i] == LevelLayout.Kind.FLOOR and style.collapse_chance > 0.0 \
						and rng.randf() < style.collapse_chance and L.flags[i] & (LevelLayout.STAIR | LevelLayout.STAIR_ABOVE | LevelLayout.NARROW) == 0 \
						and L.kind_at(x, z, s - 1) == LevelLayout.Kind.FLOOR \
						and not L.has_flag(x, z, s - 1, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE | LevelLayout.NARROW) \
						and not _near_stair(x, z, s) and L.room_of(x, z, s) and L.room_of(x, z, s).use != &"stairwell":
					L.kind[i] = LevelLayout.Kind.HOLE


func _near_stair(x: int, z: int, s: int) -> bool:
	for d in LevelLayout.DIRS:
		var n := Vector2i(x, z) + d
		for ss in [s - 1, s]:
			if L.has_flag(n.x, n.y, ss, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
				return true
	return false


# --- 7. Spawn and connectivity --------------------------------------------------------------

func _choose_spawn() -> void:
	var docks: Array = []
	for zn in L.zones:
		if zn.type == &"loading_dock":
			docks.append(zn)
	for zn in docks:
		var r: Rect2i = zn.rect
		for x in range(r.position.x, r.end.x):
			for z in range(r.position.y, r.end.y):
				for d in 4:
					if L.is_exterior(x, z, d):
						L.set_flag(x, z, 0, LevelLayout.DOCK)
	var start: LevelLayout.Zone = docks[rng.randi_range(0, docks.size() - 1)] if not docks.is_empty() else null
	var cell := Vector2i(L.size.x / 2, L.size.y / 2)
	var inward := 0
	if start:
		var r := start.rect
		var options: Array = []
		for x in range(r.position.x, r.end.x):
			for z in range(r.position.y, r.end.y):
				for d in 4:
					if L.is_exterior(x, z, d):
						options.append([x, z, (d + 2) % 4])
		if not options.is_empty():
			var o: Array = options[rng.randi_range(0, options.size() - 1)]
			cell = Vector2i(o[0], o[1])
			inward = o[2]
	else:
		for c: Vector2i in _corridor_cells:
			cell = c
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
	for attempt in 40:
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
					if L.kind[i] == LevelLayout.Kind.CATWALK:
						L.kind[i] = LevelLayout.Kind.VOID
						L.flags[i] &= ~(LevelLayout.BRIDGE_X | LevelLayout.BRIDGE_Z | (15 << 4))
					elif L.zone_of(x, z, s).type == &"corridor":
						L.kind[i] = LevelLayout.Kind.EMPTY
						L.zone[i] = -1
						L.flags[i] = 0
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


# --- 8. Exits, enemies, pickups, anomalies ----------------------------------------------------

func _reachable_floor_cells() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for s in L.storeys:
		for z in L.size.y:
			for x in L.size.x:
				if L.kind_at(x, z, s) == LevelLayout.Kind.FLOOR and L.distance[L.idx(x, z, s)] >= 0:
					out.append(Vector3i(x, z, s))
	return out


## Walls of this cell that can carry a fixture (no door, window or stair strip;
## cramped passages have their walls elsewhere).
func _free_walls(c: Vector3i) -> Array[int]:
	var out: Array[int] = []
	if L.has_flag(c.x, c.y, c.z, LevelLayout.NARROW):
		return out
	var strips := L.stair_sides(c.x, c.y, c.z)
	for d in 4:
		if L.has_wall(c.x, c.y, c.z, d) and not L.has_door(c.x, c.y, c.z, d) and not L.has_window(c.x, c.y, c.z, d) \
				and not (strips & (1 << d)) and not L.has_flag(c.x, c.y, c.z, LevelLayout.DOCK):
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
			return with_wall.call(c2) and L.zone_of(c2.x, c2.y, c2.z).type in [&"office", &"processing", &"corridor", &"maintenance", &"storage"])
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
