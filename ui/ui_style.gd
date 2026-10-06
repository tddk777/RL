class_name UIStyle
## Shared look for all menus: a Theme built in code plus small widget helpers.

const BG := Color(0.035, 0.035, 0.04, 0.92)
const PANEL := Color(0.06, 0.06, 0.065, 0.96)
const TEXT := Color(0.86, 0.84, 0.79)
const DIM := Color(0.55, 0.54, 0.51)
const ACCENT := Color(0.76, 0.64, 0.39)  # tarnished gold
const DANGER := Color(0.62, 0.16, 0.13)

static var _theme: Theme


static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	var body := SystemFont.new()
	body.font_names = PackedStringArray(["Segoe UI", "Helvetica Neue", "Arial", "DejaVu Sans", "sans-serif"])
	t.default_font = body
	t.default_font_size = 17
	t.set_color(&"font_color", &"Label", TEXT)
	for cls in [&"Button", &"CheckBox", &"OptionButton"]:
		t.set_color(&"font_color", cls, TEXT)
		t.set_color(&"font_hover_color", cls, ACCENT)
		t.set_color(&"font_focus_color", cls, ACCENT)
		t.set_color(&"font_pressed_color", cls, ACCENT.lightened(0.2))
		t.set_color(&"font_disabled_color", cls, DIM.darkened(0.3))
	var empty := StyleBoxEmpty.new()
	var line := StyleBoxFlat.new()
	line.bg_color = Color(0, 0, 0, 0)
	line.border_color = ACCENT
	line.border_width_left = 2
	line.content_margin_left = 14
	line.content_margin_right = 10
	line.content_margin_top = 6
	line.content_margin_bottom = 6
	var plain := line.duplicate() as StyleBoxFlat
	plain.border_color = Color(0, 0, 0, 0)
	t.set_stylebox(&"normal", &"Button", plain)
	t.set_stylebox(&"hover", &"Button", line)
	t.set_stylebox(&"focus", &"Button", line)
	t.set_stylebox(&"pressed", &"Button", line)
	t.set_stylebox(&"disabled", &"Button", plain)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.1, 0.1, 0.105)
	field.border_color = Color(0.25, 0.24, 0.22)
	field.set_border_width_all(1)
	field.set_content_margin_all(6)
	t.set_stylebox(&"normal", &"OptionButton", field)
	var field_hover := field.duplicate() as StyleBoxFlat
	field_hover.border_color = ACCENT
	t.set_stylebox(&"hover", &"OptionButton", field_hover)
	t.set_stylebox(&"focus", &"OptionButton", field_hover)
	t.set_stylebox(&"pressed", &"OptionButton", field_hover)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.2, 0.2, 0.2)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT.darkened(0.25)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", fill)
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", fill)
	t.set_stylebox(&"focus", &"HSlider", empty)
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_content_margin_all(28)
	t.set_stylebox(&"panel", &"PanelContainer", panel)
	_theme = t
	return t


static func title_font() -> Font:
	var serif := SystemFont.new()
	serif.font_names = PackedStringArray(["Cinzel", "Trajan Pro", "Cormorant Garamond", "Georgia", "Times New Roman", "DejaVu Serif", "serif"])
	var variation := FontVariation.new()
	variation.base_font = serif
	variation.spacing_glyph = 6
	return variation


static func label(text: String, size: int = 17, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	return l


static func title(text: String, size: int = 64) -> Label:
	var l := label(text, size)
	l.add_theme_font_override(&"font", title_font())
	return l


static func button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override(&"font_size", 22)
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(func() -> void:
		UI.play_click()
		on_pressed.call())
	b.mouse_entered.connect(UI.play_hover)
	return b
