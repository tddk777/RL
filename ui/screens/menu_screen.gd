class_name MenuScreen
extends Control
## Base for full-screen menus: dark backdrop and a left-aligned column.
## Subclasses override build(column) to add their content.

@export var backdrop_alpha: float = 0.88

var column: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(UIStyle.BG, backdrop_alpha)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override(&"margin_left", 120)
	margin.add_theme_constant_override(&"margin_top", 110)
	margin.add_theme_constant_override(&"margin_bottom", 90)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	column = VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	margin.add_child(column)
	build(column)
	_focus_first.call_deferred()


func build(_column: VBoxContainer) -> void:
	pass


func spacer(height: float) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, height)
	column.add_child(s)


func _focus_first() -> void:
	for child in column.get_children():
		if child is Button:
			(child as Button).grab_focus()
			return


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and UI.screen_count() > 1:
		UI.pop_screen()
		get_viewport().set_input_as_handled()
