class_name SurfaceData
extends Resource
## How a material reacts to bullets and feet. Colliders are tagged with the id
## (metadata "surface"); see Surface.of().

@export var id: StringName

@export_group("Impacts")
@export var impact_sounds: Array[AudioStream] = []
@export var ricochet_sounds: Array[AudioStream] = []
@export_range(0.0, 1.0) var ricochet_chance: float = 0.0
@export var decal_textures: Array[Texture2D] = []
@export var decal_size: float = 0.12
@export var particle_texture: Texture2D
@export var particle_color: Color = Color(0.6, 0.58, 0.55)
@export var particle_amount: int = 10
@export var particle_speed: float = 2.5
@export var particle_size: float = 0.12
@export var sparks: bool = false

@export_group("Footsteps")
@export var footstep_sounds: Array[AudioStream] = []
@export var land_sound: AudioStream
@export var casing_sounds: Array[AudioStream] = []
