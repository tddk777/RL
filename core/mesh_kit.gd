class_name MeshKit
extends RefCounted
## Procedural modelling helpers for the asset generators in this folder.
##
## Parts are appended into one SurfaceTool per material; commit() returns an
## ArrayMesh with one surface per material. Set `xform` before adding a part
## to place it. Coordinates are meters; weapons point down -Z with +Y up.
##
## Shapes:
##   box()      chamfered box
##   extrude()  side profile (in the Z/Y plane) extruded along X, chamfered
##   lathe()    profile of (radius, z) points revolved around the Z axis
##   cylinder(), tube_between(), sphere(), capsule() built on lathe()

var xform := Transform3D.IDENTITY
var _tools: Dictionary = {}  # Material -> SurfaceTool
var _order: Array[Material] = []


func at(origin: Vector3, rotation_deg := Vector3.ZERO, scale := Vector3.ONE) -> MeshKit:
	var basis := Basis.from_euler(rotation_deg * (PI / 180.0)).scaled(scale)
	xform = Transform3D(basis, origin)
	return self


func reset() -> MeshKit:
	xform = Transform3D.IDENTITY
	return self


func commit() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for mat in _order:
		var st: SurfaceTool = _tools[mat]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh


func is_empty() -> bool:
	return _order.is_empty()


# --- Primitives -------------------------------------------------------------

## Box centered on `center` with every edge chamfered by `bevel`.
func box(size: Vector3, center: Vector3, mat: Material, bevel := 0.0) -> void:
	var h := size * 0.5
	var b := minf(bevel, minf(h.x, minf(h.y, h.z)) * 0.9)
	if b <= 0.0001:
		_plain_box(h, center, mat)
		return
	# For each corner sign s, three points sit on the X, Y and Z faces.
	var p := func(s: Vector3, axis: int) -> Vector3:
		var v := Vector3((h.x - b) * s.x, (h.y - b) * s.y, (h.z - b) * s.z)
		v[axis] = h[axis] * s[axis]
		return v + center
	var signs: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				signs.append(Vector3(sx, sy, sz))
	# Faces
	for axis in 3:
		for side in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = side
			var u := (axis + 1) % 3
			var w := (axis + 2) % 3
			var c := func(su: float, sw: float) -> Vector3:
				var s := Vector3.ZERO
				s[axis] = side
				s[u] = su
				s[w] = sw
				return p.call(s, axis)
			_quad(mat, c.call(-1.0, -1.0), c.call(1.0, -1.0), c.call(1.0, 1.0), c.call(-1.0, 1.0), n)
	# Edge chamfers: between faces of axis a and axis b, running along axis r.
	for a in 3:
		for bb in range(a + 1, 3):
			var r := 3 - a - bb
			for sa in [-1.0, 1.0]:
				for sb in [-1.0, 1.0]:
					var n := Vector3.ZERO
					n[a] = sa
					n[bb] = sb
					n = n.normalized()
					var s0 := Vector3.ZERO
					s0[a] = sa
					s0[bb] = sb
					s0[r] = -1.0
					var s1 := s0
					s1[r] = 1.0
					_quad(mat, p.call(s0, a), p.call(s1, a), p.call(s1, bb), p.call(s0, bb), n)
	# Corner triangles
	for s in signs:
		_tri(mat, p.call(s, 0), p.call(s, 1), p.call(s, 2), s.normalized(), s.normalized(), s.normalized())


## Extrudes a closed side profile. Profile points are Vector2(z, y); the part
## spans x in [-width/2, width/2]. Edges between nearly-parallel segments are
## smoothed (below `smooth_degrees`) so curves read as curves.
func extrude(profile: PackedVector2Array, width: float, mat: Material, bevel := 0.0,
		smooth_degrees := 32.0, x_offset := 0.0) -> void:
	var poly := profile.duplicate()
	if Geometry2D.is_polygon_clockwise(poly):
		poly.reverse()  # make counter-clockwise so outward = right of travel
	var count := poly.size()
	var hw := width * 0.5
	var b := minf(bevel, hw * 0.9)
	var inset := _inset(poly, b) if b > 0.0001 else poly
	if b > 0.0001 and Geometry2D.triangulate_polygon(inset).is_empty():
		inset = poly
		b = 0.0
	var edge_n: Array[Vector2] = []
	for i in count:
		var d := poly[(i + 1) % count] - poly[i]
		edge_n.append(Vector2(d.y, -d.x).normalized())  # outward for CCW
	var cos_smooth := cos(deg_to_rad(smooth_degrees))
	var to3 := func(v: Vector2, x: float) -> Vector3:
		return Vector3(x + x_offset, v.y, v.x)
	var n3 := func(n: Vector2, nx: float) -> Vector3:
		return Vector3(nx, n.y, n.x).normalized()
	# Side walls (and chamfer bands when bevelled)
	for i in count:
		var j := (i + 1) % count
		var en := edge_n[i]
		var ni := en
		var nj := en
		if edge_n[(i - 1 + count) % count].dot(en) > cos_smooth:
			ni = (edge_n[(i - 1 + count) % count] + en).normalized()
		if edge_n[j].dot(en) > cos_smooth:
			nj = (en + edge_n[j]).normalized()
		var xa := hw - b
		_quad_n(mat, to3.call(poly[i], -xa), to3.call(poly[j], -xa), to3.call(poly[j], xa), to3.call(poly[i], xa),
			n3.call(ni, 0.0), n3.call(nj, 0.0), n3.call(nj, 0.0), n3.call(ni, 0.0))
		if b > 0.0001:
			for side in [-1.0, 1.0]:
				var outer_x: float = xa * side
				var inner_x: float = hw * side
				_quad_n(mat, to3.call(poly[i], outer_x), to3.call(poly[j], outer_x), to3.call(inset[j], inner_x), to3.call(inset[i], inner_x),
					n3.call(ni, side), n3.call(nj, side), n3.call(nj, side), n3.call(ni, side))
	# Caps
	var tris := Geometry2D.triangulate_polygon(inset)
	for side in [-1.0, 1.0]:
		var n := Vector3(side, 0.0, 0.0)
		for t in range(0, tris.size(), 3):
			_tri(mat, to3.call(inset[tris[t]], hw * side), to3.call(inset[tris[t + 1]], hw * side),
				to3.call(inset[tris[t + 2]], hw * side), n, n, n)


## Revolves (radius, z) points around the Z axis. Each profile segment gets
## its own normal band (crisp steps); normals are smooth around the axis.
## Caps are added where the first/last radius is above zero.
func lathe(profile: PackedVector2Array, mat: Material, segments := 16, cap_start := true, cap_end := true) -> void:
	var dirs: Array[Vector3] = []
	for s in segments + 1:
		var a := TAU * float(s) / segments
		dirs.append(Vector3(cos(a), sin(a), 0.0))
	# Close the profile through the axis and use its winding to decide which
	# side of each segment faces outward, whatever direction it was drawn in.
	var closed := profile.duplicate()
	closed.append(Vector2(0.0, profile[profile.size() - 1].y))
	closed.append(Vector2(0.0, profile[0].y))
	var area := 0.0
	for k in closed.size():
		var a2 := closed[k]
		var b2 := closed[(k + 1) % closed.size()]
		area += a2.x * b2.y - b2.x * a2.y
	var outward := 1.0 if area >= 0.0 else -1.0
	for k in profile.size() - 1:
		var p0 := profile[k]
		var p1 := profile[k + 1]
		var dr := p1.x - p0.x
		var dz := p1.y - p0.y
		var seg_len := sqrt(dr * dr + dz * dz)
		if seg_len < 0.00001:
			continue
		var nr := outward * dz / seg_len
		var nz := outward * -dr / seg_len
		for s in segments:
			var d0 := dirs[s]
			var d1 := dirs[s + 1]
			var a := d0 * p0.x + Vector3(0, 0, p0.y)
			var b := d1 * p0.x + Vector3(0, 0, p0.y)
			var c := d1 * p1.x + Vector3(0, 0, p1.y)
			var d := d0 * p1.x + Vector3(0, 0, p1.y)
			var n0 := (d0 * nr + Vector3(0, 0, nz)).normalized()
			var n1 := (d1 * nr + Vector3(0, 0, nz)).normalized()
			_quad_n(mat, a, b, c, d, n0, n1, n1, n0)
	if cap_start and profile[0].x > 0.0001:
		_disc(mat, profile[0].x, profile[0].y, dirs, segments, Vector3(0, 0, signf(profile[0].y - profile[1].y) if profile[0].y != profile[1].y else -1.0))
	var last := profile.size() - 1
	if cap_end and profile[last].x > 0.0001:
		_disc(mat, profile[last].x, profile[last].y, dirs, segments, Vector3(0, 0, signf(profile[last].y - profile[last - 1].y) if profile[last].y != profile[last - 1].y else 1.0))


## Cylinder along the local Z axis from z0 to z1.
func cylinder(radius: float, z0: float, z1: float, mat: Material, segments := 16, bevel := 0.0) -> void:
	if bevel > 0.0:
		var b := minf(bevel, minf(radius * 0.5, absf(z1 - z0) * 0.3))
		var dirz := signf(z1 - z0)
		lathe(PackedVector2Array([Vector2(radius - b, z0), Vector2(radius, z0 + b * dirz), Vector2(radius, z1 - b * dirz), Vector2(radius - b, z1)]),
			mat, segments)
	else:
		lathe(PackedVector2Array([Vector2(radius, z0), Vector2(radius, z1)]), mat, segments)


## Cylinder from world-ish point a to point b (in the current xform space).
func tube_between(a: Vector3, b: Vector3, radius: float, mat: Material, segments := 10) -> void:
	var saved := xform
	var dir := b - a
	var length := dir.length()
	if length < 0.0001:
		return
	var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	var basis := Basis.looking_at(dir, up)  # -Z toward b
	xform = saved * Transform3D(basis, a)
	cylinder(radius, 0.0, -length, mat, segments)
	xform = saved


func sphere(radius: float, center: Vector3, mat: Material, rings := 10, segments := 16, scale := Vector3.ONE) -> void:
	var saved := xform
	xform = saved * Transform3D(Basis.from_scale(scale), center)
	var pts := PackedVector2Array()
	for r in rings + 1:
		var a := PI * float(r) / rings
		pts.append(Vector2(sin(a) * radius, -cos(a) * radius))
	_lathe_smooth(pts, mat, segments)
	xform = saved


## Capsule along local Z from z0 to z1 (total length includes the caps).
func capsule(radius: float, z0: float, z1: float, mat: Material, segments := 14, scale := Vector3.ONE) -> void:
	var saved := xform
	xform = saved * Transform3D(Basis.from_scale(scale), Vector3.ZERO)
	var lo := minf(z0, z1)
	var hi := maxf(z0, z1)
	var pts := PackedVector2Array()
	var cap_rings := 5
	for r in cap_rings + 1:
		var a := (PI * 0.5) * float(r) / cap_rings
		pts.append(Vector2(sin(a) * radius, lo + radius - cos(a) * radius))
	for r in cap_rings + 1:
		var a := (PI * 0.5) + (PI * 0.5) * float(r) / cap_rings
		pts.append(Vector2(sin(a) * radius, hi - radius - cos(a) * radius))
	_lathe_smooth(pts, mat, segments)
	xform = saved


# --- Internals --------------------------------------------------------------

func _lathe_smooth(pts: PackedVector2Array, mat: Material, segments: int) -> void:
	## Lathe with normals averaged along the profile (spheres, capsules).
	var n_prof: Array[Vector2] = []
	var count := pts.size()
	for k in count:
		var prev := pts[maxi(k - 1, 0)]
		var next := pts[mini(k + 1, count - 1)]
		var d := next - prev
		n_prof.append(Vector2(d.y, -d.x).normalized())
	for k in count - 1:
		for s in segments:
			var a0 := TAU * float(s) / segments
			var a1 := TAU * float(s + 1) / segments
			var d0 := Vector3(cos(a0), sin(a0), 0.0)
			var d1 := Vector3(cos(a1), sin(a1), 0.0)
			var p := func(k2: int, d: Vector3) -> Vector3: return d * pts[k2].x + Vector3(0, 0, pts[k2].y)
			var nn := func(k2: int, d: Vector3) -> Vector3: return (d * n_prof[k2].x + Vector3(0, 0, n_prof[k2].y)).normalized()
			_quad_n(mat, p.call(k, d0), p.call(k, d1), p.call(k + 1, d1), p.call(k + 1, d0),
				nn.call(k, d0), nn.call(k, d1), nn.call(k + 1, d1), nn.call(k + 1, d0))


func _disc(mat: Material, radius: float, z: float, dirs: Array[Vector3], segments: int, n: Vector3) -> void:
	var c := Vector3(0, 0, z)
	for s in segments:
		_tri(mat, c, dirs[s] * radius + c, dirs[s + 1] * radius + c, n, n, n)


func _plain_box(h: Vector3, center: Vector3, mat: Material) -> void:
	for axis in 3:
		for side in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = side
			var u := (axis + 1) % 3
			var w := (axis + 2) % 3
			var c := func(su: float, sw: float) -> Vector3:
				var v := Vector3.ZERO
				v[axis] = h[axis] * side
				v[u] = h[u] * su
				v[w] = h[w] * sw
				return v + center
			_quad(mat, c.call(-1.0, -1.0), c.call(1.0, -1.0), c.call(1.0, 1.0), c.call(-1.0, 1.0), n)


func _inset(poly: PackedVector2Array, amount: float) -> PackedVector2Array:
	## Moves each vertex inward along its corner bisector (polygon is CCW).
	var out := PackedVector2Array()
	var count := poly.size()
	for i in count:
		var prev := poly[(i - 1 + count) % count]
		var cur := poly[i]
		var next := poly[(i + 1) % count]
		var d0 := (cur - prev).normalized()
		var d1 := (next - cur).normalized()
		var n0 := Vector2(d0.y, -d0.x)
		var n1 := Vector2(d1.y, -d1.x)
		var bis := (n0 + n1)
		if bis.length() < 0.0001:
			bis = n0
		bis = bis.normalized()
		var denom := maxf(bis.dot(n0), 0.35)
		out.append(cur - bis * (amount / denom))
	return out


func _st(mat: Material) -> SurfaceTool:
	if not _tools.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[mat] = st
		_order.append(mat)
	return _tools[mat]


func _quad(mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	_tri(mat, a, b, c, n, n, n)
	_tri(mat, a, c, d, n, n, n)


func _quad_n(mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	_tri(mat, a, b, c, na, nb, nc)
	_tri(mat, a, c, d, na, nc, nd)


func _tri(mat: Material, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	var g := (b - a).cross(c - a)
	if g.length_squared() < 1e-14:
		return
	# Godot treats clockwise triangles as front-facing: flip when the
	# geometric normal agrees with the intended one.
	if g.dot(na + nb + nc) > 0.0:
		var t := b
		b = c
		c = t
		var tn := nb
		nb = nc
		nc = tn
	var st := _st(mat)
	var nbasis := xform.basis.inverse().transposed()
	for pair in [[a, na], [b, nb], [c, nc]]:
		var p: Vector3 = xform * (pair[0] as Vector3)
		var n: Vector3 = (nbasis * (pair[1] as Vector3)).normalized()
		st.set_normal(n)
		st.set_uv(_box_uv(p, n))
		st.add_vertex(p)


static func _box_uv(p: Vector3, n: Vector3) -> Vector2:
	var an := n.abs()
	if an.x >= an.y and an.x >= an.z:
		return Vector2(p.z, -p.y)
	if an.y >= an.z:
		return Vector2(p.x, p.z)
	return Vector2(p.x, -p.y)
