class_name PlayZone
extends Node3D
## Area on the table where played cards are laid out in centered rows.

@export var spacing: float = 1.45
@export var row_spacing: float = 2.0
@export var per_row: int = 6


func add_card(card: Card) -> void:
	card.reparent(self)
	layout()


func layout() -> void:
	var cards: Array[Card] = []
	for child in get_children():
		if child is Card:
			cards.append(child)
	for i in cards.size():
		var row := i / per_row
		var in_row := mini(per_row, cards.size() - row * per_row)
		var column := i % per_row
		var origin := Vector3((column - (in_row - 1) / 2.0) * spacing, 0.0, row * row_spacing)
		cards[i].move_to(Transform3D(Basis.IDENTITY, origin))
