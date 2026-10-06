extends MenuScreen
## Title screen.

const MUSIC := "res://assets/audio/ui/menu_drone_loop.wav"


func build(col: VBoxContainer) -> void:
	backdrop_alpha = 1.0
	var sigil := preload("res://ui/screens/sigil.gd").new() as Control
	sigil.set_anchors_preset(Control.PRESET_FULL_RECT)
	sigil.anchor_left = 0.42
	sigil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sigil)
	move_child(sigil, 1)
	col.add_child(UIStyle.title(String(ProjectSettings.get_setting("application/config/name")).to_upper(), 76))
	col.add_child(UIStyle.label("What was learned cannot be unlearned.", 17, UIStyle.DIM))
	spacer(70)
	col.add_child(UIStyle.button("Begin", Game.start_run))
	col.add_child(UIStyle.button("Settings", func() -> void: UI.push_screen(UI.SETTINGS_MENU)))
	col.add_child(UIStyle.button("Quit", Game.quit))
	if ResourceLoader.exists(MUSIC):
		Audio.play_music(load(MUSIC), -4.0, 3.0)
	UI.play_open()
	tree_exiting.connect(func() -> void: Audio.stop_music(1.5))
