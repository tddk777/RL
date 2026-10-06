class_name Interactable
extends Area3D
## Something the player can use by looking at it and pressing interact.
## Subclass and override interact(). Lives on the "interact" physics layer.

signal interacted(by: Node)

@export var prompt: String = "Use"
@export var enabled: bool = true


func _ready() -> void:
	collision_layer = Layers.INTERACT
	collision_mask = 0
	monitoring = false


func get_prompt() -> String:
	return prompt


func can_interact(_by: Node) -> bool:
	return enabled


func interact(by: Node) -> void:
	interacted.emit(by)
