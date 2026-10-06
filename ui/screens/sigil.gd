extends Control
## Slowly turning alchemical sigil drawn with primitives (circle, triangle,
## square, hexagram, planetary marks). Background ornament for menus.

@export var color: Color = Color(0.76, 0.64, 0.39, 0.16)
@export var speed: float = 0.03

var _t: float = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.46
	var w := 1.4
	draw_arc(c, r, 0, TAU, 128, color, w, true)
	draw_arc(c, r * 0.96, 0, TAU, 128, color * Color(1, 1, 1, 0.7), w * 0.7, true)
	_ticks(c, r * 0.96, r * 0.9, 72, _t * speed)
	_polygon(c, r * 0.9, 3, -PI * 0.5 + _t * speed * 1.5, w)
	_polygon(c, r * 0.9, 3, PI * 0.5 + _t * speed * 1.5, w * 0.8)
	draw_arc(c, r * 0.45, 0, TAU, 96, color, w, true)
	_polygon(c, r * 0.45 * sqrt(2.0) * 0.5 * 1.414, 4, PI * 0.25 - _t * speed * 2.0, w)
	draw_arc(c, r * 0.16, 0, TAU, 64, color, w, true)
	# Planetary marks at the hexagram points
	for i in 6:
		var a := -PI * 0.5 + _t * speed * 1.5 + TAU * i / 6.0
		var p := c + Vector2(cos(a), sin(a)) * r * 0.9
		draw_arc(p, r * 0.035, 0, TAU, 24, color, w, true)
		match i % 3:
			0:
				draw_line(p + Vector2(0, r * 0.035), p + Vector2(0, r * 0.09), color, w)
				draw_line(p + Vector2(-r * 0.025, r * 0.065), p + Vector2(r * 0.025, r * 0.065), color, w)
			1:
				draw_circle(p, r * 0.008, color)
			2:
				draw_arc(p + Vector2(0, -r * 0.045), r * 0.03, PI * 0.15, PI * 0.85, 12, color, w)
	draw_line(c + Vector2(0, -r), c + Vector2(0, r), color * Color(1, 1, 1, 0.5), w * 0.6)
	draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), color * Color(1, 1, 1, 0.5), w * 0.6)


func _polygon(c: Vector2, r: float, sides: int, start: float, w: float) -> void:
	var pts := PackedVector2Array()
	for i in sides + 1:
		var a := start + TAU * i / sides
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	draw_polyline(pts, color, w, true)


func _ticks(c: Vector2, r0: float, r1: float, count: int, rot: float) -> void:
	for i in count:
		var a := rot + TAU * i / count
		var d := Vector2(cos(a), sin(a))
		var inner := r1 if i % 6 == 0 else lerpf(r0, r1, 0.4)
		draw_line(c + d * r0, c + d * inner, color, 1.0)
