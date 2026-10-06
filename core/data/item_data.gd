class_name ItemData
extends Resource
## Base for anything that can exist as loot. Specific item kinds (weapons,
## ammo, attachments, and later armor, medical, etc.) extend this.
## Every definition file lives in res://content/<category>/ and is found by
## the Registry through its id.

@export var id: StringName
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
## Model shown when the item lies in the world. Optional for now.
@export var world_model: PackedScene
@export var weight_kg: float = 0.0
