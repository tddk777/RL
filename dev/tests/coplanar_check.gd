extends Node
## Writes the triangles and solids of a generated level for
## dev/tests/coplanar_check.py, which lists faces that share a plane with
## another visible face (they flicker when the camera moves).
##   godot --headless --path . res://dev/tests/coplanar_check.tscn -- <out_file> [seed]
##   python3 dev/tests/coplanar_check.py <out_file>


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://coplanar.txt"
	var profile: LevelProfile = load("res://levels/l1_industrial/l1_profile.tres")
	var layout := LayoutGenerator.generate(profile, int(args[1]) if args.size() > 1 else 7)
	var builder := ChunkBuilder.new(layout)
	builder.record_solids = true
	var tris := FileAccess.open(out, FileAccess.WRITE)
	var solids := FileAccess.open(out + ".solids", FileAccess.WRITE)
	var mats := {}
	var count := builder.chunk_count()
	for cx in count.x:
		for cz in count.y:
			var d := builder.build(Vector2i(cx, cz))
			for mat: StringName in d.geo.packed_surfaces:
				if not mats.has(mat):
					mats[mat] = mats.size()
				var arr: Array = d.geo.packed_surfaces[mat]
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				for i in range(0, v.size(), 3):
					tris.store_line("%d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.3f %.3f %.3f" % [mats[mat],
						v[i].x, v[i].y, v[i].z, v[i + 1].x, v[i + 1].y, v[i + 1].z, v[i + 2].x, v[i + 2].y, v[i + 2].z, n[i].x, n[i].y, n[i].z])
			for sd: Array in d.geo.solids:
				if sd[0] is Vector3:
					var c: Vector3 = sd[0]
					var sz: Vector3 = sd[1]
					var b: Basis = sd[2]
					solids.store_line("B %.4f %.4f %.4f %.4f %.4f %.4f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f" % [c.x, c.y, c.z, sz.x, sz.y, sz.z,
						b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z])
				else:
					var pts: PackedVector2Array = sd[0]
					var line := "P %.4f %.4f" % [sd[1], sd[2]]
					for p in pts:
						line += " %.4f %.4f" % [p.x, p.y]
					solids.store_line(line)
	var mf := FileAccess.open(out + ".mats", FileAccess.WRITE)
	for m in mats:
		mf.store_line("%d %s" % [mats[m], m])
	print("coplanar_check: wrote %s" % out)
	get_tree().quit()
