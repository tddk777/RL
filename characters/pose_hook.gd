class_name PoseHook
extends SkeletonModifier3D
## Calls `apply(skeleton, delta)` after the animation has posed the skeleton
## and before attachments read it. Lets a body script add procedural layers
## (aim, arm IK) on top of the clips without its own modifier class.

var apply: Callable


func _process_modification_with_delta(delta: float) -> void:
	if apply.is_valid():
		apply.call(get_skeleton(), delta)
