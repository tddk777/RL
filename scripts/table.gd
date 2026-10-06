extends Node3D
## Table controller: deals the opening hand, tracks what is under the mouse,
## plays clicked hand cards and draws when the deck is clicked.

const CARD_SCENE := preload("res://scenes/card.tscn")
const PICK_MASK := 1 << 1  # "cards" physics layer (layer 2)
const RAY_LENGTH := 100.0
const DEAL_DELAY := 0.08

@export var opening_hand_size: int = 5
@export var max_hand_size: int = 8

var _hovered: Node3D

@onready var _camera: Camera3D = $Camera3D
@onready var _hand: Hand = $Hand
@onready var _play_zone: PlayZone = $PlayZone
@onready var _deck: Deck = $Deck
@onready var _deck_label: Label = $HUD/DeckLabel
@onready var _message_label: Label = $HUD/MessageLabel


func _ready() -> void:
	_deck.count_changed.connect(_on_deck_count_changed)
	_on_deck_count_changed(_deck.count())
	for i in opening_hand_size:
		draw_card()
		await get_tree().create_timer(DEAL_DELAY).timeout


func _physics_process(_delta: float) -> void:
	# Space queries are only safe here, so input handlers read _hovered.
	_set_hovered(_pick())


func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var card := _hand_card(_hovered)
	if card:
		play_card(card)
	elif _hovered is Deck:
		draw_card()


func draw_card() -> void:
	if _hand.get_cards().size() >= max_hand_size:
		_show_message("Hand is full")
		return
	var data := _deck.draw()
	if data == null:
		_show_message("Deck is empty")
		return
	var card: Card = CARD_SCENE.instantiate()
	card.data = data
	_hand.add_child(card)
	card.global_transform = _deck.top_transform()
	_hand.layout()


func play_card(card: Card) -> void:
	card.set_hovered(false)
	_play_zone.add_card(card)
	_hand.layout()


func _pick() -> Node3D:
	var mouse := get_viewport().get_mouse_position()
	var from := _camera.project_ray_origin(mouse)
	var query := PhysicsRayQueryParameters3D.create(from, from + _camera.project_ray_normal(mouse) * RAY_LENGTH, PICK_MASK)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	# Pick areas are direct children of the Card / Deck they belong to.
	return (hit.collider as Node).get_parent() as Node3D


func _set_hovered(target: Node3D) -> void:
	if target == _hovered:
		return
	if _hovered is Card:
		(_hovered as Card).set_hovered(false)
	_hovered = target
	var card := _hand_card(_hovered)
	if card:
		card.set_hovered(true)


## Returns [param target] as a Card if it is in the hand. Played cards ignore
## hover and clicks.
func _hand_card(target: Node3D) -> Card:
	var card := target as Card
	if card and card.get_parent() == _hand:
		return card
	return null


func _on_deck_count_changed(count: int) -> void:
	_deck_label.text = "Deck: %d" % count


func _show_message(text: String) -> void:
	_message_label.text = text
	_message_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(1.2)
	tween.tween_property(_message_label, "modulate:a", 0.0, 0.4)
