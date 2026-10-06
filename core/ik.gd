class_name IK
## Small inverse-kinematics helpers.


## Two-bone solve. Returns the elbow/knee position for a chain rooted at
## `root` reaching for `target`, bending toward `pole`.
static func two_bone(root: Vector3, target: Vector3, pole: Vector3, upper: float, lower: float) -> Vector3:
	var to_target := target - root
	var dist := clampf(to_target.length(), 0.001, upper + lower - 0.0005)
	var dir := to_target.normalized() if to_target.length() > 0.0001 else Vector3.FORWARD
	var along := (upper * upper - lower * lower + dist * dist) / (2.0 * dist)
	var height := sqrt(maxf(upper * upper - along * along, 0.0))
	var bend := pole - root
	bend = bend - dir * bend.dot(dir)
	if bend.length() < 0.0001:
		bend = dir.cross(Vector3.RIGHT)
	return root + dir * along + bend.normalized() * height
