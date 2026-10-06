# Adding content

Everything below is data-driven: the Registry finds any `.tres` placed in
`res://content/<category>/` by its `id`, so most additions need no code.

## A weapon

1. **Model.** Make a scene whose root has `res://weapons/weapon_model.gd` and
   these child nodes (Marker3D or any Node3D):

   | Node | Purpose |
   |---|---|
   | `Muzzle` | End of the barrel, -Z downrange. Flash spawns here. |
   | `Eject` | Ejection port, +X is the throw direction for casings. |
   | `ADS` | A point on the sight line. Aiming puts it on the eye ray. |
   | `Grip_R`, `Grip_L` | Where the right and left hands go (IK). |
   | `Magazine` | Optional. Moves out/in during reloads. |
   | `Bolt` | Optional. Cycles on each shot (set `bolt_travel`, `bolt_lift_degrees`). |
   | `Mount_<slot>` | Optional. Attachment point, e.g. `Mount_optic`, `Mount_muzzle`. |

   Conventions: bore axis at y = 0, rear of receiver at z = 0, barrel along -Z,
   right side +X, 1 unit = 1 m. An imported `.glb` works: drop it in as a child
   and add the markers.
2. **Ammo.** If the caliber is new, add an `AmmoData` in `content/ammo/`
   (`caliber`, `damage`).
3. **Definition.** In the FileSystem dock: right-click `content/weapons/` >
   New Resource > `WeaponData`. Set `id`, `model_scene`, `caliber`,
   `default_ammo`, fire modes, stats and sounds. The Inspector groups the
   fields (Ammunition, Firing, Recoil, Handling, Attachments, Sound, Effects).
4. Give it to the player: add its id to `starting_weapon_ids` on
   `player/player.tscn` (temporary until an inventory exists).

Tuning tips: `hip_offset` places the gun at the hip; `ads_eye_distance` is
how far the sight sits from the eye when aiming; `length` controls how early
the gun pulls back near walls.

## An attachment

1. Model scene. For an optic, add an `ADS` marker on the optic's sight line;
   it replaces the weapon's iron-sight ADS point.
2. `AttachmentData` in `content/attachments/`: `slot` (matches
   `Mount_<slot>`), `mount_type`, multipliers, optional `ads_fov`,
   `ads_overlay` (scope eyepiece texture), or `shot_sounds` (suppressor).
3. On the weapon's `WeaponData`, list the accepted mount types per slot in
   `mount_types` (e.g. `{"optic": ["picatinny"]}`), and add it to
   `default_attachments` to spawn it mounted.

## An enemy

1. **Behaviour.** AI states are nodes under the NPC's `Brain`. The base scene
   `ai/human_npc.tscn` has Idle, Patrol, Investigate, Combat and Dead. For a
   new kind of enemy, duplicate the scene and add or replace state scripts
   (extend `AIState`; switch with `brain.change(&"state")`; use the helpers on
   `NPC`: `move_to`, `face`, `aim_at`, `weapon`, `perception`).
2. **Body.** The `Body` node must provide `setup(health)`,
   `hold_weapon(weapon)`, `set_motion(speed, run)`, `set_aim(target, aiming)`,
   `die(direction)` and an `eye` node. `characters/humanoid.gd` is the
   procedural reference body.
3. **Numbers.** `EnemyData` in `content/enemies/`: scene, health, weapon,
   sight range/FOV, detection time, hearing, aim error, reaction time, bursts,
   speeds.
4. **Place it.** Add an `EnemySpawn` node to a level, set `enemy_id`, and
   optionally point `patrol_route` at a Node3D whose Marker3D children are the
   patrol points.

## A level

1. Make a scene whose root uses `levels/level.gd` (`Level`). Required child:
   a Marker3D named `PlayerSpawn`. Usually also: `WorldEnvironment`, lights, a
   `NavigationRegion3D` containing all static geometry (bake it), `EnemySpawn`
   markers, Marker3D cover points in group `cover`, and a `LevelExit`.
2. Tag static bodies with metadata `surface` (`concrete`, `metal`, `wood`)
   for the right impact and footstep sounds. Untagged counts as concrete.
3. Reusable props are in `levels/kit/` (crates, barrels, shelving, machines,
   lamps, furniture, sandbags, ...). Regenerate or extend them in
   `dev/generators/build_kit.gd`, or replace any prop scene with a real model.
4. Register: a `LevelData` in `content/levels/` with `order` (play order),
   `display_name`, `subtitle` and `scene_path`. The level exit loads the next
   `order`; the last one shows the end screen.
5. On the level root, set `ambience`, `random_sounds` (distant drips, groans)
   and the reverb values.

## A surface

`SurfaceData` in `content/surfaces/` with impact sounds, decals, particle
look, footstep, landing and casing sounds. Tag colliders with the same id.

## Menus and UI

Screens are scenes in `ui/screens/`; extend `MenuScreen` and build widgets in
`build(column)`, using `UIStyle` helpers so everything matches. Show with
`UI.push_screen(path)` / `UI.replace_screen(path)`; go back with
`UI.pop_screen()`. In-game overlay elements belong in `ui/ui.tscn` (`HUD`).

## New gameplay systems

Prefer a component node or an autoload service that talks through `Events`.
Examples of where future systems fit:
- Inventory/loot: `ItemData` subclasses already model items; containers and
  bodies can be `Interactable`s that open an inventory screen.
- Armor/medical: hook `HealthComponent` / `Hitbox.receive_hit()` (zones are
  already reported in `HitInfo.zone`).
- Extraction: `LevelExit` is the hook for "leave the level" conditions.
