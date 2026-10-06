class_name CardData
extends Resource
## Static definition of one card. Each card is a .tres file in res://data/cards/.

@export var title: String = ""
@export_range(0, 10) var cost: int = 0
@export_multiline var description: String = ""
@export var color: Color = Color(0.85, 0.85, 0.85)
