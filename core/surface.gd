class_name Surface
## Resolves which SurfaceData a collider is made of. Level pieces tag their
## physics body with metadata "surface" (e.g. &"metal"); hitboxes carry it as a
## property. Anything untagged counts as concrete.

const DEFAULT := &"concrete"


static func of(collider: Object) -> StringName:
	if collider == null:
		return DEFAULT
	if collider is Hitbox:
		return (collider as Hitbox).surface
	if collider.has_meta(&"surface"):
		return collider.get_meta(&"surface")
	var node := collider as Node
	if node and node.get_parent() and node.get_parent().has_meta(&"surface"):
		return node.get_parent().get_meta(&"surface")
	return DEFAULT
