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
## If set, each one carries one of these instead (pick weighted by `weapon_weights`).
@export var weapon_pool: Array[WeaponData] = []
@export var weapon_weights: Array[float] = []

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

@export_group("Tactics")
## How readily they push, flank and run and gun (0 cautious .. 1 reckless).
## Each one rolls their own around this, +- aggression_spread.
@export_range(0.0, 1.0) var aggression: float = 0.5
@export var aggression_spread: float = 0.25
## Marksmanship (0 poor .. 1 sharp): how fast the aim settles and how tight it gets.
@export_range(0.0, 1.0) var skill: float = 0.5
@export var skill_spread: float = 0.2
## Seconds of tracking for the aim to settle from its first, wild shots.
@export var aim_settle_time: float = 1.2
## The first shots' aim error, as a multiple of the settled one.
@export var first_shot_error: float = 2.6
## Below this share of health they want out of the fight.
@export var retreat_health: float = 0.35
## How much fire it takes to pin them down (higher = steadier).
@export var suppression_tolerance: float = 1.0
## How far they look for cover (m).
@export var cover_radius: float = 14.0
## How far they shout what they've seen to the others (m).
@export var callout_range: float = 26.0

@export_group("Movement")
@export var walk_speed: float = 1.6
@export var run_speed: float = 4.2
@export var crouch_speed: float = 1.1
