class_name Pickup
extends Interactable
## Something lying around that the player can take: a weapon or ammunition.
## (Placeholder for a fuller loot/inventory system.)

const SOUND := "res://assets/audio/weapons/m16/mag_in.wav"

var record: Dictionary = {}
var weapon: WeaponData
var caliber: StringName
var amount: int = 0


static func create(rec: Dictionary) -> Pickup:
	var p := Pickup.new()
	p.record = rec
	if rec["kind"] == &"weapon":
		p.weapon = Registry.weapon(rec["id"])
		if p.weapon == null:
			return null
	else:
		p.caliber = rec["id"]
		p.amount = rec.get("amount", 10)
	return p


func _ready() -> void:
	super()
	if weapon:
		prompt = "Take %s" % weapon.display_name
		var model := weapon.model_scene.instantiate() as Node3D
		model.rotation_degrees = Vector3(0, 0, 90)  # lying on its side
		model.position = Vector3(0, 0.03, 0)
		add_child(model)
		_shape(Vector3(0.35, 0.25, maxf(weapon.length, 0.4)), Vector3(0, 0.1, -weapon.length * 0.3))
	else:
		prompt = "Take %s rounds (%d)" % [caliber, amount]
		_build_box()
		_shape(Vector3(0.45, 0.3, 0.4), Vector3(0, 0.12, 0))
	# Placed from the navmesh, which floats above the floor: drop onto it
	# (once whoever placed it has set the transform).
	if not record.get("on_surface", false):
		Ground.settle.call_deferred(self)


func interact(by: Node) -> void:
	var player := by as Player
	if player == null:
		return
	if weapon:
		var existing: Weapon = null
		for w in player.weapons:
			if w.data == weapon:
				existing = w
		if existing:
			player.ammo_reserve[String(weapon.caliber)] = player.count_ammo(weapon.caliber) + weapon.magazine_size
		else:
			var w := player.add_weapon(weapon)
			w.mag_ammo = record.get("loaded", weapon.magazine_size / 2)
	else:
		player.ammo_reserve[String(caliber)] = player.count_ammo(caliber) + amount
	record["taken"] = true
	if ResourceLoader.exists(SOUND):
		Audio.play_3d(load(SOUND), global_position, &"World", -6.0, 3.0, 0.1)
	super(by)
	queue_free()


func _shape(size: Vector3, offset: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = offset
	add_child(cs)


## Olive steel ammo can with a coloured caliber stripe.
func _build_box() -> void:
	var k := MeshKit.new()
	var steel := load("res://assets/materials/prop_steel.tres") as Material
	var dark := load("res://assets/materials/gun_metal.tres") as Material
	var small := caliber == &".45ACP" or caliber == &"9x19"
	var size := Vector3(0.22, 0.12, 0.14) if small else Vector3(0.3, 0.18, 0.15)
	k.box(size, Vector3(0, size.y * 0.5, 0), steel, 0.01)
	k.box(Vector3(size.x + 0.01, 0.025, size.z + 0.01), Vector3(0, size.y - 0.01, 0), steel, 0.005)
	k.box(Vector3(0.09, 0.012, 0.025), Vector3(0, size.y + 0.012, 0), dark, 0.004)
	var stripe := StandardMaterial3D.new()
	stripe.albedo_color = {&".45ACP": Color(0.75, 0.6, 0.2), &"9x19": Color(0.65, 0.65, 0.6), &"7.62x39": Color(0.6, 0.25, 0.15),
		&"5.56x45": Color(0.25, 0.45, 0.25), &"7.62x51": Color(0.2, 0.25, 0.5)}.get(caliber, Color.GRAY)
	k.box(Vector3(size.x + 0.002, 0.03, size.z + 0.002), Vector3(0, size.y * 0.45, 0), stripe)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	add_child(mi)
