class_name ZoneStyle
extends Resource
## Look and dressing for one kind of space (a factory hall, an office block,
## a maintenance corridor...). `type` selects the layout rules in
## LayoutGenerator; everything else here is look and density.

@export var type: StringName = &"corridor"
## Relative chance among the styles allowed for a building's size.
@export var weight: float = 1.0
## Storeys above the ground floor (min, max). 0 = single storey.
@export var extra_storeys := Vector2i(0, 1)

@export_group("Materials")
@export var floor_material: StringName = &"concrete_floor"
@export var upper_floor_material: StringName = &"concrete_floor"
@export var wall_material: StringName = &"concrete_wall"
@export var upper_wall_material: StringName = &"brick"
@export var ceiling_material: StringName = &"concrete_dark"
@export var floor_surface: StringName = &"concrete"

@export_group("Openings")
@export var door_width: float = 1.8
@export var door_height: float = 2.6
@export var ground_door_width: float = 1.8
@export var ground_door_height: float = 2.6
@export var windows: bool = false

@export_group("Lighting")
## &"fluorescent", &"cage", &"hanging", &"none"
@export var light_kind: StringName = &"cage"
@export_range(0.0, 1.0) var light_chance: float = 0.5
@export_range(0.0, 1.0) var light_working: float = 0.6
@export_range(0.0, 1.0) var flicker_chance: float = 0.2
@export var light_color: Color = Color(1.0, 0.8, 0.55)
@export var light_energy: float = 1.4

@export_group("Dressing")
## Kit prop id -> weight, used for wall-side props.
@export var props: Dictionary = {}
@export_range(0.0, 1.0) var prop_density: float = 0.35
## Overhead pipe runs (corridors and processing).
@export_range(0.0, 1.0) var pipe_chance: float = 0.0
@export_range(0.0, 1.0) var leak_chance: float = 0.0
@export_range(0.0, 1.0) var collapse_chance: float = 0.0
@export_range(0.0, 1.0) var roof_hole_chance: float = 0.0
