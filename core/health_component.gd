class_name HealthComponent
extends Node
## Hit points for an actor. Hitboxes forward damage here.

signal health_changed(current: float, maximum: float)
signal damaged(hit: HitInfo)
signal died(hit: HitInfo)

@export var max_health: float = 100.0

var current: float
var is_dead: bool = false


func _ready() -> void:
	current = max_health


func apply_damage(hit: HitInfo) -> void:
	if is_dead or hit.damage <= 0.0:
		return
	current = maxf(current - hit.damage, 0.0)
	health_changed.emit(current, max_health)
	damaged.emit(hit)
	Events.actor_damaged.emit(owner, hit)
	if current <= 0.0:
		is_dead = true
		died.emit(hit)
		Events.actor_killed.emit(owner, hit)


func heal(amount: float) -> void:
	if is_dead:
		return
	current = minf(current + amount, max_health)
	health_changed.emit(current, max_health)


func ratio() -> float:
	return current / max_health
