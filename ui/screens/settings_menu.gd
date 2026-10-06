extends MenuScreen
## Graphics, controls, audio and interface options. Changes apply live and
## are saved when leaving the screen.


func build(col: VBoxContainer) -> void:
	backdrop_alpha = 0.94
	col.add_child(UIStyle.title("SETTINGS", 42))
	spacer(16)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", 40)
	grid.add_theme_constant_override(&"v_separation", 12)
	scroll.add_child(grid)

	_section(grid, "Graphics")
	_option(grid, "Quality", "graphics", "quality", ["Low", "Medium", "High", "Ultra"])
	_check(grid, "Fullscreen", "graphics", "fullscreen")
	_check(grid, "V-Sync", "graphics", "vsync")
	_slider(grid, "Render scale", "graphics", "render_scale", 0.5, 1.0, 0.05, "%d%%", 100.0)
	_slider(grid, "Field of view", "graphics", "fov", 60.0, 100.0, 1.0, "%d")
	_section(grid, "Controls")
	_slider(grid, "Mouse sensitivity", "controls", "mouse_sensitivity", 0.02, 0.4, 0.01, "%.2f")
	_slider(grid, "Aim sensitivity", "controls", "ads_sensitivity", 0.3, 1.5, 0.05, "%.2f")
	_check(grid, "Invert Y", "controls", "invert_y")
	_section(grid, "Audio")
	for bus in ["Master", "SFX", "Ambience", "Music", "UI"]:
		_slider(grid, bus, "audio", bus, 0.0, 1.0, 0.05, "%d%%", 100.0)
	_section(grid, "Interface")
	_check(grid, "Crosshair dot", "interface", "crosshair")
	_check(grid, "Ammo counter", "interface", "ammo_counter")
	spacer(20)
	col.add_child(UIStyle.button("Back", _back))


func _back() -> void:
	Settings.save()
	UI.pop_screen()


func _section(grid: GridContainer, text: String) -> void:
	grid.add_child(UIStyle.label(text.to_upper(), 14, UIStyle.ACCENT))
	grid.add_child(Control.new())


func _row_label(grid: GridContainer, text: String) -> void:
	var l := UIStyle.label(text, 17)
	l.custom_minimum_size = Vector2(240, 0)
	grid.add_child(l)


func _changed(section: String, key: String, value: Variant) -> void:
	Settings.set_value(section, key, value)
	Settings.apply()


func _option(grid: GridContainer, text: String, section: String, key: String, items: Array) -> void:
	_row_label(grid, text)
	var opt := OptionButton.new()
	for item: String in items:
		opt.add_item(item)
	opt.selected = Settings.get_value(section, key)
	opt.custom_minimum_size = Vector2(260, 0)
	opt.item_selected.connect(func(i: int) -> void: _changed(section, key, i))
	grid.add_child(opt)


func _check(grid: GridContainer, text: String, section: String, key: String) -> void:
	_row_label(grid, text)
	var box := CheckBox.new()
	box.button_pressed = Settings.get_value(section, key)
	box.toggled.connect(func(on: bool) -> void: _changed(section, key, on))
	grid.add_child(box)


func _slider(grid: GridContainer, text: String, section: String, key: String, lo: float, hi: float,
		step: float, fmt: String, display_mult: float = 1.0) -> void:
	_row_label(grid, text)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = Settings.get_value(section, key)
	slider.custom_minimum_size = Vector2(220, 20)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var value_label := UIStyle.label(fmt % (slider.value * display_mult), 15, UIStyle.DIM)
	value_label.custom_minimum_size = Vector2(60, 0)
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = fmt % (v * display_mult)
		_changed(section, key, v))
	row.add_child(slider)
	row.add_child(value_label)
	grid.add_child(row)
