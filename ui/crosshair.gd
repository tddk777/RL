extends Control
## Small dot at screen center (optional, off by default for realism).


func _draw() -> void:
	draw_circle(size * 0.5, 2.0, Color(0.9, 0.88, 0.82, 0.7))
