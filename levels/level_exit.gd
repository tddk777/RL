class_name LevelExit
extends Interactable
## Interact to leave the level and continue to the next one.

@export var sound: AudioStream


func _ready() -> void:
	super()
	if prompt == "Use":
		prompt = "Go deeper"


func interact(by: Node) -> void:
	super(by)
	if sound:
		Audio.play_2d(sound, &"SFX")
	Game.complete_level()
