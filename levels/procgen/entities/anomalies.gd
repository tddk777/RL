class_name Anomalies
## The quiet wrongness of Level 1: things that are only slightly off.
##   symbol         an alchemical mark chalked or painted on a wall
##   odd_corpse     0: a body laid out inside a salt circle
##                  1: a body kneeling with its forehead against the wall
##   odd_container  a padlocked wire cage holding something that doesn't
##                  reflect light


static func spawn(level: ProceduralLevel, root: Node3D, record: Dictionary) -> void:
	var dir: int = record["dir"]
	var to_wall := LevelLayout.dir_vector(dir)
	var pos: Vector3 = record["position"]
	match record["kind"]:
		&"symbol":
			var decal := Decal.new()
			decal.texture_albedo = load("res://assets/textures/decals/symbol_%d.png" % record["variant"])
			var size: float = 1.3 + 0.15 * (int(record["variant"]) % 3)
			decal.size = Vector3(size, 0.4, size)
			decal.cull_mask = 1
			root.add_child(decal)
			# Decals project along their -Y axis: point it into the wall. The
			# texture's top is -Z and its left -X, so X runs to the viewer's
			# right and Z points down.
			var up := -to_wall
			var right := Vector3.UP.cross(up).normalized()
			decal.global_transform = Transform3D(Basis(right, up, right.cross(up)), pos)
		&"odd_corpse":
			var corpse := Corpse.new()
			if record["variant"] == 0:
				corpse.pose = Corpse.Pose.SPREAD
				root.add_child(corpse)
				corpse.global_transform = Transform3D(Basis(Vector3.UP, atan2(-to_wall.x, -to_wall.z)), pos)
				var ring := Decal.new()
				ring.texture_albedo = load("res://assets/textures/decals/salt_circle.png")
				ring.size = Vector3(3.2, 0.6, 3.2)
				root.add_child(ring)
				ring.global_position = pos + Vector3(0, 0.05, 0) - to_wall * 0.0 + Basis(Vector3.UP, atan2(-to_wall.x, -to_wall.z)) * Vector3(0, 0, 0.75)
			else:
				corpse.pose = Corpse.Pose.KNEELING
				root.add_child(corpse)
				corpse.global_transform = Transform3D(Basis(Vector3.UP, atan2(-to_wall.x, -to_wall.z)), pos)
		&"odd_container":
			var cage := OddContainer.new()
			root.add_child(cage)
			cage.global_transform = Transform3D(Basis(Vector3.UP, atan2(-to_wall.x, -to_wall.z)), pos)
