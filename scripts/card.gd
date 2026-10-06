class_name Card
extends Node3D
## A single card. The root transform belongs to whatever lays the card out
## (Hand, PlayZone); hover feedback only moves the Visual child so the two
## never fight over the same transform.

const SIZE := Vector3(1.26, 0.02, 1.76)  # 63 x 88 mm poker-card ratio, lying flat
const MOVE_TIME := 0.25
const HOVER_TIME := 0.15
# Hovered cards rise toward the camera and slide up so the whole face shows.
const HOVER_OFFSET := Vector3(0.0, 0.35, -0.45)
const HOVER_SCALE := 1.15

@export var data: CardData:
	set(value):
		data = value
		if is_node_ready():
			_apply_data()

var _hovered := false
var _move_tween: Tween
var _hover_tween: Tween

@onready var _visual: Node3D = $Visual
@onready var _mesh: MeshInstance3D = $Visual/Mesh
@onready var _title_label: Label3D = $Visual/TitleLabel
@onready var _cost_label: Label3D = $Visual/CostLabel
@onready var _body_label: Label3D = $Visual/BodyLabel


func _ready() -> void:
	_apply_data()


## Tweens the card's local transform to [param target].
func move_to(target: Transform3D, duration: float = MOVE_TIME) -> void:
	if _move_tween:
		_move_tween.kill()
	_move_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_move_tween.tween_property(self, "transform", target, duration)


func set_hovered(value: bool) -> void:
	if _hovered == value:
		return
	_hovered = value
	if _hover_tween:
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(_visual, "position", HOVER_OFFSET if value else Vector3.ZERO, HOVER_TIME)
	_hover_tween.tween_property(_visual, "scale", Vector3.ONE * (HOVER_SCALE if value else 1.0), HOVER_TIME)


func _apply_data() -> void:
	if data == null:
		return
	_title_label.text = data.title
	_cost_label.text = str(data.cost)
	_body_label.text = data.description
	var material := StandardMaterial3D.new()
	material.albedo_color = data.color
	material.roughness = 0.85
	_mesh.material_override = material
