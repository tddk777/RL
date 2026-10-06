class_name AIBrain
extends Node
## State machine for an NPC. Child nodes are AIState scripts named after the
## state (idle, patrol, investigate, combat, dead...).

signal state_changed(from: StringName, to: StringName)

@export var initial_state: StringName = &"idle"

var current: AIState
var current_name: StringName = &""
var _states: Dictionary = {}


func setup(npc: NPC) -> void:
	for child in get_children():
		if child is AIState:
			var state := child as AIState
			state.npc = npc
			state.brain = self
			_states[StringName(child.name.to_lower())] = state
	change(initial_state)


func has_state(state_name: StringName) -> bool:
	return _states.has(state_name)


func change(state_name: StringName) -> void:
	if not _states.has(state_name) or state_name == current_name:
		return
	var previous := current_name
	if current:
		current.exit()
	current = _states[state_name]
	current_name = state_name
	current.enter(previous)
	state_changed.emit(previous, state_name)


func update(delta: float) -> void:
	if current:
		current.update(delta)
