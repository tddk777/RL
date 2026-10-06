extends MenuScreen
## In-game pause.


func build(col: VBoxContainer) -> void:
	backdrop_alpha = 0.7
	col.add_child(UIStyle.title("PAUSED", 46))
	if Game.level_data:
		col.add_child(UIStyle.label(Game.level_data.display_name, 16, UIStyle.DIM))
	if Game.level is ProceduralLevel:
		col.add_child(UIStyle.label("Seed %d" % Game.level_seed, 14, UIStyle.DIM))
	spacer(40)
	col.add_child(UIStyle.button("Resume", Game.resume))
	col.add_child(UIStyle.button("Settings", func() -> void: UI.push_screen(UI.SETTINGS_MENU)))
	col.add_child(UIStyle.button("Restart level", Game.restart_level))
	col.add_child(UIStyle.button("Main menu", Game.show_main_menu))
