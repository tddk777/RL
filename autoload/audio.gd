extends Node
## Plays one-shot sounds from pools so gameplay code never manages players.
## Buses: Master > SFX > (World, Weapons); Ambience; Music; UI.

const POOL_3D := 48
const POOL_2D := 16

var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer] = []
var _next_3d := 0
var _next_2d := 0
var _ambience: AudioStreamPlayer
var _music: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var holder := Node3D.new()
	holder.name = "Players3D"
	add_child(holder)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"World"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.max_polyphony = 1
		holder.add_child(p)
		_pool_3d.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool_2d.append(p)
	_ambience = AudioStreamPlayer.new()
	_ambience.bus = &"Ambience"
	add_child(_ambience)
	_music = AudioStreamPlayer.new()
	_music.bus = &"Music"
	add_child(_music)


## Picks a random stream from a list, or null when empty.
static func pick(streams: Array) -> AudioStream:
	return streams.pick_random() if not streams.is_empty() else null


func play_3d(stream: AudioStream, position: Vector3, bus: StringName = &"World",
		volume_db: float = 0.0, unit_size: float = 6.0, pitch_jitter: float = 0.05,
		max_distance: float = 0.0) -> AudioStreamPlayer3D:
	if stream == null:
		return null
	var p := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % POOL_3D
	p.stop()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.unit_size = unit_size
	p.max_distance = max_distance
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.global_position = position
	p.play()
	return p


func play_2d(stream: AudioStream, bus: StringName = &"SFX", volume_db: float = 0.0,
		pitch_jitter: float = 0.0) -> AudioStreamPlayer:
	if stream == null:
		return null
	var p := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % POOL_2D
	p.stop()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()
	return p


func play_ambience(stream: AudioStream, volume_db: float = 0.0, fade: float = 2.0) -> void:
	_crossfade(_ambience, stream, volume_db, fade)


func play_music(stream: AudioStream, volume_db: float = 0.0, fade: float = 2.0) -> void:
	_crossfade(_music, stream, volume_db, fade)


func stop_ambience(fade: float = 1.0) -> void:
	_crossfade(_ambience, null, 0.0, fade)


func stop_music(fade: float = 1.0) -> void:
	_crossfade(_music, null, 0.0, fade)


func _crossfade(player: AudioStreamPlayer, stream: AudioStream, volume_db: float, fade: float) -> void:
	if player.stream == stream and player.playing:
		return
	var tween := create_tween()
	if player.playing:
		tween.tween_property(player, "volume_db", -60.0, fade * 0.5)
	tween.tween_callback(func() -> void:
		player.stop()
		player.stream = stream
		if stream:
			player.volume_db = -60.0
			player.play())
	if stream:
		tween.tween_property(player, "volume_db", volume_db, fade * 0.5)
