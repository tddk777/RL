class_name WeaponData
extends ItemData
## Static definition of a firearm. Runtime state lives in Weapon.

enum FireMode { SEMI, BURST, AUTO, BOLT }
enum Feed { MAGAZINE, INTERNAL }

## Scene with a WeaponModel root (markers: Muzzle, Eject, ADS, Grip_R, Grip_L,
## optional Magazine, Bolt and Mount_<slot> nodes). See docs/ADDING_CONTENT.md.
@export var model_scene: PackedScene

@export_group("Ammunition")
@export var caliber: StringName
@export var default_ammo: AmmoData
@export var feed: Feed = Feed.MAGAZINE
@export var magazine_size: int = 30
## Closed-bolt weapons hold one extra round in the chamber.
@export var can_chamber_extra: bool = true
## Spent cases fly out with each shot (not from a revolver).
@export var ejects_casings: bool = true

@export_group("Firing")
@export var fire_modes: Array[FireMode] = [FireMode.SEMI, FireMode.AUTO]
@export var rounds_per_minute: float = 600.0
@export var burst_count: int = 3
@export var muzzle_velocity: float = 715.0  # m/s
@export var damage_multiplier: float = 1.0
## Cone half-angle in degrees.
@export var spread_hip: float = 2.5
@export var spread_ads: float = 0.15
## Extra spread while moving at full speed.
@export var spread_moving: float = 1.5
## Range (m) the weapon is good to: the AI tries to fight from inside it
## (shotguns close in, marksman rifles hang back).
@export var effective_range: float = 30.0

@export_group("Recoil")
## Degrees of camera pitch per shot.
@export var recoil_vertical: float = 1.2
## Max degrees of random yaw per shot.
@export var recoil_horizontal: float = 0.45
## Fraction of camera recoil that recovers after firing stops.
@export var recoil_recovery: float = 0.6
## Viewmodel kick back (m) and up-rotation (deg).
@export var kick_back: float = 0.045
@export var kick_rotation: float = 4.0

@export_group("Handling")
@export var ads_time: float = 0.25
@export var ads_fov: float = 55.0
## Viewmodel offset from the camera when hip firing.
@export var hip_offset: Vector3 = Vector3(0.16, -0.17, -0.32)
## Distance from the eye to the ADS marker when aiming.
@export var ads_eye_distance: float = 0.14
@export var sway: float = 1.0
@export var length: float = 0.75  # m, used to pull the weapon back near walls
@export var reload_time: float = 2.4
@export var reload_empty_time: float = 3.1
## Bolt-action cycle time, or charging-handle time after an empty reload.
@export var cycle_time: float = 1.0
## Internal-feed weapons: time to push in one round.
@export var insert_time: float = 0.55
@export var equip_time: float = 0.5

@export_group("Attachments")
## Slot name -> Array of accepted mount types, e.g. {"optic": ["m40_base"]}.
@export var mount_types: Dictionary = {}
@export var default_attachments: Array[AttachmentData] = []

@export_group("Sound")
@export var shot_sounds: Array[AudioStream] = []
@export var distant_shot_sound: AudioStream
@export var dry_fire_sound: AudioStream
@export var mag_out_sound: AudioStream
@export var mag_in_sound: AudioStream
@export var charge_sound: AudioStream
@export var fire_select_sound: AudioStream
## Radius in meters at which AI hears this weapon fire.
@export var loudness: float = 120.0

@export_group("Effects")
@export var muzzle_flash_scale: float = 1.0
@export var casing_scale: float = 1.0


func time_between_shots() -> float:
	return 60.0 / rounds_per_minute


func accepts(attachment: AttachmentData) -> bool:
	var accepted: Array = mount_types.get(String(attachment.slot), [])
	return accepted.has(String(attachment.mount_type))
