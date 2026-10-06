class_name GeoBuilder
extends RefCounted
## Thread-safe accumulator for chunk geometry. Everything is plain arrays (no
## nodes, no resources) so it can be filled on a worker thread; the level
## turns it into meshes, collision and occluders on the main thread.
##
##   surfaces   material name -> [vertices, normals]  (one mesh surface each)
##   collision  "surface|layer" -> triangle faces     (one trimesh body each)
##   occluder   vertices + indices                    (occlusion culling)
##   nav        triangle faces used to bake navigation
##
## Accumulates into untyped Arrays (reference semantics, cheap appends) and
## converts to packed arrays once in packed_*().

var surfaces: Dictionary = {}  # mat -> [Array verts, Array normals]
var collision: Dictionary = {}  # key -> Array faces
var occluder_vertices: Array = []
var occluder_indices: Array = []
var nav: Array = []
var visuals: bool = true
## Only geometry intersecting this box goes into `nav` (empty = everything).
var nav_bounds := AABB()

const _FACES := [
	[Vector3(1, 0, 0), [Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(1, -1, 1)]],
	[Vector3(-1, 0, 0), [Vector3(-1, -1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1), Vector3(-1, -1, -1)]],
	[Vector3(0, 1, 0), [Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1)]],
	[Vector3(0, -1, 0), [Vector3(-1, -1, 1), Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, -1, 1)]],
	[Vector3(0, 0, 1), [Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(-1, -1, 1)]],
	[Vector3(0, 0, -1), [Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, -1, -1)]],
]


## Box with optional visual (mat != &""), collision (surface != &"") and
## occluder. `basis` rotates (and may scale) around the center.
func box(center: Vector3, size: Vector3, mat: StringName, surface: StringName = &"", occlude: bool = false,
		basis: Basis = Basis.IDENTITY, layer: int = 1) -> void:
	var half := size * 0.5
	var corners: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var nb := basis.inverse().transposed()
	for face in _FACES:
		normals.append((nb * (face[0] as Vector3)).normalized())
		for c: Vector3 in face[1]:
			corners.append(center + basis * (c * half))
	var in_nav := surface != &"" and (nav_bounds.size == Vector3.ZERO or _intersects(corners))
	var col_key := "%s|%d" % [surface, layer]
	for f in 6:
		var a := corners[f * 4]
		var b := corners[f * 4 + 1]
		var c := corners[f * 4 + 2]
		var d := corners[f * 4 + 3]
		var n := normals[f]
		if visuals and mat != &"":
			_tri(mat, a, b, c, n)
			_tri(mat, a, c, d, n)
		if surface != &"":
			if not collision.has(col_key):
				collision[col_key] = []
			var faces: Array = collision[col_key]
			_append_face(faces, a, b, c, n)
			_append_face(faces, a, c, d, n)
			if in_nav and layer != 0:
				_append_face(nav, a, b, c, n)
				_append_face(nav, a, c, d, n)
	if occlude and visuals:
		var base := occluder_vertices.size()
		for i in 8:
			occluder_vertices.append(center + basis * Vector3(half.x * (1 if i & 1 else -1), half.y * (1 if i & 2 else -1), half.z * (1 if i & 4 else -1)))
		for t in [[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5], [0, 4, 5], [0, 5, 1], [2, 3, 7], [2, 7, 6], [0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]]:
			for k in t:
				occluder_indices.append(base + k)


## Nav-only obstacle (a prop's footprint) - no visuals or collision.
func nav_box(center: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> void:
	var half := size * 0.5
	var corners: Array[Vector3] = []
	for face in _FACES:
		for c: Vector3 in face[1]:
			corners.append(center + basis * (c * half))
	if nav_bounds.size != Vector3.ZERO and not _intersects(corners):
		return
	for f in 6:
		var n := basis * (_FACES[f][0] as Vector3)
		_append_face(nav, corners[f * 4], corners[f * 4 + 1], corners[f * 4 + 2], n)
		_append_face(nav, corners[f * 4], corners[f * 4 + 2], corners[f * 4 + 3], n)


## Cylinder from a to b (visual only), for pipes and rails.
func cylinder(a: Vector3, b: Vector3, radius: float, mat: StringName, segments: int = 8) -> void:
	if not visuals:
		return
	var axis := b - a
	var length := axis.length()
	if length < 0.001:
		return
	var dir := axis / length
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(dir)
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var n0 := side * cos(a0) + up * sin(a0)
		var n1 := side * cos(a1) + up * sin(a1)
		var p0 := a + n0 * radius
		var p1 := a + n1 * radius
		var q0 := b + n0 * radius
		var q1 := b + n1 * radius
		_tri_n(mat, p0, p1, q1, n0, n1, n1)
		_tri_n(mat, p0, q1, q0, n0, n1, n0)


## Appends another mesh (e.g. an I-beam built with MeshKit). `arrays` is
## material name -> [vertices, normals] in the mesh's local space.
func mesh(arrays: Dictionary, xform: Transform3D) -> void:
	if not visuals:
		return
	var nb := xform.basis.inverse().transposed()
	for mat: StringName in arrays:
		var src: Array = arrays[mat]
		var v: PackedVector3Array = src[0]
		var n: PackedVector3Array = src[1]
		var dst := _surface(mat)
		var dv: Array = dst[0]
		var dn: Array = dst[1]
		for i in v.size():
			dv.append(xform * v[i])
			dn.append((nb * n[i]).normalized())


func _surface(mat: StringName) -> Array:
	if not surfaces.has(mat):
		surfaces[mat] = [[], []]
	return surfaces[mat]


## Packed results, filled by finalize() (call on the worker thread so the
## main thread only hands finished arrays to the engine).
var packed_surfaces: Dictionary = {}  # mat -> mesh arrays
var packed_collisions: Dictionary = {}  # key -> PackedVector3Array
var packed_occluder_vertices := PackedVector3Array()
var packed_occluder_indices := PackedInt32Array()


func finalize() -> void:
	for mat: StringName in surfaces:
		packed_surfaces[mat] = packed_surface(mat)
	for key: String in collision:
		packed_collisions[key] = packed_collision(key)
	packed_occluder_vertices = PackedVector3Array(occluder_vertices)
	packed_occluder_indices = PackedInt32Array(occluder_indices)
	surfaces.clear()
	collision.clear()
	occluder_vertices.clear()
	occluder_indices.clear()


## Mesh arrays ready for ArrayMesh.add_surface_from_arrays().
func packed_surface(mat: StringName) -> Array:
	var s: Array = surfaces[mat]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(s[0])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(s[1])
	return arrays


func packed_collision(key: String) -> PackedVector3Array:
	return PackedVector3Array(collision[key])


func packed_nav() -> PackedVector3Array:
	return PackedVector3Array(nav)


func _tri(mat: StringName, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	_tri_n(mat, a, b, c, n, n, n)


func _tri_n(mat: StringName, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	var s := _surface(mat)
	var v: Array = s[0]
	var n: Array = s[1]
	# Godot treats clockwise triangles as front faces.
	if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
		v.append_array([a, c, b])
		n.append_array([na, nc, nb])
	else:
		v.append_array([a, b, c])
		n.append_array([na, nb, nc])


static func _append_face(arr: Array, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		arr.append_array([a, c, b])
	else:
		arr.append_array([a, b, c])


func _intersects(points: Array[Vector3]) -> bool:
	var box := AABB(points[0], Vector3.ZERO)
	for p in points:
		box = box.expand(p)
	return box.intersects(nav_bounds)
