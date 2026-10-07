class_name Level
extends Node3D
## Root of every level scene. Provides the player spawn, starts ambience,
## spawns enemies from EnemySpawn markers and applies graphics settings to the
## level's WorldEnvironment.
##
## Required child: Marker3D "PlayerSpawn". Optional: WorldEnvironment,
## EnemySpawn markers anywhere below, Marker3D nodes in group "cover".

@export var ambience: AudioStream
@export var ambience_volume_db: float = -2.0
## Second looping layer under the ambience (wind, weather).
@export var ambience_bed: AudioStream
@export var ambience_bed_volume_db: float = -14.0
## Distant one-shots (drips, groans) played at random around the player.
@export var random_sounds: Array[AudioStream] = []
@export var random_interval := Vector2(7.0, 18.0)
@export var random_volume_db: float = -6.0
@export_group("Reverb (World bus)")
@export var reverb_room_size: float = 0.75
@export var reverb_damping: float = 0.55
@export var reverb_wet: float = 0.14

var _random_timer: float = 0.0
var _environment: Environment


## Awaited by Game before the player is placed (procedural levels generate
## and load their starting area here).
func prepare() -> void:
	pass


func player_spawn_transform() -> Transform3D:
	var spawn := get_node_or_null(^"PlayerSpawn") as Node3D
	return spawn.global_transform if spawn else Transform3D.IDENTITY


## Called by Game once the player has been placed.
func begin() -> void:
	var world_env := _find_environment(self)
	if world_env:
		_environment = world_env.environment
		Settings.apply_environment(_environment)
		Events.settings_changed.connect(_on_settings_changed)
	_apply_reverb()
	if ambience:
		Audio.play_ambience(ambience, ambience_volume_db, 3.0)
	Audio.play_ambience_bed(ambience_bed, ambience_bed_volume_db, 3.0)
	for spawn in find_children("*", "EnemySpawn", true, false):
		(spawn as EnemySpawn).spawn()
	_random_timer = randf_range(random_interval.x, random_interval.y)


func _process(delta: float) -> void:
	if random_sounds.is_empty():
		return
	_random_timer -= delta
	if _random_timer > 0.0:
		return
	_random_timer = randf_range(random_interval.x, random_interval.y)
	var player := Game.player
	if not is_instance_valid(player):
		return
	var offset := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * randf_range(10.0, 28.0)
	offset.y = randf_range(0.0, 8.0)
	Audio.play_3d(random_sounds.pick_random(), player.global_position + offset, &"World", random_volume_db, 14.0, 0.1)


func _on_settings_changed() -> void:
	if _environment:
		Settings.apply_environment(_environment)


func _apply_reverb() -> void:
	var bus := AudioServer.get_bus_index(&"World")
	if bus < 0:
		return
	for i in AudioServer.get_bus_effect_count(bus):
		var effect := AudioServer.get_bus_effect(bus, i) as AudioEffectReverb
		if effect:
			effect.room_size = reverb_room_size
			effect.damping = reverb_damping
			effect.wet = reverb_wet


static func _find_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node
	for child in node.get_children():
		var found := _find_environment(child)
		if found:
			return found
	return null
