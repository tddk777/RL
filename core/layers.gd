class_name Layers
## Physics layer bits. Names match project.godot [layer_names].

const WORLD := 1 << 0
const PLAYER := 1 << 1
const NPC := 1 << 2
const HITBOX := 1 << 3
const INTERACT := 1 << 4
const DEBRIS := 1 << 5
const TRIGGER := 1 << 6
## Invisible movement blockers (railing guards): stop bodies, not bullets.
const CLIP := 1 << 7

## What bullets collide with: level geometry and damageable hitboxes.
const BULLET_MASK := WORLD | HITBOX
## What blocks line of sight for AI.
const SIGHT_MASK := WORLD
