class_name NPCBody
extends Node3D
## What an NPC needs from its body. `Humanoid` (procedural) and `Mannequin`
## (rigged, animated) implement it; any rigged model can, by extending this.

## Where the NPC sees from (perception casts its sight rays from here).
var eye: Node3D


## Creates the hitboxes, all feeding `health`. Returns them (for bullet exclusion).
func setup(_health: HealthComponent) -> Array[Hitbox]:
	return []


func hold_weapon(_weapon: Weapon) -> void:
	pass


## Ground speed in m/s; `run` when the NPC is hurrying.
func set_motion(_speed: float, _run: bool) -> void:
	pass


## Crouched (in cover, sneaking) or standing.
func set_crouch(_crouched: bool) -> void:
	pass


## Walking backward (facing the aim while backing off).
func set_backward(_backward: bool) -> void:
	pass


## A brief flinch when hit.
func flinch(_head: bool) -> void:
	pass


## Points the upper body and weapon at a global position (low ready when not aiming).
func set_aim(_target: Vector3, _aiming: bool) -> void:
	pass


## `direction` is the killing shot's travel direction.
func die(_direction: Vector3) -> void:
	pass


## Instant dead pose for bodies placed in the level (no animation).
## pose: 0 fallen, 1 laid out, 2 slumped (sitting or kneeling).
func pose_dead(_pose: int, _variant: int = 0) -> void:
	pass
