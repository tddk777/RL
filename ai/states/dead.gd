extends AIState
## Terminal state. The body stays as a corpse (future: lootable container).


func enter(_from: StringName) -> void:
	npc.stop()
