class_name ModelProps
extends RefCounted
## Realistic props from scanned models (Poly Haven, CC0: see
## assets/third_party/polyhaven/SOURCES.md, fetched by
## dev/asset_gen/fetch_polyhaven.py). They place like kit props
## (`ChunkBuilder.kit(d, id, pos, yaw)`): each glTF is baked once into one mesh
## with its origin moved to where it meets what holds it, and chunks only
## record transforms (so worker threads never touch the meshes);
## ProceduralLevel draws one MultiMesh per model per chunk.
##
## Origins: `base` = middle of the underside (stands on a floor or a bench
## top), `back` = middle of the bottom of the back (hangs on a wall, front
## toward +Z), `native` = as modelled (the vice's jaw sits on the bench edge).
## Front is +Z for all of them, as for kit props.

const DIR := "res://assets/third_party/polyhaven/models/"
## id -> {model, surface, origin, solid (box collider from the bounds; for
## compact things), parts (open things: a movement-only box round the bounds
## plus CollisionBoxes from the mesh for bullets), scale (models that come in
## other units), far (m, culled beyond)}. Neither: no collision (things hung
## on walls).
const MODELS := {
	"barrel_red": {"model": "Barrel_01", "solid": true},
	"barrel_plastic": {"model": "Barrel_02", "solid": true},
	"barrel_steel": {"model": "barrel_03", "solid": true},
	"cardboard_box": {"model": "cardboard_box_01", "surface": &"wood", "solid": true, "far": 45.0},
	"tool_chest": {"model": "metal_tool_chest", "solid": true},
	"toolbox": {"model": "metal_toolbox", "solid": true, "far": 30.0},
	"rack_wide": {"model": "steel_frame_shelves_01", "parts": true, "scale": 0.1},
	"rack_narrow": {"model": "steel_frame_shelves_02", "parts": true},
	"rack_worn": {"model": "worn_metal_rack", "parts": true},
	"office_desk": {"model": "metal_office_desk", "parts": true},
	"school_chair": {"model": "SchoolChair_01", "parts": true, "far": 40.0},
	"wet_floor_sign": {"model": "WetFloorSign_01", "parts": true, "far": 35.0},
	"fire_alarm": {"model": "fire_alarm", "origin": &"back", "far": 25.0},
	"power_box": {"model": "power_box_01", "origin": &"back", "far": 40.0},
	"utility_box": {"model": "utility_box_01", "solid": true},
	"utility_box_wide": {"model": "utility_box_02", "solid": true},
	"hand_truck": {"model": "hand_truck", "parts": true, "far": 45.0},
	"tool_cart": {"model": "tool_cart", "parts": true},
	"storage_cart": {"model": "industrial_storage_cart", "parts": true},
	"cement_bag": {"model": "cement_bag", "surface": &"concrete", "solid": true, "far": 40.0},
	"bins": {"model": "metal_trash_can", "solid": true},
	"tyre": {"model": "old_tyre", "surface": &"wood", "solid": true, "far": 50.0},
	"road_barrier": {"model": "concrete_road_barrier", "surface": &"concrete", "solid": true},
	"ladder": {"model": "ladder_sectioned_01", "parts": true, "far": 50.0},
	"vice": {"model": "bench_vice_01", "origin": &"native", "solid": true, "far": 25.0},
	"drill_press": {"model": "drill_press_01", "parts": true, "far": 35.0},
	"generator": {"model": "portable_generator", "solid": true},
	"stool": {"model": "metal_stool_01", "parts": true, "far": 35.0},
	"camera": {"model": "security_camera_01", "origin": &"back", "far": 35.0},
}

## id -> ArrayMesh (origin moved, scale applied)
var meshes: Dictionary = {}
## id -> AABB of the baked mesh
var bounds: Dictionary = {}
## id -> Array of [center, size] boxes (models with `parts`)
var parts: Dictionary = {}
## id -> Array of shelf tops [height, Rect2 (x, z footprint)] found in the
## parts: wide thin horizontal boxes (shelving, a desk top, a cart's decks)
var shelves: Dictionary = {}


## Main thread only (loads scenes).
func _init() -> void:
	for id: String in MODELS:
		var def: Dictionary = MODELS[id]
		var path := "%s%s/%s.gltf" % [DIR, def["model"], def["model"]]
		if not ResourceLoader.exists(path):
			push_warning("ModelProps: missing %s (run dev/asset_gen/fetch_polyhaven.py)" % path)
			continue
		var root := (load(path) as PackedScene).instantiate() as Node3D
		_bake(id, def, root)
		root.free()


func has(id: String) -> bool:
	return meshes.has(id)


func surface(id: String) -> StringName:
	return MODELS[id].get("surface", &"metal")


func solid(id: String) -> bool:
	return MODELS[id].get("solid", false)


## Shelf tops of an open prop (see `shelves`), lowest first, or [].
func shelves_of(id: String) -> Array:
	return shelves.get(id, [])


## Collision boxes for open props, or [] (see `parts` in MODELS).
func parts_of(id: String) -> Array:
	return parts.get(id, [])


func far(id: String) -> float:
	return MODELS[id].get("far", 90.0)


## Size of the baked model.
func size(id: String) -> Vector3:
	return (bounds[id] as AABB).size


func _bake(id: String, def: Dictionary, root: Node3D) -> void:
	var parts: Array = []  # [arrays, material, Transform3D]
	var box := AABB()
	var first := true
	var scale: float = def.get("scale", 1.0)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.ZERO) * _relative(root, mi)
		for i in mi.mesh.get_surface_count():
			var a := mi.mesh.surface_get_arrays(i)
			var mat := mi.get_surface_override_material(i)
			if mat == null:
				mat = mi.mesh.surface_get_material(i)
			parts.append([a, mat, xf])
			for v: Vector3 in a[Mesh.ARRAY_VERTEX]:
				var p := xf * v
				if first:
					box = AABB(p, Vector3.ZERO)
					first = false
				else:
					box = box.expand(p)
	if parts.is_empty():
		return
	var c := box.get_center()
	var shift: Vector3
	match def.get("origin", &"base"):
		&"back":
			shift = -Vector3(c.x, box.position.y, box.position.z)
		&"native":
			shift = Vector3.ZERO
		_:
			shift = -Vector3(c.x, box.position.y, c.z)
	var mesh := ArrayMesh.new()
	for part: Array in parts:
		var a: Array = part[0]
		var xf: Transform3D = Transform3D(Basis.IDENTITY, shift) * (part[2] as Transform3D)
		var nb := xf.basis.inverse().transposed()
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		for j in verts.size():
			verts[j] = xf * verts[j]
		a[Mesh.ARRAY_VERTEX] = verts
		if a[Mesh.ARRAY_NORMAL] != null:
			var normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			for j in normals.size():
				normals[j] = (nb * normals[j]).normalized()
			a[Mesh.ARRAY_NORMAL] = normals
		if a[Mesh.ARRAY_TANGENT] != null:
			var tangents: PackedFloat32Array = a[Mesh.ARRAY_TANGENT]
			for j in range(0, tangents.size(), 4):
				var t := (xf.basis * Vector3(tangents[j], tangents[j + 1], tangents[j + 2])).normalized()
				tangents[j] = t.x
				tangents[j + 1] = t.y
				tangents[j + 2] = t.z
			a[Mesh.ARRAY_TANGENT] = tangents
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		mesh.surface_set_material(mesh.get_surface_count() - 1, part[1])
	meshes[id] = mesh
	bounds[id] = AABB(box.position + shift, box.size)
	if def.get("parts", false):
		var tris := PackedVector3Array()
		for i in mesh.get_surface_count():
			tris.append_array(CollisionBoxes.triangles(mesh.surface_get_arrays(i)))
		self.parts[id] = CollisionBoxes.from_triangles(tris)
		self.shelves[id] = CollisionBoxes.shelves(self.parts[id], bounds[id], tris)


static func _relative(root: Node, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = node
	while cur != root and cur != null:
		xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf
