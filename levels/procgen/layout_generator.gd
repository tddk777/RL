class_name LayoutGenerator
extends RefCounted
## Builds a LevelLayout from a LevelProfile and a seed. Same seed, same level.
##
## Steps:
##  1. Cut the footprint into building blocks (BSP); the cuts become
##     maintenance corridors.
##  2. Give each block a building type and height and fill its cells
##     (halls with catwalk rings, warehouses, processing plants, offices,
##     loading docks).
##  3. Corridors on every storey that has buildings beside it.
##  4. Stairs (office stairwells, hall catwalk stairs, corridor stairs),
##     doors (building <-> corridor, room <-> room).
##  5. Collapse: floor holes and roof holes.
##  6. Spawn in a loading dock; connect everything reachable from it.
##  7. Exits far away (open / hidden / locked), enemies, pickups, anomalies.

var profile: LevelProfile
var L: LevelLayout
var rng := RandomNumberGenerator.new()
var _corridor_cells: Dictionary = {}  # Vector2i -> true
var _leaves: Array[Rect2i] = []
var _corridor_zone: Dictionary = {}  # storey -> zone id


static func generate(p: LevelProfile, level_seed: int) -> LevelLayout:
	var g := LayoutGenerator.new()
	return g._run(p, level_seed)


func _run(p: LevelProfile, level_seed: int) -> LevelLayout:
	profile = p
	rng.seed = level_seed
	L = LevelLayout.new()
	L.setup(p, level_seed)
	_split(Rect2i(Vector2i.ZERO, L.size))
	_make_buildings()
	_make_corridors()
	_make_stairs()
	_make_doors()
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
	var stop_chance := 0.55 if r.size.x * r.size.y >= 36 else 0.3
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


func _add_zone(type: StringName, style: ZoneStyle, rect: Rect2i, base: int, top: int) -> int:
	var z := LevelLayout.Zone.new()
	z.id = L.zones.size()
	z.type = type
	z.style = style
	z.rect = rect
	z.base = base
	z.top = top
	L.zones.append(z)
	return z.id


func _put(x: int, z: int, s: int, kind: int, zone_id: int, room_id: int = 0) -> void:
	var i := L.idx(x, z, s)
	L.kind[i] = kind
	L.zone[i] = zone_id
	L.room[i] = room_id


# --- 2. Buildings ----------------------------------------------------------------------

func _make_buildings() -> void:
	var have_dock := false
	var order := _leaves.duplicate()
	for r: Rect2i in order:
		var style := _pick_style(r, not have_dock)
		if style == null:
			continue
		have_dock = have_dock or style.type == &"loading_dock"
		var top := clampi(rng.randi_range(style.extra_storeys.x, style.extra_storeys.y), 0, L.storeys - 1)
		var id := _add_zone(style.type, style, r, 0, top)
		match style.type:
			&"hall":
				_fill_tall(r, id, top, true)
			&"warehouse", &"loading_dock":
				_fill_tall(r, id, top, false)
			_:
				_fill_rooms(r, id, top, style.type == &"office")
	if not have_dock:
		# Guarantee a loading dock to start in: convert an edge block.
		for z in L.zones:
			if _on_edge(z.rect) and z.type != &"loading_dock":
				var dock := profile.style_for(&"loading_dock")
				if dock:
					_clear_zone(z)
					z.type = &"loading_dock"
					z.style = dock
					z.top = mini(1, L.storeys - 1)
					_fill_tall(z.rect, z.id, z.top, false)
					break


func _pick_style(r: Rect2i, want_dock: bool) -> ZoneStyle:
	var area := r.size.x * r.size.y
	var mn := mini(r.size.x, r.size.y)
	var edge := _on_edge(r)
	var options: Array[ZoneStyle] = []
	for s in profile.buildings:
		var ok := false
		match s.type:
			&"hall":
				ok = mn >= 5 and area >= 36
			&"warehouse":
				ok = mn >= 4 and area >= 20
			&"processing":
				ok = area >= 9
			&"office":
				ok = area <= 70
			&"loading_dock":
				ok = edge and mn >= 3 and area >= 12 and area <= 70
		if ok:
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
				L.flags[i] = 0


## Tall open space: floor at ground level, open air above. Halls get catwalk
## rings along their walls on the upper storeys.
func _fill_tall(r: Rect2i, id: int, top: int, catwalks: bool) -> void:
	for x in range(r.position.x, r.end.x):
		for z in range(r.position.y, r.end.y):
			_put(x, z, 0, LevelLayout.Kind.FLOOR, id)
			for s in range(1, top + 1):
				_put(x, z, s, LevelLayout.Kind.VOID, id)
	if not catwalks or top < 1:
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


## Storeyed building split into rooms on every floor.
func _fill_rooms(r: Rect2i, id: int, top: int, office: bool) -> void:
	for s in range(0, top + 1):
		var rooms: Array[Rect2i] = []
		_split_rooms(r, rooms, 2 if office else 3)
		for k in rooms.size():
			var rr := rooms[k]
			for x in range(rr.position.x, rr.end.x):
				for z in range(rr.position.y, rr.end.y):
					_put(x, z, s, LevelLayout.Kind.FLOOR, id, k + 1)


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


# --- 3. Corridors ------------------------------------------------------------------------

func _make_corridors() -> void:
	var style := profile.corridor
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
			if not _corridor_zone.has(s):
				_corridor_zone[s] = _add_zone(&"corridor", style, Rect2i(Vector2i.ZERO, L.size), s, s)
			_put(c.x, c.y, s, LevelLayout.Kind.FLOOR, _corridor_zone[s])


# --- 4. Stairs and doors ------------------------------------------------------------------

func _place_stair(x: int, z: int, s: int, dir: int, side: int) -> bool:
	var t := Vector2i(x, z) + LevelLayout.DIRS[dir]
	if not L.inside(t.x, t.y, s + 1):
		return false
	if L.has_flag(x, z, s, LevelLayout.STAIR) or L.has_flag(x, z, s + 1, LevelLayout.STAIR):
		return false
	var i := L.idx(x, z, s)
	var above := L.idx(x, z, s + 1)
	L.flags[i] |= LevelLayout.STAIR
	L.flags[above] |= LevelLayout.STAIR_ABOVE
	L.stair[i] = dir | (side << 2)
	L.stair[above] = dir | (side << 2)
	# The catwalk strip on the ramp side is replaced by the ramp opening.
	if L.kind[above] == LevelLayout.Kind.CATWALK:
		L.flags[above] &= ~(LevelLayout.CATWALK_SIDE << side)
		if (L.flags[above] >> 4) & 15 == 0:
			L.kind[above] = LevelLayout.Kind.VOID
	return true


func _make_stairs() -> void:
	for z in L.zones:
		match z.type:
			&"office", &"processing":
				if z.top >= 1:
					_stairwell(z)
			&"hall":
				_hall_stairs(z)
	_corridor_stairs()


## Zig-zag stairwell between two neighbouring cells, one flight per storey.
func _stairwell(z: LevelLayout.Zone) -> void:
	var r := z.rect
	var along_x := r.size.x >= r.size.y
	if (along_x and r.size.x < 2) or (not along_x and r.size.y < 2):
		return
	var dir := 1 if along_x else 2
	var start := Vector2i(r.position.x + rng.randi_range(0, maxi(r.size.x - 2, 0)) if along_x else r.position.x + rng.randi_range(0, r.size.x - 1),
		r.position.y + rng.randi_range(0, r.size.y - 1) if along_x else r.position.y + rng.randi_range(0, maxi(r.size.y - 2, 0)))
	var other := start + LevelLayout.DIRS[dir]
	var sides := [(dir + 1) % 4, (dir + 3) % 4]
	var stair_room := 63
	for s in range(0, z.top + 1):
		for c in [start, other]:
			L.room[L.idx(c.x, c.y, s)] = stair_room
	for s in range(0, z.top):
		var from: Vector2i = start if s % 2 == 0 else other
		var d := dir if s % 2 == 0 else (dir + 2) % 4
		_place_stair(from.x, from.y, s, d, sides[s % 2])


## A stair along a hall wall up to each catwalk ring.
func _hall_stairs(z: LevelLayout.Zone) -> void:
	var r := z.rect
	for s in range(1, z.top + 1):
		var candidates: Array = []
		for x in range(r.position.x, r.end.x):
			for zz in range(r.position.y, r.end.y):
				if L.kind_at(x, zz, s) != LevelLayout.Kind.CATWALK:
					continue
				var sides := (L.flags_at(x, zz, s) >> 4) & 15
				for wall in 4:
					if not (sides & (1 << wall)):
						continue
					for d in [(wall + 1) % 4, (wall + 3) % 4]:
						var t := Vector2i(x, zz) + LevelLayout.DIRS[d]
						var below_ok := L.kind_at(x, zz, s - 1) == LevelLayout.Kind.FLOOR or \
							(L.kind_at(x, zz, s - 1) == LevelLayout.Kind.CATWALK and (L.flags_at(x, zz, s - 1) >> 4) & (1 << wall))
						if below_ok and L.kind_at(t.x, t.y, s) == LevelLayout.Kind.CATWALK \
								and (L.flags_at(t.x, t.y, s) >> 4) & (1 << wall) and sides == (1 << wall):
							candidates.append([x, zz, d, wall])
		if candidates.is_empty():
			continue
		var count := 2 if candidates.size() > 16 else 1
		_shuffle(candidates)
		var placed := 0
		for c in candidates:
			if _place_stair(c[0], c[1], s - 1, c[2], c[3]):
				placed += 1
				if placed >= count:
					break


func _corridor_stairs() -> void:
	for s in range(0, L.storeys - 1):
		var candidates: Array = []
		for c: Vector2i in _corridor_cells:
			if L.zone_at(c.x, c.y, s) != _corridor_zone.get(s, -2) or L.zone_at(c.x, c.y, s + 1) != _corridor_zone.get(s + 1, -2):
				continue
			for d in 4:
				var t := c + LevelLayout.DIRS[d]
				var b := c - LevelLayout.DIRS[d]
				if L.zone_at(t.x, t.y, s + 1) == _corridor_zone[s + 1] and L.zone_at(b.x, b.y, s) == _corridor_zone[s]:
					candidates.append([c.x, c.y, d])
		_shuffle(candidates)
		var want := clampi(candidates.size() / 40, 2, 10)
		var placed: Array[Vector2i] = []
		for c in candidates:
			var p := Vector2i(c[0], c[1])
			var close := false
			for q in placed:
				if p.distance_to(q) < 8.0:
					close = true
					break
			if close:
				continue
			if _place_stair(c[0], c[1], s, c[2], (c[2] + 1 + 2 * rng.randi_range(0, 1)) % 4):
				placed.append(p)
				if placed.size() >= want:
					break


func _door(x: int, z: int, s: int, dir: int) -> void:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	L.set_flag(x, z, s, LevelLayout.DOOR << dir)
	L.set_flag(n.x, n.y, s, LevelLayout.DOOR << ((dir + 2) % 4))


## A door can go here: walls on both sides of the edge belong to walkable cells
## and a catwalk only opens on its own strip side.
func _door_ok(x: int, z: int, s: int, dir: int) -> bool:
	var n := Vector2i(x, z) + LevelLayout.DIRS[dir]
	if not (L.is_walkable(x, z, s) and L.is_walkable(n.x, n.y, s)):
		return false
	for c in [[x, z, dir], [n.x, n.y, (dir + 2) % 4]]:
		var k := L.kind_at(c[0], c[1], s)
		if k == LevelLayout.Kind.CATWALK and not ((L.flags_at(c[0], c[1], s) >> 4) & (1 << c[2])):
			return false
		# Keep doorways off ramp strips.
		if L.has_flag(c[0], c[1], s, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) and L.stair_side(c[0], c[1], s) == c[2]:
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
				var count := 1 + (1 if cells.size() >= 6 and rng.randf() < 0.6 else 0)
				if s > 0 and rng.randf() < 0.35:
					count = 0 if d != _first_side(by_side) else 1
				for i in mini(count, cells.size()):
					_door(cells[i].x, cells[i].y, s, d)
			if zn.type in [&"office", &"processing"]:
				_room_doors(zn, s)


func _first_side(by_side: Dictionary) -> int:
	for d in 4:
		if not (by_side[d] as Array).is_empty():
			return d
	return -1


## Spanning tree of doors between rooms on one storey, plus a few loops.
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
	var keys := pairs.keys()
	_shuffle(keys)
	var parent := {}
	var find := func(a: int) -> int:
		while parent.get(a, a) != a:
			a = parent[a]
		return a
	for key: String in keys:
		var ab := key.split(":")
		var ra: int = find.call(int(ab[0]))
		var rb: int = find.call(int(ab[1]))
		var spots: Array = pairs[key]
		var spot: Array = spots[rng.randi_range(0, spots.size() - 1)]
		if ra != rb:
			parent[ra] = rb
			_door(spot[0], spot[1], s, spot[2])
		elif rng.randf() < 0.2:
			_door(spot[0], spot[1], s, spot[2])


# --- 5. Collapse --------------------------------------------------------------------------

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
						and L.kind[i] != LevelLayout.Kind.CATWALK:
					L.flags[i] |= LevelLayout.ROOF_HOLE
				# Floors fallen through onto the storey below.
				if s >= 1 and L.kind[i] == LevelLayout.Kind.FLOOR and style.collapse_chance > 0.0 \
						and rng.randf() < style.collapse_chance and L.flags[i] & (LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) == 0 \
						and L.kind_at(x, z, s - 1) == LevelLayout.Kind.FLOOR \
						and not L.has_flag(x, z, s - 1, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) and not _near_stair(x, z, s):
					L.kind[i] = LevelLayout.Kind.HOLE


func _near_stair(x: int, z: int, s: int) -> bool:
	for d in LevelLayout.DIRS:
		var n := Vector2i(x, z) + d
		for ss in [s - 1, s]:
			if L.has_flag(n.x, n.y, ss, LevelLayout.STAIR):
				return true
	return false


# --- 6. Spawn and connectivity --------------------------------------------------------------

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
					elif L.zone_of(x, z, s).type == &"corridor":
						L.kind[i] = LevelLayout.Kind.EMPTY
						L.zone[i] = -1


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


## Walls of this cell that can carry a fixture (no door, no ramp strip).
func _free_walls(c: Vector3i) -> Array[int]:
	var out: Array[int] = []
	for d in 4:
		if L.has_wall(c.x, c.y, c.z, d) and not L.has_door(c.x, c.y, c.z, d):
			if L.has_flag(c.x, c.y, c.z, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE) and L.stair_side(c.x, c.y, c.z) == d:
				continue
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


func _scatter(c: Vector3i, margin: float = 1.6) -> Vector3:
	## Random point in a cell, kept off the ramp strip.
	var o := L.cell_origin(c.x, c.y, c.z)
	for i in 8:
		var p := Vector2(rng.randf_range(margin, L.cell - margin), rng.randf_range(margin, L.cell - margin))
		if L.has_flag(c.x, c.y, c.z, LevelLayout.STAIR | LevelLayout.STAIR_ABOVE):
			var side := L.stair_side(c.x, c.y, c.z)
			var v := LevelLayout.DIRS[side]
			var lateral := p.x if v.x != 0 else p.y
			var near_side := lateral > L.cell * 0.5 if (v.x > 0 or v.y > 0) else lateral < L.cell * 0.5
			if near_side:
				continue
		return o + Vector3(p.x, 0.05, p.y)
	return L.cell_center(c.x, c.y, c.z) + Vector3.UP * 0.05


func _place_enemies() -> void:
	var cells := _reachable_floor_cells().filter(func(c: Vector3i) -> bool: return _dist(c) >= 6)
	_shuffle(cells)
	var placed: Array[Vector3i] = []
	for c: Vector3i in cells:
		if placed.size() >= profile.enemy_count:
			break
		var close := false
		for q in placed:
			if q.z == c.z and Vector2i(q.x, q.y).distance_to(Vector2i(c.x, c.y)) < 4.0:
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
			patrol.append(_scatter(cur, 2.5))
		L.enemies.append({"position": _scatter(c, 2.5), "yaw": rng.randf() * TAU, "patrol": patrol,
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
	var k := 0
	var take := func(filter: Callable) -> Vector3i:
		for j in range(k, cells.size()):
			if filter.call(cells[j]):
				var c: Vector3i = cells[j]
				cells.remove_at(j)
				return c
		return Vector3i(-1, -1, -1)
	var with_wall := func(c: Vector3i) -> bool: return not _free_walls(c).is_empty()
	for n in profile.symbols:
		var c: Vector3i = take.call(func(c2: Vector3i) -> bool:
			return with_wall.call(c2) and L.zone_of(c2.x, c2.y, c2.z).type in [&"office", &"processing", &"corridor"])
		if c.x < 0:
			break
		var walls := _free_walls(c)
		var dir: int = walls[rng.randi_range(0, walls.size() - 1)]
		L.anomalies.append({"kind": &"symbol", "cell": c, "dir": dir, "variant": rng.randi_range(0, 5),
			"position": L.wall_point(c.x, c.y, c.z, dir, rng.randf_range(1.4, 2.4), rng.randf_range(-2.0, 2.0))})
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
			return with_wall.call(c2) and L.zone_of(c2.x, c2.y, c2.z).type in [&"processing", &"warehouse", &"office"])
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
