class_name LevelData
extends Resource
## One stage of a run. Levels play in ascending `order`.

@export var id: StringName
@export var display_name: String = ""
@export var subtitle: String = ""
@export var order: int = 0
## Path, not PackedScene, so the Registry doesn't load every level up front.
@export_file("*.tscn") var scene_path: String
