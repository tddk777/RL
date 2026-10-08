class_name LevelLayout
extends RefCounted
## The generated plan of a procedural level: a 3D grid of cells (x, z, storey)
## plus districts, zones (buildings, corridors), rooms and placed entities.
## Pure data, no nodes; LayoutGenerator fills it, ChunkBuilder turns it into
## geometry.
##
## Grid directions: 0 = N (-Z), 1 = E (+X), 2 = S (+Z), 3 = W (-X).

enum Kind { EMPTY, FLOOR, VOID, CATWALK, HOLE }
enum District { FACTORY, INTERIOR, STORAGE }

const DOOR := 1          # << dir: opening in the wall on that edge
const CATWALK_SIDE := 16 # << dir: catwalk strip runs along that side
const STAIR := 256       # a flight starts here and climbs to the landing of this cell one storey up
const STAIR_ABOVE := 512 # a flight from below arrives here: the floor has a hole over its run
const ROOF_HOLE := 1024  # collapsed roof / ceiling above this cell
const DOCK := 2048       # loading bay shutters on exterior edges
const EXIT := 4096       # an exit door is on one of this cell's walls
const NARROW := 8192     # cramped passage: solid fill around a narrow cross of corridors
const BRIDGE_X := 16384  # catwalk bridge through the middle of the cell along X
const BRIDGE_Z := 32768  # catwalk bridge through the middle of the cell along Z
const WINDOW := 65536    # << dir: window in the wall on that edge
const CHAMFER := 1 << 20 # << corner: the building's outer corner is cut at 45 degrees
const PARTIAL := 1 << 24 # << dir: a stub of wall on an open edge inside a room

## Per-cell `extra` flags (the main flags word is full).
const VENT := 1     # << dir: crawl vent through the wall on that edge (crouching player only)
const BREACH := 16  # << dir: a hole broken through the wall on that edge
const PODIUM := 256 # a raised platform stands in the cell (steps up to it)
const PIT := 512    # a sunken pit is let into the floor (steps down into it)
const DROP := 1024  # the floor has broken through in one corner (bits 11-12): a way down, not back up
const SPLIT := 1 << 13  # a partition walls off a small back room along one side (bits 14-15), doorway at one end (bit 16)

## Split cells: the partition's middle is SPLIT_BACK in from that side's edge
## line; it is SPLIT_T thick with a SPLIT_DOOR wide doorway near one end.
const SPLIT_BACK := 3.0
const SPLIT_T := 0.14
const SPLIT_DOOR := 1.2
const SPLIT_DOOR_H := 2.1

## Corners of a cell: 0 = N-W, 1 = N-E, 2 = S-E, 3 = S-W. CORNER_DIRS[c] are
## the two sides that meet there.
const CORNER_DIRS: Array = [[0, 3], [0, 1], [2, 1], [2, 3]]
## How far a chamfer cuts along each of the two walls.
const CHAMFER_CUT := 2.8

## A stair climbs one storey inside its cell column, in a strip STRIP wide
## along one side of the cell (the switchback's shape: ChunkBuilder.Stair).
const STRIP := 3.2

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


class Zone:
	var id: int
	var type: StringName
	var style: ZoneStyle
	var district: int = 0
	## Bounding box of the footprint.
	var rect: Rect2i
	## Footprint: column (Vector2i) -> top storey of that column.
	var cols: Dictionary = {}
	var base: int = 0
	var top: int = 0


class Room:
	var id: int
	var zone: int
	var storey: int
	var rect: Rect2i
	## What the room is used for (set pieces): cubicles, offices, meeting,
	## archive, boiler, electrical, lockers, washroom, workshop, closet,
	## parts, cages, pumps, vats, hallway, stairwell ...
	var use: StringName = &""
	## Extra rects merged into this room (L-shaped rooms).
	var extra: Array[Rect2i] = []

	func has_point(p: Vector2i) -> bool:
		if rect.has_point(p):
			return true
		for r in extra:
			if r.has_point(p):
				return true
		return false


var seed: int
var profile: LevelProfile
var size := Vector2i.ZERO
var storeys: int = 1
## Storeys below ground (index -1, -2...): the maintenance tunnels. Storey 0
## is always the ground floor.
var basement: int = 0
var cell: float = 8.0
var storey_height: float = 4.5

var kind := PackedByteArray()
var zone := PackedInt32Array()
## Room id per cell (index into `rooms` + 1; 0 = open zone space).
var room := PackedInt32Array()
var flags := PackedInt32Array()
var extra := PackedInt32Array()
## Stair info: low nibble = the flight starting here (dir | side << 2),
## high nibble = the flight arriving from below (dir | side << 2).
var stair := PackedByteArray()
## District per column (x, z).
var district := PackedByteArray()
var zones: Array[Zone] = []
var rooms: Array[Room] = []

var spawn_cell := Vector3i.ZERO
var spawn_position := Vector3.ZERO
var spawn_yaw: float = 0.0
## Graph distance (in cells) from the spawn, -1 = unreachable.
var distance := PackedInt32Array()
var max_distance: int = 0

## Entities: Arrays of Dictionaries (see LayoutGenerator for the keys).
var exits: Array = []
var enemies: Array = []
var pickups: Array = []
var anomalies: Array = []
var corpses: Array = []


func setup(p: LevelProfile, level_seed: int) -> void:
	profile = p
	seed = level_seed
	size = p.grid_size
	storeys = p.storeys
	basement = p.basement
	cell = p.cell_size
	storey_height = p.storey_height
	var n := size.x * size.y * (storeys + basement)
	kind.resize(n)
	zone.resize(n)
	zone.fill(-1)
	room.resize(n)
	flags.resize(n)
	extra.resize(n)
	stair.resize(n)
	distance.resize(n)
	distance.fill(-1)
	district.resize(size.x * size.y)


# --- Indexing ---------------------------------------------------------------------

func idx(x: int, z: int, s: int) -> int:
	return ((s + basement) * size.y + z) * size.x + x


func inside(x: int, z: int, s: int) -> bool:
	return x >= 0 and z >= 0 and s >= -basement and x < size.x and z < size.y and s < storeys


## Every storey index, basement first.
func all_storeys() -> Array:
	return range(-basement, storeys)


func kind_at(x: int, z: int, s: int) -> int:
	return kind[idx(x, z, s)] if inside(x, z, s) else Kind.EMPTY


func zone_at(x: int, z: int, s: int) -> int:
	return zone[idx(x, z, s)] if inside(x, z, s) else -1


func room_at(x: int, z: int, s: int) -> int:
	return room[idx(x, z, s)] if inside(x, z, s) else 0


func room_of(x: int, z: int, s: int) -> Room:
	var r := room_at(x, z, s)
	return rooms[r - 1] if r > 0 else null


func flags_at(x: int, z: int, s: int) -> int:
	return flags[idx(x, z, s)] if inside(x, z, s) else 0


func has_flag(x: int, z: int, s: int, flag: int) -> bool:
	return (flags_at(x, z, s) & flag) != 0


func set_flag(x: int, z: int, s: int, flag: int, on := true) -> void:
	var i := idx(x, z, s)
	flags[i] = (flags[i] | flag) if on else (flags[i] & ~flag)


func zone_of(x: int, z: int, s: int) -> Zone:
	var id := zone_at(x, z, s)
	return zones[id] if id >= 0 else null


func style_at(x: int, z: int, s: int) -> ZoneStyle:
	var zn := zone_of(x, z, s)
	return zn.style if zn else null


func district_at(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size.x or z >= size.y:
		return -1
	return district[z * size.x + x]


## The flight starting in this cell.
func stair_dir(x: int, z: int, s: int) -> int:
	return stair[idx(x, z, s)] & 3


func stair_side(x: int, z: int, s: int) -> int:
	return (stair[idx(x, z, s)] >> 2) & 3


## The flight arriving here from the storey below (its hole in this floor).
func hole_dir(x: int, z: int, s: int) -> int:
	return (stair[idx(x, z, s)] >> 4) & 3


func hole_side(x: int, z: int, s: int) -> int:
	return (stair[idx(x, z, s)] >> 6) & 3


## Sides of this cell taken by a stair strip (flight or hole), as a bit mask.
func stair_sides(x: int, z: int, s: int) -> int:
	var m := 0
	if has_flag(x, z, s, STAIR):
		m |= 1 << stair_side(x, z, s)
	if has_flag(x, z, s, STAIR_ABOVE):
		m |= 1 << hole_side(x, z, s)
	return m


func is_walkable(x: int, z: int, s: int) -> bool:
	var k := kind_at(x, z, s)
	return k == Kind.FLOOR or k == Kind.CATWALK


func is_enclosed(x: int, z: int, s: int) -> bool:
	return kind_at(x, z, s) != Kind.EMPTY


## A wall stands on this edge (a door is an opening in a wall).
func has_wall(x: int, z: int, s: int, dir: int) -> bool:
	if not is_enclosed(x, z, s):
		return false
	var n := Vector2i(x, z) + DIRS[dir]
	if not is_enclosed(n.x, n.y, s):
		return true
	var a := idx(x, z, s)
	var b := idx(n.x, n.y, s)
	return zone[a] != zone[b] or room[a] != room[b]


func has_door(x: int, z: int, s: int, dir: int) -> bool:
	return has_flag(x, z, s, DOOR << dir)


func has_window(x: int, z: int, s: int, dir: int) -> bool:
	return has_flag(x, z, s, WINDOW << dir)


func is_exterior(x: int, z: int, dir: int) -> bool:
	var n := Vector2i(x, z) + DIRS[dir]
	return n.x < 0 or n.y < 0 or n.x >= size.x or n.y >= size.y


## Open air on this side at this storey: past the edge of the site or a
## column with nothing built at this storey.
func is_outside(x: int, z: int, s: int, dir: int) -> bool:
	var n := Vector2i(x, z) + DIRS[dir]
	return not is_enclosed(n.x, n.y, s)


func has_chamfer(x: int, z: int, s: int, corner: int) -> bool:
	return has_flag(x, z, s, CHAMFER << corner)


## The chamfered corner at the start (along = 0) or end (along = cell) of
## the wall on `dir`, as a corner index, or -1.
func chamfer_at(x: int, z: int, s: int, dir: int, at_end: bool) -> int:
	for c in 4:
		if not has_chamfer(x, z, s, c):
			continue
		var dirs: Array = CORNER_DIRS[c]
		if dir != dirs[0] and dir != dirs[1]:
			continue
		# Along runs +X for N/S walls and +Z for E/W walls.
		var corner_is_end := (c == 1 or c == 2) if dir % 2 == 0 else (c == 2 or c == 3)
		if corner_is_end == at_end:
			return c
	return -1


func extra_at(x: int, z: int, s: int) -> int:
	return extra[idx(x, z, s)] if inside(x, z, s) else 0


func set_extra(x: int, z: int, s: int, flag: int, on := true) -> void:
	var i := idx(x, z, s)
	extra[i] = (extra[i] | flag) if on else (extra[i] & ~flag)


func has_vent(x: int, z: int, s: int, dir: int) -> bool:
	return extra_at(x, z, s) & (VENT << dir) != 0


func has_breach(x: int, z: int, s: int, dir: int) -> bool:
	return extra_at(x, z, s) & (BREACH << dir) != 0


## A way through the wall on this edge other than a door (breach or vent).
func has_gap(x: int, z: int, s: int, dir: int) -> bool:
	return extra_at(x, z, s) & ((VENT | BREACH) << dir) != 0


func has_drop(x: int, z: int, s: int) -> bool:
	return extra_at(x, z, s) & DROP != 0


func drop_corner(x: int, z: int, s: int) -> int:
	return (extra_at(x, z, s) >> 11) & 3


func has_split(x: int, z: int, s: int) -> bool:
	return inside(x, z, s) and extra_at(x, z, s) & SPLIT != 0


## The side the back room is on.
func split_side(x: int, z: int, s: int) -> int:
	return (extra_at(x, z, s) >> 14) & 3


## The doorway through the partition: start and end along the side's edge span.
func split_door(x: int, z: int, s: int) -> Vector2:
	var mid := 1.75 if (extra_at(x, z, s) >> 16) & 1 == 0 else cell - 1.75
	return Vector2(mid - SPLIT_DOOR * 0.5, mid + SPLIT_DOOR * 0.5)


## Which part of a split cell a cell-local point (x, z in 0..cell) is in.
func in_back_room(x: int, z: int, s: int, local: Vector2) -> bool:
	if not has_split(x, z, s):
		return false
	match split_side(x, z, s):
		0:
			return local.y < SPLIT_BACK
		1:
			return local.x > cell - SPLIT_BACK
		2:
			return local.y > cell - SPLIT_BACK
	return local.x < SPLIT_BACK


func has_partial(x: int, z: int, s: int, dir: int) -> bool:
	return has_flag(x, z, s, PARTIAL << dir)


## Edges of this cell that open onto the next cell on the same storey (open
## space of the same room, or a door - even one onto a collapsed floor), as
## a bit mask.
func open_edges(x: int, z: int, s: int) -> int:
	var m := 0
	for d in 4:
		var n := Vector2i(x, z) + DIRS[d]
		if (has_door(x, z, s, d) or has_breach(x, z, s, d)) and is_enclosed(n.x, n.y, s):
			m |= 1 << d
		elif is_walkable(n.x, n.y, s) and not has_wall(x, z, s, d):
			m |= 1 << d
	return m


# --- World space ------------------------------------------------------------------

func cell_origin(x: int, z: int, s: int) -> Vector3:
	return Vector3(x * cell, s * storey_height, z * cell)


func cell_center(x: int, z: int, s: int) -> Vector3:
	return Vector3((x + 0.5) * cell, s * storey_height, (z + 0.5) * cell)


func world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / cell), clampi(floori((p.y + 0.5) / storey_height), -basement, storeys - 1), floori(p.z / cell))


static func dir_vector(dir: int) -> Vector3:
	var d := DIRS[dir]
	return Vector3(d.x, 0.0, d.y)


## Point on the inner face of the wall on `dir` side, at height h.
func wall_point(x: int, z: int, s: int, dir: int, h: float, along: float = 0.0) -> Vector3:
	var c := cell_center(x, z, s)
	var d := dir_vector(dir)
	var t := dir_vector((dir + 1) % 4)
	return c + d * (cell * 0.5 - 0.17) + t * along + Vector3.UP * h


# --- Graph ------------------------------------------------------------------------

## Walkable cells reachable in one step from (x, z, s). Breaches count; vents
## only with `crawl` (people and navigation can't fit through them).
func links(x: int, z: int, s: int, crawl: bool = false) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not is_walkable(x, z, s):
		return out
	var i := idx(x, z, s)
	for d in 4:
		var n := Vector2i(x, z) + DIRS[d]
		if not is_walkable(n.x, n.y, s):
			continue
		var j := idx(n.x, n.y, s)
		var open := false
		if has_door(x, z, s, d) or has_breach(x, z, s, d) or (crawl and has_vent(x, z, s, d)):
			open = true
		elif zone[i] == zone[j] and room[i] == room[j]:
			if kind[i] == Kind.CATWALK or kind[j] == Kind.CATWALK:
				open = _catwalks_meet(i, j, d)
			else:
				open = true
		if open:
			out.append(Vector3i(n.x, n.y, s))
	# Up the flight that starts here, down the one that arrives here.
	if has_flag(x, z, s, STAIR) and is_walkable(x, z, s + 1):
		out.append(Vector3i(x, z, s + 1))
	if has_flag(x, z, s, STAIR_ABOVE) and is_walkable(x, z, s - 1):
		out.append(Vector3i(x, z, s - 1))
	return out


func _catwalks_meet(i: int, j: int, dir: int) -> bool:
	if kind[i] != Kind.CATWALK or kind[j] != Kind.CATWALK:
		return false
	# A catwalk strip whose near end is a stair opening doesn't connect there.
	if (flags[i] & STAIR_ABOVE and (stair[i] >> 4) & 3 == (dir + 2) % 4) \
			or (flags[j] & STAIR_ABOVE and (stair[j] >> 4) & 3 == dir):
		return false
	var bridge := BRIDGE_X if dir % 2 == 1 else BRIDGE_Z
	if flags[i] & bridge and flags[j] & bridge:
		return true
	var shared := (flags[i] & flags[j]) >> 4 & 15
	for side in 4:
		if shared & (1 << side) and side % 2 != dir % 2:
			return true
	return false


func zone_name(x: int, z: int, s: int) -> String:
	var zn := zone_of(x, z, s)
	return String(zn.type) if zn else "none"


## Text map of one storey (tests and debugging).
func ascii(s: int) -> String:
	var chars := {Kind.EMPTY: " ", Kind.FLOOR: ".", Kind.VOID: "~", Kind.CATWALK: "=", Kind.HOLE: "O"}
	var type_char := {&"corridor": "+", &"connector": "+", &"yard": "#", &"hall": "H", &"foundry": "F", &"warehouse": "W",
		&"processing": "P", &"office": "o", &"maintenance": "m", &"storage": "s", &"loading_dock": "D"}
	var lines := PackedStringArray()
	for z in size.y:
		var row := ""
		for x in size.x:
			var k := kind_at(x, z, s)
			var ch: String = chars[k]
			if k == Kind.FLOOR:
				var zn := zone_of(x, z, s)
				ch = type_char.get(zn.type, ".") if zn else "."
				if has_flag(x, z, s, NARROW):
					ch = ":"
			if has_flag(x, z, s, BRIDGE_X | BRIDGE_Z):
				ch = "="
			if has_flag(x, z, s, STAIR):
				ch = "^"
			if has_flag(x, z, s, EXIT):
				ch = "X"
			if Vector3i(x, z, s) == spawn_cell:
				ch = "S"
			row += ch
		lines.append(row)
	return "\n".join(lines)
