extends Control
## Keeps the scope texture square and centered with black bars at the sides.

@onready var _texture: TextureRect = $Texture
@onready var _left: ColorRect = $Left
@onready var _right: ColorRect = $Right


func _ready() -> void:
	resized.connect(_layout)
	_layout()


func _layout() -> void:
	var side := size.y
	var x := (size.x - side) * 0.5
	_texture.position = Vector2(x, 0)
	_texture.size = Vector2(side, side)
	_left.position = Vector2.ZERO
	_left.size = Vector2(maxf(x, 0.0) + 1.0, size.y)
	_right.position = Vector2(x + side - 1.0, 0)
	_right.size = Vector2(maxf(x, 0.0) + 1.0, size.y)
