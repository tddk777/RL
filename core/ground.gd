class_name Ground
extends RefCounted
## Where things come to rest: the first world surface under a point. Spawned
## things (pickups, bodies) settle onto it, because the navigation mesh they
## are placed from floats a little above the floor and doesn't follow every
## step and slab edge.


## The surface below `p` (looking from `up` above it to `down` below), or `p`
## when there is none in reach.
static func below(world: World3D, p: Vector3, up: float = 0.4, down: float = 1.6, exclude: Array[RID] = []) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * up, p + Vector3.DOWN * down, Layers.WORLD, exclude)
	var hit := world.direct_space_state.intersect_ray(q)
	return hit.position if hit else p


## Moves `node` down (or up) onto the surface below it.
static func settle(node: Node3D, up: float = 0.4, down: float = 1.6, exclude: Array[RID] = []) -> void:
	if is_instance_valid(node) and node.is_inside_tree():
		node.global_position = below(node.get_world_3d(), node.global_position, up, down, exclude)
