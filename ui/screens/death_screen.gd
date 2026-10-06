extends MenuScreen
## Shown after the player dies.


func build(col: VBoxContainer) -> void:
	backdrop_alpha = 0.82
	col.add_child(UIStyle.title("YOU DIED", 58))
	col.add_child(UIStyle.label("Whatever you carried is gone.", 17, UIStyle.DIM))
	spacer(40)
	col.add_child(UIStyle.button("Try again", Game.restart_level))
	col.add_child(UIStyle.button("Main menu", Game.show_main_menu))
