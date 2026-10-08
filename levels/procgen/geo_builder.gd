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
## Tall solids as [footprint PackedVector3Array, elevation, height]: the
## navigation baker sees only surfaces, so a big box would otherwise have
## walkable floor inside it.
var obstructions: Array = []
var visuals: bool = true
## Only geometry intersecting this box goes into `nav` (empty = everything).
var nav_bounds := AABB()
## Debugging (dev/tests/coplanar_check): when set, every visible box and prism
## is also listed here as [center, size, basis] or [polygon, y0, y1].
var record_solids: bool = false
var solids: Array = []

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
	if record_solids and visuals and mat != &"":
		solids.append([center, size, basis])
	var corners: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var nb := basis.inverse().transposed()
	for face in _FACES:
		normals.append((nb * (face[0] as Vector3)).normalized())
		for c: Vector3 in face[1]:
			corners.append(center + basis * (c * half))
	var in_nav := surface != &"" and (nav_bounds.size == Vector3.ZERO or _intersects(corners))
	if in_nav and layer != 0 and minf(size.x, minf(size.y, size.z)) >= 0.5:
		_obstruction(corners)
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


func _obstruction(corners: Array[Vector3]) -> void:
	var lo := INF
	var hi := -INF
	var pts := PackedVector2Array()
	for c in corners:
		lo = minf(lo, c.y)
		hi = maxf(hi, c.y)
		pts.append(Vector2(c.x, c.z))
	if hi - lo < 1.6:
		return
	var hull := Geometry2D.convex_hull(pts)
	if hull.size() < 4:
		return
	# Thin walls are no problem (no room for an agent inside).
	var area := 0.0
	var perimeter := 0.0
	for i in hull.size() - 1:
		area += hull[i].x * hull[i + 1].y - hull[i + 1].x * hull[i].y
		perimeter += hull[i].distance_to(hull[i + 1])
	area = absf(area) * 0.5
	if area / maxf(perimeter, 0.001) < 0.2:
		return
	var verts := PackedVector3Array()
	for i in hull.size() - 1:
		verts.append(Vector3(hull[i].x, lo, hull[i].y))
	# Stop short of the top: the floor of the storey above starts there.
	obstructions.append([verts, lo, hi - lo - 0.25])


## Vertical prism over a convex polygon (world x, z; either winding) from y0
## to y1: chamfered slabs and floors. Collision and navigation like box().
func prism(points: PackedVector2Array, y0: float, y1: float, mat: StringName, surface: StringName = &"",
		occlude: bool = false) -> void:
	var n := points.size()
	if n < 3 or y1 - y0 < 0.001:
		return
	if record_solids and visuals and mat != &"":
		solids.append([points, y0, y1])
	var c := Vector2.ZERO
	for p in points:
		c += p
	c /= n
	var area := 0.0
	for i in n:
		area += points[i].cross(points[(i + 1) % n])
	var pts := points
	if area < 0.0:  # make it counter-clockwise in (x, z)
		pts = points.duplicate()
		pts.reverse()
	var faces: Array = []  # [a, b, c, normal]
	for i in range(1, n - 1):
		var a := pts[0]
		var b := pts[i]
		var d := pts[i + 1]
		faces.append([Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(d.x, y1, d.y), Vector3.UP])
		faces.append([Vector3(a.x, y0, a.y), Vector3(d.x, y0, d.y), Vector3(b.x, y0, b.y), Vector3.DOWN])
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var e := b - a
		var out := Vector3(e.y, 0, -e.x).normalized()
		if Vector2(out.x, out.z).dot(a - c) < 0.0:
			out = -out
		var a0 := Vector3(a.x, y0, a.y)
		var b0 := Vector3(b.x, y0, b.y)
		var a1 := Vector3(a.x, y1, a.y)
		var b1 := Vector3(b.x, y1, b.y)
		faces.append([a0, b0, b1, out])
		faces.append([a0, b1, a1, out])
	var corners: Array[Vector3] = []
	for p in pts:
		corners.append(Vector3(p.x, y0, p.y))
		corners.append(Vector3(p.x, y1, p.y))
	var in_nav := surface != &"" and (nav_bounds.size == Vector3.ZERO or _intersects(corners))
	var col_key := "%s|1" % surface
	if surface != &"" and not collision.has(col_key):
		collision[col_key] = []
	for f in faces:
		if visuals and mat != &"":
			_tri(mat, f[0], f[1], f[2], f[3])
		if surface != &"":
			_append_face(collision[col_key], f[0], f[1], f[2], f[3])
			if in_nav:
				_append_face(nav, f[0], f[1], f[2], f[3])
	if occlude and visuals:
		var base := occluder_vertices.size()
		for p in pts:
			occluder_vertices.append(Vector3(p.x, y0, p.y))
			occluder_vertices.append(Vector3(p.x, y1, p.y))
		for i in range(1, n - 1):
			occluder_indices.append_array([base, base + 2 * i, base + 2 * (i + 1)])
			occluder_indices.append_array([base + 1, base + 2 * (i + 1) + 1, base + 2 * i + 1])
		for i in n:
			var j := (i + 1) % n
			occluder_indices.append_array([base + 2 * i, base + 2 * j, base + 2 * j + 1])
			occluder_indices.append_array([base + 2 * i, base + 2 * j + 1, base + 2 * i + 1])


## A profile (2D points (along, up), either winding, may be concave)
## extruded sideways: visual only. The profile's x runs along `along`, y up;
## the solid spans `side * w0` .. `side * w1` from `origin`.
func extrude(profile: PackedVector2Array, origin: Vector3, along: Vector3, side: Vector3, w0: float, w1: float,
		mat: StringName) -> void:
	if not visuals or profile.size() < 3:
		return
	var pts := profile
	var area := 0.0
	for i in pts.size():
		area += pts[i].cross(pts[(i + 1) % pts.size()])
	if area < 0.0:
		pts = profile.duplicate()
		pts.reverse()
	var at := func(p: Vector2, w: float) -> Vector3:
		return origin + along * p.x + Vector3.UP * p.y + side * w
	var tris := Geometry2D.triangulate_polygon(pts)
	var n_side := side.normalized()
	for i in range(0, tris.size(), 3):
		var a := pts[tris[i]]
		var b := pts[tris[i + 1]]
		var c := pts[tris[i + 2]]
		_tri(mat, at.call(a, w0), at.call(b, w0), at.call(c, w0), -n_side)
		_tri(mat, at.call(a, w1), at.call(b, w1), at.call(c, w1), n_side)
	# Counter-clockwise profile: the outward normal of edge a->b is (dy, -dx).
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var e := b - a
		if e.length() < 0.0001:
			continue
		var n2 := Vector2(e.y, -e.x).normalized()
		var n := (along * n2.x + Vector3.UP * n2.y).normalized()
		var a0: Vector3 = at.call(a, w0)
		var b0: Vector3 = at.call(b, w0)
		var a1: Vector3 = at.call(a, w1)
		var b1: Vector3 = at.call(b, w1)
		_tri(mat, a0, b0, b1, n)
		_tri(mat, a0, b1, a1, n)


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
func cylinder(a: Vector3, b: Vector3, radius: float, mat: StringName, segments: int = 8, caps: bool = false) -> void:
	frustum(a, b, radius, radius, mat, segments, caps)


## Truncated cone from a (radius ra) to b (radius rb), visual only. Caps close
## the ends (tanks, furnaces, drums).
func frustum(a: Vector3, b: Vector3, ra: float, rb: float, mat: StringName, segments: int = 8, caps: bool = false) -> void:
	if not visuals:
		return
	var axis := b - a
	var length := axis.length()
	if length < 0.001:
		return
	var dir := axis / length
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := side.cross(dir)
	var slope := (ra - rb) / length
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var r0 := side * cos(a0) + up * sin(a0)
		var r1 := side * cos(a1) + up * sin(a1)
		var n0 := (r0 + dir * slope).normalized()
		var n1 := (r1 + dir * slope).normalized()
		var p0 := a + r0 * ra
		var p1 := a + r1 * ra
		var q0 := b + r0 * rb
		var q1 := b + r1 * rb
		_tri_n(mat, p0, p1, q1, n0, n1, n1)
		_tri_n(mat, p0, q1, q0, n0, n1, n0)
		if caps:
			if ra > 0.001:
				_tri(mat, a, p1, p0, -dir)
			if rb > 0.001:
				_tri(mat, b, q0, q1, dir)


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
