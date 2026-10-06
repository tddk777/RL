class_name WeaponModel
extends Node3D
## Root script for a weapon's visual scene. Gameplay code only talks to the
## model through the named marker nodes below, so any model works (procedural
## or an imported .glb placed inside a scene) as long as it has them:
##
##   Muzzle      end of the barrel, -Z pointing downrange (flash, smoke)
##   Eject       ejection port, +X pointing the way casings fly
##   ADS         a point on the sight line; aiming puts it on the eye ray
##   Grip_R      where the right hand holds (pistol grip)
##   Grip_L      where the left hand holds (handguard)
##   Magazine    (optional) node moved out/in during reloads
##   Bolt        (optional) node that cycles on each shot
##   Mount_<slot> (optional) where an attachment for <slot> is parented
##
## Origin convention: bore axis at y = 0, rear of the receiver at z = 0,
## barrel along -Z, right side +X.

## How far the Bolt node travels (local space) when cycling.
@export var bolt_travel := Vector3(0, 0, 0.06)
## Bolt-action lift: degrees the Bolt rotates around Z before travelling.
@export var bolt_lift_degrees := 0.0
## Where the magazine goes when removed (offset from its rest position).
@export var magazine_drop := Vector3(0, -0.22, 0.02)

var muzzle: Node3D
var eject: Node3D
var grip_r: Node3D
var grip_l: Node3D
var magazine: Node3D
var bolt: Node3D

var _ads: Node3D
var _ads_override: Node3D
var _bolt_rest: Transform3D
var _mag_rest: Transform3D
var _bolt_tween: Tween
var _mag_tween: Tween


func _ready() -> void:
	muzzle = get_node_or_null(^"Muzzle")
	eject = get_node_or_null(^"Eject")
	grip_r = get_node_or_null(^"Grip_R")
	grip_l = get_node_or_null(^"Grip_L")
	magazine = get_node_or_null(^"Magazine")
	bolt = get_node_or_null(^"Bolt")
	_ads = get_node_or_null(^"ADS")
	if bolt:
		_bolt_rest = bolt.transform
	if magazine:
		_mag_rest = magazine.transform


func mount(slot: StringName) -> Node3D:
	return get_node_or_null(NodePath("Mount_%s" % slot))


## The sight point used for aiming. An optic attachment can supply its own.
func ads_point() -> Node3D:
	return _ads_override if is_instance_valid(_ads_override) else _ads


func set_ads_override(point: Node3D) -> void:
	_ads_override = point


## ADS marker position in this model's local space.
func ads_local_position() -> Vector3:
	var point := ads_point()
	if point == null:
		return Vector3(0, 0.05, -0.1)
	return global_transform.affine_inverse() * point.global_position if is_inside_tree() else point.position


## Quick bolt cycle for semi/auto fire.
func cycle_bolt(duration: float = 0.06) -> void:
	if bolt == null:
		return
	if _bolt_tween:
		_bolt_tween.kill()
	bolt.transform = _bolt_rest
	_bolt_tween = create_tween()
	_bolt_tween.tween_property(bolt, "position", _bolt_rest.origin + bolt_travel, duration * 0.4)
	_bolt_tween.tween_property(bolt, "position", _bolt_rest.origin, duration * 0.6)


## Slow manual cycle (bolt action or charging handle), total `duration` s.
func manual_cycle(duration: float) -> void:
	if bolt == null:
		return
	if _bolt_tween:
		_bolt_tween.kill()
	bolt.transform = _bolt_rest
	var lifted := _bolt_rest.basis.rotated(Vector3.FORWARD, deg_to_rad(bolt_lift_degrees))
	_bolt_tween = create_tween().set_trans(Tween.TRANS_SINE)
	if bolt_lift_degrees != 0.0:
		_bolt_tween.tween_property(bolt, "basis", lifted, duration * 0.15)
	_bolt_tween.tween_property(bolt, "position", _bolt_rest.origin + bolt_travel, duration * 0.25)
	_bolt_tween.tween_interval(duration * 0.1)
	_bolt_tween.tween_property(bolt, "position", _bolt_rest.origin, duration * 0.25)
	if bolt_lift_degrees != 0.0:
		_bolt_tween.tween_property(bolt, "basis", _bolt_rest.basis, duration * 0.15)


func magazine_out(duration: float = 0.35) -> void:
	if magazine == null:
		return
	if _mag_tween:
		_mag_tween.kill()
	_mag_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_mag_tween.tween_property(magazine, "position", _mag_rest.origin + magazine_drop, duration)
	_mag_tween.tween_callback(magazine.hide)


func magazine_in(duration: float = 0.35) -> void:
	if magazine == null:
		return
	if _mag_tween:
		_mag_tween.kill()
	magazine.show()
	magazine.position = _mag_rest.origin + magazine_drop
	_mag_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_mag_tween.tween_property(magazine, "position", _mag_rest.origin, duration)


func reset_pose() -> void:
	if _bolt_tween:
		_bolt_tween.kill()
	if _mag_tween:
		_mag_tween.kill()
	if bolt:
		bolt.transform = _bolt_rest
	if magazine:
		magazine.transform = _mag_rest
		magazine.show()
