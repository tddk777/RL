extends Node
## Simulates every bullet in flight as a projectile with drop. Each physics
## tick a bullet ray-casts from its last position to its next one, so fast
## rounds never tunnel through thin walls. Hits go to Hitbox.receive_hit() and
## Effects.impact().

const MAX_LIFETIME := 3.0
const GRAVITY := Vector3(0.0, -9.81, 0.0)
const FLYBY_RADIUS := 2.0
const FLYBY_SOUNDS := [
	"res://assets/audio/player/bullet_flyby_1.wav",
	"res://assets/audio/player/bullet_flyby_2.wav",
	"res://assets/audio/player/bullet_flyby_3.wav",
]


class Bullet:
	var position: Vector3
	var velocity: Vector3
	var damage: float
	var ammo: AmmoData
	var source: Node
	var exclude: Array[RID]
	var age: float = 0.0
	var flyby_done: bool = false
	var tracer: Node3D


var _bullets: Array[Bullet] = []
var _flyby_streams: Array[AudioStream] = []
## Node whose position counts as "the listener's head" for near-miss sounds.
var listener: Node3D
## The actor owning the listener; its own bullets never fly by.
var listener_owner: Node


func _ready() -> void:
	for path: String in FLYBY_SOUNDS:
		if ResourceLoader.exists(path):
			_flyby_streams.append(load(path))


func fire(origin: Vector3, direction: Vector3, speed: float, damage: float, ammo: AmmoData,
		source: Node, exclude: Array[RID] = []) -> void:
	var b := Bullet.new()
	b.position = origin
	b.velocity = direction.normalized() * speed
	b.damage = damage
	b.ammo = ammo
	b.source = source
	b.exclude = exclude
	if ammo and ammo.tracer:
		b.tracer = Effects.create_tracer(ammo.tracer_color)
	_bullets.append(b)


func clear() -> void:
	for b in _bullets:
		if is_instance_valid(b.tracer):
			b.tracer.queue_free()
	_bullets.clear()


func active_count() -> int:
	return _bullets.size()


func _physics_process(delta: float) -> void:
	if _bullets.is_empty():
		return
	var space := get_viewport().world_3d.direct_space_state
	for i in range(_bullets.size() - 1, -1, -1):
		var b := _bullets[i]
		var next := b.position + b.velocity * delta + GRAVITY * (0.5 * delta * delta)
		var query := PhysicsRayQueryParameters3D.create(b.position, next, Layers.BULLET_MASK, b.exclude)
		query.collide_with_areas = true
		var hit := space.intersect_ray(query)
		var end: Vector3 = hit.position if hit else next
		_check_flyby(b, b.position, end)
		_update_tracer(b, b.position, end)
		if hit:
			_resolve_hit(b, hit)
			_remove(i)
			continue
		b.velocity += GRAVITY * delta
		b.position = next
		b.age += delta
		if b.age > MAX_LIFETIME:
			_remove(i)


func _resolve_hit(b: Bullet, hit: Dictionary) -> void:
	var info := HitInfo.new()
	info.damage = b.damage
	info.position = hit.position
	info.normal = hit.normal
	info.direction = b.velocity.normalized()
	info.source = b.source
	info.ammo = b.ammo
	var collider: Object = hit.collider
	if collider is Hitbox:
		(collider as Hitbox).receive_hit(info)
	elif collider is RigidBody3D:
		(collider as RigidBody3D).apply_impulse(info.direction * 2.0, info.position - (collider as RigidBody3D).global_position)
	Effects.impact(Surface.of(collider), info.position, info.normal, info.direction, collider as Node)


func _check_flyby(b: Bullet, from: Vector3, to: Vector3) -> void:
	if b.flyby_done or not is_instance_valid(listener) or b.source == listener_owner or _flyby_streams.is_empty():
		return
	var head := listener.global_position
	var closest := Geometry3D.get_closest_point_to_segment(head, from, to)
	if closest.distance_to(head) < FLYBY_RADIUS and closest.distance_to(to) > 0.05:
		b.flyby_done = true
		Audio.play_3d(_flyby_streams.pick_random(), closest, &"World", -2.0, 4.0, 0.1)


func _update_tracer(b: Bullet, from: Vector3, to: Vector3) -> void:
	if not is_instance_valid(b.tracer):
		return
	var length := from.distance_to(to)
	if length < 0.01:
		return
	b.tracer.global_position = from.lerp(to, 0.5)
	b.tracer.look_at(to, Vector3.UP if absf(b.velocity.normalized().y) < 0.99 else Vector3.RIGHT)
	b.tracer.scale = Vector3(1.0, 1.0, length)


func _remove(index: int) -> void:
	var b := _bullets[index]
	if is_instance_valid(b.tracer):
		b.tracer.queue_free()
	_bullets.remove_at(index)
