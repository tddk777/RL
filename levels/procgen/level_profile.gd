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
## Maintenance tunnels under the site (0 = none, 1 = a tunnel storey below
## ground): passages joining the buildings' stairwells and halls, with plant
## rooms and sumps off them.
@export_range(0, 1) var basement: int = 0
@export var tunnel_rooms: int = 4
## Extra tunnel links beyond the ones that join everything (loops).
@export var tunnel_loops: int = 2
## Share of the site covered by buildings; the rest is yards and open ground.
@export_range(0.1, 0.9) var coverage: float = 0.42
@export var max_buildings: int = 22
## Chance a new building is built against its neighbour instead of being
## joined to it by a covered walkway.
@export_range(0.0, 1.0) var touch_chance: float = 0.45
## Longest walkway, in cells.
@export var max_gap: int = 3
## Chance a building may also touch buildings other than the one it grew from.
@export_range(0.0, 1.0) var abut_chance: float = 0.3
## Open-air courtyards and bridges between upper floors.
@export var yards: int = 2
@export var bridges: int = 2
## Chance per eligible outer corner of being cut at 45 degrees.
@export_range(0.0, 1.0) var chamfer_chance: float = 0.3
## Chance per room of a stub of wall partly dividing it.
@export_range(0.0, 1.0) var partial_chance: float = 0.35
## District centres; each gets one family (factory, interior, storage).
@export var districts: int = 3
## Odd ways through: holes broken in walls (anyone fits), crawl vents (the
## crouching player only), and small dead-end rooms sealed so a vent is the
## only way in.
@export var breaches: int = 14
@export var vents: int = 12
@export var stashes: int = 2
## Changes of level inside a storey: chance per open floor cell of a raised
## platform (machine plinth, control stand, loading stage) or a sunken pit
## (machine pit, sump) with steps.
@export_range(0.0, 1.0) var podium_chance: float = 0.14
@export_range(0.0, 1.0) var pit_chance: float = 0.07
## Drop-downs: a corner of an upper floor broken through onto the room below,
## put where it saves the longest walk round (one way: no climbing back).
@export var drops: int = 3
## Chance a one-cell office, archive, meeting, electrical, locker, parts or workshop
## room is split: a partition walls off a small back room (closet, archive,
## parts) along one side.
@export_range(0.0, 1.0) var split_chance: float = 0.0

@export_group("Spaces")
## Walkway styles, one per family (see ZoneStyle.family): covered passages
## between buildings and bridges between upper floors.
@export var corridors: Array[ZoneStyle] = []
## Open-air courtyards.
@export var yard: ZoneStyle
## The maintenance tunnels (type `tunnel`; narrow).
@export var tunnel: ZoneStyle
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
@export var weapon_pickups: PackedStringArray = ["mp5", "ak47", "m16", "m40", "makarov", "tokarev", "ppsh41", "sks"]
@export var ammo_pickups: int = 14
## caliber -> [weight, min rounds, max rounds]
@export var ammo_table: Dictionary = {
	".45ACP": [5.0, 7, 14], "9x19": [3.0, 15, 30], "7.62x39": [2.0, 10, 30],
	"5.56x45": [2.0, 10, 30], "7.62x51": [1.0, 5, 10], "9x18": [3.0, 8, 16],
	"7.62x25": [2.0, 10, 35],
}
@export var corpses: int = 4

@export_group("Anomalies")
@export var symbols: int = 3
@export var odd_corpses: int = 2
@export var odd_containers: int = 1

@export_group("Atmosphere")
@export var environment: Environment
## Overcast daylight (a soft directional light with shadows, so it only
## reaches inside through windows, doors and roof holes). 0 = none.
@export var daylight_energy: float = 0.8
@export var daylight_color := Color(0.86, 0.89, 0.95)
## Faint god rays and lens glare toward the sun (lens_effects compositor;
## Forward+/Mobile only, medium quality and up). Alpha sets the strength.
@export var sun_rays := Color(0.45, 0.43, 0.38, 0.35)
## Ground round the buildings and the distant skyline.
@export var ground_material: StringName = &"ground"
## Rolling landscape outside the site fence (flat inside it and for a strip
## round it, rising into embankments and hills). Off: a flat ground plane.
@export var terrain: bool = true
## Highest the hills get (m), reached a couple of hundred metres out.
@export var terrain_height: float = 22.0
@export var terrain_material: StringName = &"terrain_ground"
## Build the landscape with the Terrain3D extension instead of a mesh.
## Off by default: Terrain3D 1.0.2 crashed Godot 4.7.2's Vulkan renderer in
## testing (any Terrain3D node, even empty). Try it after updating the addon.
@export var use_terrain3d: bool = false
@export var skyline: bool = true
@export var ambience: AudioStream
@export var ambience_bed: AudioStream
@export var ambience_bed_volume_db: float = -14.0
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
