extends CanvasLayer
## UI autoload: a stack of full-screen menus, the HUD, the scope overlay, level
## title cards and screen fades. Menu screens are scenes in res://ui/screens/.

const MAIN_MENU := "res://ui/screens/main_menu.tscn"
const PAUSE_MENU := "res://ui/screens/pause_menu.tscn"
const SETTINGS_MENU := "res://ui/screens/settings_menu.tscn"
const DEATH_SCREEN := "res://ui/screens/death_screen.tscn"
const END_SCREEN := "res://ui/screens/end_screen.tscn"

const SOUND_HOVER := "res://assets/audio/ui/hover.wav"
const SOUND_CLICK := "res://assets/audio/ui/click.wav"
const SOUND_OPEN := "res://assets/audio/ui/open.wav"

@onready var hud: HUD = $HUD
@onready var _screens: Control = $Screens
@onready var _scope: Control = $Scope
@onready var _scope_texture: TextureRect = $Scope/Texture
@onready var _title_card: Control = $TitleCard
@onready var _title_label: Label = $TitleCard/VBox/Title
@onready var _subtitle_label: Label = $TitleCard/VBox/Subtitle
@onready var _fade: ColorRect = $Fade

var _stack: Array[Control] = []
var _sounds := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for c in [_screens, _title_card]:
		(c as Control).theme = UIStyle.theme()
	_title_label.add_theme_font_override(&"font", UIStyle.title_font())
	_title_card.modulate.a = 0.0
	_scope.visible = false
	hud.visible = false
	for path in [SOUND_HOVER, SOUND_CLICK, SOUND_OPEN]:
		if ResourceLoader.exists(path):
			_sounds[path] = load(path)


func push_screen(path: String) -> Control:
	var screen := (load(path) as PackedScene).instantiate() as Control
	if not _stack.is_empty():
		_stack.back().visible = false
	_screens.add_child(screen)
	_stack.append(screen)
	return screen


func pop_screen() -> void:
	if _stack.is_empty():
		return
	_stack.pop_back().queue_free()
	if not _stack.is_empty():
		_stack.back().visible = true
	elif Game.state == Game.State.PAUSED:
		Game.resume()


func replace_screen(path: String) -> Control:
	clear_screens()
	return push_screen(path)


func clear_screens() -> void:
	for screen in _stack:
		screen.queue_free()
	_stack.clear()


func screen_count() -> int:
	return _stack.size()


func set_hud_visible(value: bool) -> void:
	hud.visible = value
	if not value:
		set_scope_overlay(null)


func set_scope_overlay(texture: Texture2D) -> void:
	_scope.visible = texture != null
	if texture and _scope_texture.texture != texture:
		_scope_texture.texture = texture


func show_title_card(title: String, subtitle: String) -> void:
	_title_label.text = title.to_upper()
	_subtitle_label.text = subtitle
	var tween := create_tween()
	tween.tween_property(_title_card, "modulate:a", 1.0, 0.6)


func hide_title_card() -> void:
	var tween := create_tween()
	tween.tween_interval(1.5)
	tween.tween_property(_title_card, "modulate:a", 0.0, 1.2)


func fade_out(duration: float = 0.5) -> void:
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", 1.0, duration)
	await tween.finished


func fade_in(duration: float = 1.0) -> void:
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", 0.0, duration)
	await tween.finished


func play_hover() -> void:
	_play(SOUND_HOVER, -6.0)


func play_click() -> void:
	_play(SOUND_CLICK, -2.0)


func play_open() -> void:
	_play(SOUND_OPEN, -4.0)


func _play(path: String, volume: float) -> void:
	if _sounds.has(path):
		Audio.play_2d(_sounds[path], &"UI", volume)
