class_name Deck
extends Node3D
## Shuffled draw pile built from every CardData resource in card_dir.

signal count_changed(count: int)

const CARD_THICKNESS := 0.012

@export_dir var card_dir: String = "res://data/cards"
@export_range(1, 10) var copies_per_card: int = 2

var _pile: Array[CardData] = []

@onready var _stack: MeshInstance3D = $Stack


func _ready() -> void:
	refill()


func refill() -> void:
	_pile.clear()
	# list_directory() also resolves remapped resources in exported builds.
	for file in ResourceLoader.list_directory(card_dir):
		if not (file.ends_with(".tres") or file.ends_with(".res")):
			continue
		var card_data := load(card_dir.path_join(file)) as CardData
		if card_data == null:
			push_warning("Not a CardData resource: %s" % file)
			continue
		for i in copies_per_card:
			_pile.append(card_data)
	_pile.shuffle()
	_update_stack()


func draw() -> CardData:
	if _pile.is_empty():
		return null
	var top: CardData = _pile.pop_back()
	_update_stack()
	return top


func count() -> int:
	return _pile.size()


## Global transform of the top card, used as the spawn point for drawn cards.
func top_transform() -> Transform3D:
	return global_transform.translated(Vector3.UP * _pile.size() * CARD_THICKNESS)


func _update_stack() -> void:
	var height := _pile.size() * CARD_THICKNESS
	_stack.visible = height > 0.0
	_stack.scale.y = maxf(height, 0.001)
	_stack.position.y = height / 2.0
	count_changed.emit(_pile.size())
