class_name AIState
extends Node
## One behaviour of an NPC. The AIBrain calls enter/exit/update on the active
## state; states switch by calling brain.change(&"state_name"). Add new
## behaviours by adding new state nodes to an enemy scene.

var npc: NPC
var brain: AIBrain


func enter(_from: StringName) -> void:
	pass


func exit() -> void:
	pass


func update(_delta: float) -> void:
	pass


## Shared checks most states use to escalate.
func check_threats() -> bool:
	if npc.perception.is_alerted():
		brain.change(&"combat")
		return true
	if npc.perception.has_heard and brain.has_state(&"investigate"):
		npc.perception.has_heard = false
		brain.change(&"investigate")
		return true
	return false
