class_name Hand
extends Node3D
## Lays out its child Cards in a fan facing the camera.

@export var spacing: float = 1.15
@export var max_width: float = 7.5
@export var fan_degrees: float = 4.0
@export var arc_drop: float = 0.06


func get_cards() -> Array[Card]:
	var cards: Array[Card] = []
	for child in get_children():
		if child is Card:
			cards.append(child)
	return cards


func layout() -> void:
	var cards := get_cards()
	var count := cards.size()
	if count == 0:
		return
	var step := spacing
	if count > 1:
		step = minf(spacing, max_width / (count - 1))
	var middle := (count - 1) / 2.0
	for i in count:
		var offset := i - middle
		# Later cards sit slightly higher so they overlap (and get picked) on top.
		var origin := Vector3(offset * step, i * 0.004, offset * offset * arc_drop)
		var basis := Basis(Vector3.UP, deg_to_rad(-offset * fan_degrees))
		cards[i].move_to(Transform3D(basis, origin))
