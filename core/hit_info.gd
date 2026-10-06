class_name HitInfo
extends RefCounted
## Everything known about one bullet (or other damage) hitting something.

var damage: float = 0.0
var position: Vector3
var normal: Vector3
var direction: Vector3
## The actor that caused the damage (Player, NPC), if any.
var source: Node
## Body zone that was hit, set by the Hitbox ("head", "torso", "arm", "leg").
var zone: StringName = &"body"
var ammo: AmmoData
