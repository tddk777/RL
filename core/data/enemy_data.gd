class_name EnemyData
extends Resource
## Definition of an AI actor type. The scene supplies body, hitboxes and the
## AI state nodes; this resource supplies the numbers. New enemy kinds are a
## new scene (or reuse one) plus a new .tres in res://content/enemies/.

@export var id: StringName
@export var display_name: String = ""
@export var scene: PackedScene
@export var max_health: float = 100.0
@export var weapon: WeaponData

@export_group("Perception")
@export var sight_range: float = 45.0
@export var sight_fov_degrees: float = 110.0
## Seconds of continuous sight at close range before the AI is sure.
@export var detection_time: float = 0.6
@export var hearing_multiplier: float = 1.0

@export_group("Combat")
## Extra aim error in degrees, on top of the weapon's spread.
@export var aim_error: float = 2.2
## Delay between spotting the player and the first shot.
@export var reaction_time: float = 0.55
@export var burst_min: int = 2
@export var burst_max: int = 5
@export var burst_pause: float = 0.7
@export var preferred_range: float = 14.0

@export_group("Movement")
@export var walk_speed: float = 1.6
@export var run_speed: float = 4.2
