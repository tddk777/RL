extends Node
## Main scene. Hands control to Game, which shows the main menu.


func _ready() -> void:
	Game.show_main_menu.call_deferred()
