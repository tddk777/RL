class_name CollisionBoxes
extends RefCounted
## Bullet-accurate collision for open props (shelving, chairs, carts,
## ladders): the mesh is voxelised once and the filled voxels merged into a
## few dozen boxes, so shots pass through the gaps between shelves and legs
## and stop on the frame itself. (A box round the whole prop stops bullets in
## mid-air; the scanned meshes are far too dense to use as collision.)

const MAX_BOXES := 90


## Triangles (flat, three points each, in the prop's space) -> Array of
## [center Vector3, size Vector3]. Coarser voxels until it fits MAX_BOXES.
static func from_triangles(tris: PackedVector3Array, voxel: float = 0.06) -> Array:
	if tris.size() < 3:
		return []
	var box := AABB(tris[0], Vector3.ZERO)
	for p in tris:
		box = box.expand(p)
	var v := voxel
	for attempt in 4:
		var out := _boxes(tris, box, v)
		if out.size() <= MAX_BOXES or attempt == 3:
			return out
		v *= 1.5
	return []


static func _boxes(tris: PackedVector3Array, box: AABB, v: float) -> Array:
	var origin := box.position
	var dim := Vector3i((box.size / v).ceil()) + Vector3i.ONE
	var nx := dim.x
	var nxz := dim.x * dim.z
	var occ := PackedByteArray()
	occ.resize(dim.x * dim.y * dim.z)
	# Sample each triangle at under half a voxel spacing so no voxel it
	# crosses is missed.
	for t in range(0, tris.size() - 2, 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var longest := maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))
		var n := maxi(1, ceili(longest / (v * 0.5)))
		for i in n + 1:
			for j in n + 1 - i:
				var p := a + (b - a) * (float(i) / n) + (c - a) * (float(j) / n)
				var q := Vector3i(((p - origin) / v).floor()).clamp(Vector3i.ZERO, dim - Vector3i.ONE)
				occ[q.x + q.z * nx + q.y * nxz] = 1
	# Greedy merge: run along x, widen along z, then stack up y.
	var out: Array = []
	for y in dim.y:
		for z in dim.z:
			for x in dim.x:
				if occ[x + z * nx + y * nxz] != 1:
					continue
				var w := 1
				while x + w < dim.x and occ[x + w + z * nx + y * nxz] == 1:
					w += 1
				var d := 1
				while z + d < dim.z and _row(occ, x, w, z + d, y, nx, nxz):
					d += 1
				var h := 1
				while y + h < dim.y and _slab(occ, x, w, z, d, y + h, nx, nxz):
					h += 1
				for yy in h:
					for zz in d:
						for xx in w:
							occ[x + xx + (z + zz) * nx + (y + yy) * nxz] = 2
				var size := Vector3(w, h, d) * v
				out.append([origin + Vector3(x, y, z) * v + size * 0.5, size])
	return out


static func _row(occ: PackedByteArray, x: int, w: int, z: int, y: int, nx: int, nxz: int) -> bool:
	for xx in w:
		if occ[x + xx + z * nx + y * nxz] != 1:
			return false
	return true


static func _slab(occ: PackedByteArray, x: int, w: int, z: int, d: int, y: int, nx: int, nxz: int) -> bool:
	for zz in d:
		if not _row(occ, x, w, z + zz, y, nx, nxz):
			return false
	return true


## Flat triangle list from mesh surface arrays (indexed or not), through `xf`.
static func triangles(arrays: Array, xf: Transform3D = Transform3D.IDENTITY) -> PackedVector3Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var out := PackedVector3Array()
	if arrays[Mesh.ARRAY_INDEX] != null and (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
		for i: int in arrays[Mesh.ARRAY_INDEX]:
			out.append(xf * verts[i])
	else:
		for p in verts:
			out.append(xf * p)
	return out


## Shelf tops among `boxes`: thin horizontal boxes that cover a good part of
## the prop's footprint, merged by height. -> [[top y, Rect2 in x/z], ...],
## lowest first.
static func shelves(boxes: Array, bounds: AABB, tris: PackedVector3Array = PackedVector3Array(), min_share: float = 0.3) -> Array:
	var foot := bounds.size.x * bounds.size.z
	var levels: Array = []
	for b: Array in boxes:
		var c: Vector3 = b[0]
		var sz: Vector3 = b[1]
		if sz.y > 0.13 or sz.x * sz.z < foot * min_share * 0.5:
			continue
		var top := c.y + sz.y * 0.5
		if top < 0.05:
			continue  # the floor plate of a cart, not a shelf
		var rect := Rect2(c.x - sz.x * 0.5, c.z - sz.z * 0.5, sz.x, sz.z)
		var merged := false
		for lv: Array in levels:
			if absf(float(lv[0]) - top) < 0.07:
				lv[0] = maxf(lv[0], top)
				lv[1] = (lv[1] as Rect2).merge(rect)
				merged = true
				break
		if not merged:
			levels.append([top, rect])
	levels = levels.filter(func(lv: Array) -> bool: return (lv[1] as Rect2).get_area() >= foot * min_share)
	levels.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	# Voxel tops sit up to a voxel above the real surface: take the highest
	# mesh point inside each shelf's footprint just under it instead.
	if not tris.is_empty():
		for lv: Array in levels:
			var top: float = lv[0]
			var rect: Rect2 = (lv[1] as Rect2).grow(-0.02)
			var best := -INF
			for p in tris:
				if p.y <= top + 0.001 and p.y > top - 0.1 and rect.has_point(Vector2(p.x, p.z)):
					best = maxf(best, p.y)
			if best > -INF:
				lv[0] = best
	return levels
