class_name LevelLayout
extends RefCounted
## The generated plan of a procedural level: a 3D grid of cells (x, z, storey)
## plus zones (buildings, corridors) and placed entities. Pure data, no nodes;
## LayoutGenerator fills it, ChunkBuilder turns parts of it into geometry.
##
## Grid directions: 0 = N (-Z), 1 = E (+X), 2 = S (+Z), 3 = W (-X).

enum Kind { EMPTY, FLOOR, VOID, CATWALK, HOLE }

const DOOR := 1          # << dir: opening in the wall on that edge
const CATWALK_SIDE := 16 # << dir: catwalk strip runs along that side
const STAIR := 256       # a ramp starts here and climbs to the neighbour in stair_dir, one storey up
const STAIR_ABOVE := 512 # this cell sits above a ramp: its floor has a hole on the ramp strip
const ROOF_HOLE := 1024  # collapsed roof / ceiling above this cell
const DOCK := 2048       # loading bay shutters on exterior edges
const EXIT := 4096       # an exit door is on one of this cell's walls

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


class Zone:
	var id: int
	var type: StringName
	var style: ZoneStyle
	var rect: Rect2i
	var base: int = 0
	var top: int = 0


var seed: int
var profile: LevelProfile
var size := Vector2i.ZERO
var storeys: int = 1
var cell: float = 8.0
var storey_height: float = 6.0

var kind := PackedByteArray()
var zone := PackedInt32Array()
var room := PackedInt32Array()
var flags := PackedInt32Array()
## Ramp info: bits 0-1 climb direction, bits 2-3 the side the ramp strip is on.
var stair := PackedByteArray()
var zones: Array[Zone] = []

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
	cell = p.cell_size
	storey_height = p.storey_height
	var n := size.x * size.y * storeys
	kind.resize(n)
	zone.resize(n)
	zone.fill(-1)
	room.resize(n)
	flags.resize(n)
	stair.resize(n)
	distance.resize(n)
	distance.fill(-1)


# --- Indexing ---------------------------------------------------------------------

func idx(x: int, z: int, s: int) -> int:
	return (s * size.y + z) * size.x + x


func inside(x: int, z: int, s: int) -> bool:
	return x >= 0 and z >= 0 and s >= 0 and x < size.x and z < size.y and s < storeys


func kind_at(x: int, z: int, s: int) -> int:
	return kind[idx(x, z, s)] if inside(x, z, s) else Kind.EMPTY


func zone_at(x: int, z: int, s: int) -> int:
	return zone[idx(x, z, s)] if inside(x, z, s) else -1


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


func stair_dir(x: int, z: int, s: int) -> int:
	return stair[idx(x, z, s)] & 3


func stair_side(x: int, z: int, s: int) -> int:
	return (stair[idx(x, z, s)] >> 2) & 3


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


func is_exterior(x: int, z: int, dir: int) -> bool:
	var n := Vector2i(x, z) + DIRS[dir]
	return n.x < 0 or n.y < 0 or n.x >= size.x or n.y >= size.y


# --- World space ------------------------------------------------------------------

func cell_origin(x: int, z: int, s: int) -> Vector3:
	return Vector3(x * cell, s * storey_height, z * cell)


func cell_center(x: int, z: int, s: int) -> Vector3:
	return Vector3((x + 0.5) * cell, s * storey_height, (z + 0.5) * cell)


func world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / cell), clampi(floori((p.y + 0.5) / storey_height), 0, storeys - 1), floori(p.z / cell))


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

## Walkable cells reachable in one step from (x, z, s).
func links(x: int, z: int, s: int) -> Array[Vector3i]:
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
		if has_door(x, z, s, d):
			open = true
		elif zone[i] == zone[j] and room[i] == room[j]:
			if kind[i] == Kind.CATWALK or kind[j] == Kind.CATWALK:
				open = _catwalks_meet(i, j, d)
			else:
				open = true
		if open:
			out.append(Vector3i(n.x, n.y, s))
	# Up a ramp that starts here
	if has_flag(x, z, s, STAIR):
		var d := stair_dir(x, z, s)
		var t := Vector2i(x, z) + DIRS[d]
		if is_walkable(t.x, t.y, s + 1):
			out.append(Vector3i(t.x, t.y, s + 1))
	# Down a ramp that arrives here
	if s > 0:
		for d in 4:
			var b := Vector2i(x, z) - DIRS[d]
			if inside(b.x, b.y, s - 1) and has_flag(b.x, b.y, s - 1, STAIR) and stair_dir(b.x, b.y, s - 1) == d \
					and is_walkable(b.x, b.y, s - 1):
				out.append(Vector3i(b.x, b.y, s - 1))
	return out


func _catwalks_meet(i: int, j: int, dir: int) -> bool:
	if kind[i] != Kind.CATWALK or kind[j] != Kind.CATWALK:
		return false
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
	var type_char := {&"corridor": "+", &"hall": "H", &"warehouse": "W", &"processing": "P", &"office": "o", &"loading_dock": "D"}
	var lines := PackedStringArray()
	for z in size.y:
		var row := ""
		for x in size.x:
			var k := kind_at(x, z, s)
			var ch: String = chars[k]
			if k == Kind.FLOOR:
				var zn := zone_of(x, z, s)
				ch = type_char.get(zn.type, ".") if zn else "."
			if has_flag(x, z, s, STAIR):
				ch = "^"
			if has_flag(x, z, s, EXIT):
				ch = "X"
			if Vector3i(x, z, s) == spawn_cell:
				ch = "S"
			row += ch
		lines.append(row)
	return "\n".join(lines)
