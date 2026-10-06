class_name EnemySpawn
extends Marker3D
## Place in a level to spawn an enemy when the level begins. The enemy type is
## an EnemyData id from res://content/enemies/. Patrol points are the
## Marker3D children of `patrol_route` (in order).

@export var enemy_id: StringName = &"scavenger"
@export var patrol_route: Node3D
@export_range(0.0, 1.0) var spawn_chance: float = 1.0


func spawn() -> NPC:
	if randf() > spawn_chance:
		return null
	var data := Registry.enemy(enemy_id)
	if data == null or data.scene == null:
		return null
	var npc := data.scene.instantiate() as NPC
	npc.data = data
	if patrol_route:
		for child in patrol_route.get_children():
			if child is Node3D:
				npc.patrol_points.append((child as Node3D).global_position)
	get_parent().add_child(npc)
	npc.global_transform = global_transform
	return npc
