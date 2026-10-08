class_name AmmoData
extends ItemData
## One cartridge type. Weapons accept ammo whose caliber matches theirs.

@export var caliber: StringName
@export var damage: float = 40.0
## Multiplies the weapon's muzzle velocity (e.g. subsonic loads < 1).
@export var velocity_multiplier: float = 1.0
@export var tracer: bool = false
@export var tracer_color: Color = Color(1.0, 0.55, 0.25)
## Projectiles per round (buckshot: 9) and how wide they spread (degrees).
## `damage` is per projectile.
@export var pellets: int = 1
@export var pellet_spread: float = 0.0
