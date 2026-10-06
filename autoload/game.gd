extends Node
## Owns the flow of a run: main menu -> level 1 -> level 2 -> ... -> end.
## Levels are loaded under `world`; the player is spawned at the level's
## PlayerSpawn marker. UI screens are shown through the UI autoload.

enum State { MENU, LOADING, PLAYING, PAUSED, DEAD, FINISHED }

const PLAYER_SCENE := "res://player/player.tscn"

var state: State = State.MENU
var world: Node3D
var level: Level
var level_data: LevelData
var player: Player
## Seed of the current run; each level and each retry derives its own seed.
var run_seed: int = 0
var attempt: int = 0
var level_seed: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.player_died.connect(_on_player_died)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		if state == State.PLAYING:
			pause()
		elif state == State.PAUSED and UI.screen_count() <= 1:
			resume()
		get_viewport().set_input_as_handled()


func show_main_menu() -> void:
	await _unload_level()
	state = State.MENU
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	UI.set_hud_visible(false)
	UI.replace_screen(UI.MAIN_MENU)
	UI.fade_in()


func start_run() -> void:
	var levels := Registry.levels()
	if levels.is_empty():
		push_error("Game: no levels in res://content/levels")
		return
	run_seed = randi()
	attempt = 0
	load_level(levels[0])


func load_level(data: LevelData) -> void:
	state = State.LOADING
	await UI.fade_out()
	await _unload_level()
	UI.clear_screens()
	UI.set_hud_visible(false)
	UI.show_title_card(data.display_name, data.subtitle)
	get_tree().paused = false

	ResourceLoader.load_threaded_request(data.scene_path)
	while ResourceLoader.load_threaded_get_status(data.scene_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var packed := ResourceLoader.load_threaded_get(data.scene_path) as PackedScene
	if packed == null:
		push_error("Game: could not load %s" % data.scene_path)
		show_main_menu()
		return

	level_data = data
	level_seed = absi(hash([run_seed, data.order, attempt])) % 2147483647
	world = Node3D.new()
	world.name = "World"
	get_tree().root.add_child(world)
	level = packed.instantiate() as Level
	if level.has_method(&"configure"):
		level.call(&"configure", level_seed)
	world.add_child(level)
	await level.prepare()
	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	world.add_child(player)
	player.global_transform = level.player_spawn_transform()
	Events.player_spawned.emit(player)
	level.begin()
	Events.level_started.emit(level)

	state = State.PLAYING
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	UI.set_hud_visible(true)
	await get_tree().create_timer(1.2).timeout
	UI.hide_title_card()
	UI.fade_in()


## Retrying generates a fresh layout (new seed) for procedural levels.
func restart_level() -> void:
	if level_data:
		attempt += 1
		load_level(level_data)


## Called by a LevelExit once the player leaves the current level.
func complete_level() -> void:
	if state != State.PLAYING:
		return
	var next := Registry.next_level(level_data)
	if next:
		attempt = 0
		load_level(next)
	else:
		state = State.FINISHED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().paused = true
		UI.set_hud_visible(false)
		UI.replace_screen(UI.END_SCREEN)


func pause() -> void:
	state = State.PAUSED
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	UI.push_screen(UI.PAUSE_MENU)


func resume() -> void:
	UI.clear_screens()
	state = State.PLAYING
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func quit() -> void:
	Settings.save()
	get_tree().quit()


func _on_player_died(_player: Node) -> void:
	if state != State.PLAYING:
		return
	state = State.DEAD
	await get_tree().create_timer(2.0).timeout
	if state != State.DEAD:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	UI.set_hud_visible(false)
	UI.replace_screen(UI.DEATH_SCREEN)


func _unload_level() -> void:
	Ballistics.clear()
	Effects.clear()
	Audio.stop_ambience(0.5)
	if is_instance_valid(world):
		world.queue_free()
		await get_tree().process_frame
	world = null
	level = null
	player = null
