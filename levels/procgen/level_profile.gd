class_name LevelProfile
extends Resource
## Everything that makes one procedural level different from another: size,
## the kinds of spaces and their looks, enemy and loot density, anomalies,
## atmosphere. A level is a ProceduralLevel scene + one of these.

@export_group("Size")
@export var grid_size := Vector2i(25, 25)
@export var storeys: int = 3
@export var cell_size: float = 8.0
@export var storey_height: float = 4.5
@export var chunk_cells: int = 5
## Building blocks are cut until both sides are at most this many cells.
@export var max_block: int = 8
@export var min_block: int = 3
## District centres; each gets one family (factory, interior, storage).
@export var districts: int = 3
## Chance that a building straddling two districts takes the other one's style.
@export_range(0.0, 1.0) var blend_chance: float = 0.4

@export_group("Spaces")
## Corridor styles, one per family (see ZoneStyle.family).
@export var corridors: Array[ZoneStyle] = []
## Building styles. Their `type` must be one LayoutGenerator knows:
## hall, foundry, processing, office, maintenance, warehouse, storage,
## loading_dock.
@export var buildings: Array[ZoneStyle] = []

@export_group("Population")
@export var enemy_count: int = 8
@export var enemy_id: StringName = &"scavenger"
@export var exits_min: int = 2
@export var exits_max: int = 3
## Weapon ids placed once each, far from the start.
@export var weapon_pickups: PackedStringArray = ["mp5", "ak47", "m16", "m40"]
@export var ammo_pickups: int = 12
## caliber -> [weight, min rounds, max rounds]
@export var ammo_table: Dictionary = {
	".45ACP": [5.0, 7, 14], "9x19": [3.0, 15, 30], "7.62x39": [2.0, 10, 30],
	"5.56x45": [2.0, 10, 30], "7.62x51": [1.0, 5, 10],
}
@export var corpses: int = 4

@export_group("Anomalies")
@export var symbols: int = 3
@export var odd_corpses: int = 2
@export var odd_containers: int = 1

@export_group("Atmosphere")
@export var environment: Environment
@export var ambience: AudioStream
@export var random_sounds: Array[AudioStream] = []


func style_for(type: StringName) -> ZoneStyle:
	for s in buildings:
		if s.type == type:
			return s
	return null


func corridor_for(family: StringName) -> ZoneStyle:
	for s in corridors:
		if s.family == family:
			return s
	return corridors[0] if not corridors.is_empty() else null
