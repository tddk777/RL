class_name AttachmentData
extends ItemData
## A weapon attachment. It mounts on a weapon model's "Mount_<slot>" marker
## when the weapon's mount_types for that slot include this mount_type.
## Stat fields are multipliers so attachments stack predictably.

@export var slot: StringName = &"optic"  # optic, muzzle, underbarrel, stock, ...
@export var mount_type: StringName = &"picatinny"
@export var model_scene: PackedScene

@export_group("Modifiers")
@export var recoil_multiplier: float = 1.0
@export var spread_multiplier: float = 1.0
@export var ads_time_multiplier: float = 1.0
@export var loudness_multiplier: float = 1.0
@export var flash_multiplier: float = 1.0
## Field of view while aiming. 0 keeps the weapon's own ADS FOV.
@export var ads_fov: float = 0.0
## Fullscreen overlay while fully aimed (e.g. a scope eyepiece). The weapon
## model is hidden while it shows.
@export var ads_overlay: Texture2D

@export_group("Sound overrides")
## Replaces the weapon's shot sounds (e.g. a suppressor).
@export var shot_sounds: Array[AudioStream] = []
