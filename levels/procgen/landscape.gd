class_name Landscape
## Rolling ground round a site as one mesh with trimesh collision. The grid is
## fine (FINE m) over the site and the slopes next to it and opens up toward
## the horizon, so a 1.6 km square stays around 20k vertices.

const FINE := 4.0
const COARSE := 40.0
const GROWTH := 1.12
const EXTENT := 800.0  # m from the centre to each edge


## `height` maps (x, z) -> y. `site` is the flat area (world XZ); the fine
## grid reaches `margin` past it.
static func build(height: Callable, site: Rect2, centre: Vector3, material: Material, margin: float = 80.0) -> StaticBody3D:
	var xs := _lines(site.position.x - margin, site.end.x + margin, centre.x)
	var zs := _lines(site.position.y - margin, site.end.y + margin, centre.z)
	var nx := xs.size()
	var nz := zs.size()
	var verts := PackedVector3Array()
	verts.resize(nx * nz)
	for j in nz:
		for i in nx:
			verts[j * nx + i] = Vector3(xs[i], height.call(xs[i], zs[j]), zs[j])
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for j in nz:
		for i in nx:
			var l := verts[j * nx + maxi(i - 1, 0)]
			var r := verts[j * nx + mini(i + 1, nx - 1)]
			var d := verts[maxi(j - 1, 0) * nx + i]
			var u := verts[mini(j + 1, nz - 1) * nx + i]
			normals[j * nx + i] = (u - d).cross(r - l).normalized()
	var idx := PackedInt32Array()
	for j in nz - 1:
		for i in nx - 1:
			var a := j * nx + i
			idx.append_array([a, a + 1, a + nx, a + 1, a + nx + 1, a + nx])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var body := StaticBody3D.new()
	body.name = "Landscape"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	body.set_meta(&"surface", &"concrete")
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	return body


## Grid lines: FINE steps over [lo, hi], then growing steps out to EXTENT.
static func _lines(lo: float, hi: float, centre: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := ceili((hi - lo) / FINE)
	var step := (hi - lo) / n
	var left := PackedFloat32Array()
	var s := FINE
	var x := lo
	while x > centre - EXTENT:
		s = minf(s * GROWTH, COARSE)
		x -= s
		left.append(maxf(x, centre - EXTENT))
	left.reverse()
	out.append_array(left)
	for i in n + 1:
		out.append(lo + i * step)
	s = FINE
	x = hi
	while x < centre + EXTENT:
		s = minf(s * GROWTH, COARSE)
		x += s
		out.append(minf(x, centre + EXTENT))
	return out
