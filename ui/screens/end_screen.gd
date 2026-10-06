extends MenuScreen
## Shown when there is no next level yet.


func build(col: VBoxContainer) -> void:
	col.add_child(UIStyle.title("THE WAY DOWN IS SEALED", 46))
	col.add_child(UIStyle.label("This is the end of the levels built so far.", 17, UIStyle.DIM))
	spacer(40)
	col.add_child(UIStyle.button("Main menu", Game.show_main_menu))
