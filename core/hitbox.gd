class_name Hitbox
extends Area3D
## A damageable body region on the "hitbox" physics layer. Bullets hit these,
## and the damage goes to the HealthComponent after the zone multiplier.

@export var zone: StringName = &"torso"
@export var damage_multiplier: float = 1.0
@export var health: HealthComponent
## SurfaceData id used for impact effects.
@export var surface: StringName = &"flesh"


func _ready() -> void:
	collision_layer = Layers.HITBOX
	collision_mask = 0
	monitoring = false


func receive_hit(hit: HitInfo) -> void:
	hit.zone = zone
	hit.damage *= damage_multiplier
	if health:
		health.apply_damage(hit)


func set_enabled(enabled: bool) -> void:
	collision_layer = Layers.HITBOX if enabled else 0
