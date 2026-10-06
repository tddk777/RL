extends Node
## Finds every content definition under res://content/<category>/ and indexes
## it by id. Adding a weapon, enemy, level, etc. is adding a .tres file there;
## no code needs to know about it.

const ROOT := "res://content"

var _defs: Dictionary = {}  # category (StringName) -> { id (StringName) -> Resource }


func _ready() -> void:
	for entry in ResourceLoader.list_directory(ROOT):
		if entry.ends_with("/"):
			_load_category(StringName(entry.trim_suffix("/")))


func get_def(category: StringName, id: StringName) -> Resource:
	var defs: Dictionary = _defs.get(category, {})
	if not defs.has(id):
		push_error("Registry: no %s with id '%s'" % [category, id])
		return null
	return defs[id]


func all(category: StringName) -> Array:
	return _defs.get(category, {}).values()


func weapon(id: StringName) -> WeaponData:
	return get_def(&"weapons", id) as WeaponData


func enemy(id: StringName) -> EnemyData:
	return get_def(&"enemies", id) as EnemyData


func surface(id: StringName) -> SurfaceData:
	var defs: Dictionary = _defs.get(&"surfaces", {})
	return defs.get(id, defs.get(Surface.DEFAULT))


## Levels sorted by their `order` field.
func levels() -> Array[LevelData]:
	var result: Array[LevelData] = []
	for level in all(&"levels"):
		result.append(level)
	result.sort_custom(func(a: LevelData, b: LevelData) -> bool: return a.order < b.order)
	return result


func next_level(current: LevelData) -> LevelData:
	var ordered := levels()
	var index := ordered.find(current)
	return ordered[index + 1] if index >= 0 and index + 1 < ordered.size() else null


func _load_category(category: StringName) -> void:
	var defs := {}
	var dir := ROOT.path_join(category)
	for file in ResourceLoader.list_directory(dir):
		if not (file.ends_with(".tres") or file.ends_with(".res")):
			continue
		var res := load(dir.path_join(file))
		var id: Variant = res.get(&"id") if res else null
		if id == null or StringName(id) == &"":
			push_warning("Registry: %s has no id, skipped" % dir.path_join(file))
			continue
		if defs.has(id):
			push_error("Registry: duplicate %s id '%s'" % [category, id])
		defs[StringName(id)] = res
	_defs[category] = defs
