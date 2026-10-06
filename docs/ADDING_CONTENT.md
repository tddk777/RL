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
4. Get it into the player's hands: add its id to `weapon_pickups` on a
   level's `LevelProfile` (it lies somewhere in the level, with ammo in
   `ammo_table`), or to `starting_weapon_ids` on `player/player.tscn`. Both
   are placeholders until loot and inventory are designed.

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

## A procedural level

Level 1 is procedural; new levels in the same spirit (L2 housing and towers,
L4 labs, ...) are mostly data:

1. **Styles.** A `ZoneStyle` (`levels/procgen/zone_style.gd`) per kind of
   space: `type` (hall, warehouse, processing, office, loading_dock,
   corridor), `weight`, `extra_storeys`, materials for floors, walls and
   ceilings, door sizes, `windows`, light kind/chance/flicker/colour, props
   with weights and density, pipe/leak/collapse/roof-hole chances.
2. **Profile.** A `LevelProfile` (`levels/procgen/level_profile.gd`) with the
   grid (`grid_size`, `storeys`, `cell_size`, `storey_height`, `chunk_cells`), block
   sizes, the corridor style and building styles, population (enemy count
   and id, exits, weapon/ammo pickups, corpses), anomalies (symbols, odd
   corpses, odd containers), and atmosphere (`environment`, ambience, random
   sounds). `dev/generators/build_l1_profile.gd` is the L1 example; copy it,
   or build the resources in the Inspector.
3. **Scene.** A scene whose root uses `levels/procgen/procedural_level.gd`
   with the profile assigned. `load_radius` (chunks around the player) and
   `frame_budget_ms` trade view distance and smoothness for cost.
4. **Register** a `LevelData` with `order`, `display_name`, `subtitle` and
   `scene_path` as for any level.

Zone types new to a level (e.g. `apartment`, `lab`) need a fill rule in
`LayoutGenerator` (`_make_buildings` / `_fill_rooms` / `_fill_tall`) and
dressing in `ChunkBuilder._dressing`; everything else (walls, doors, stairs,
lights, pipes, streaming, navigation) is shared. New wall marks go in
`dev/asset_gen/decals.py`; new "odd" things in `levels/procgen/entities/`
(spawned from `Anomalies.spawn`).

Check a profile with `dev/tests/layout_test.gd` (connectivity, exits,
determinism over several seeds) and look at it with
`dev/tests/procgen_tour.tscn`.

## A hand-built level

1. Make a scene whose root uses `levels/level.gd` (`Level`). Required child:
   a Marker3D named `PlayerSpawn`. Usually also: `WorldEnvironment`, lights, a
   `NavigationRegion3D` containing all static geometry (bake it), `EnemySpawn`
   markers, Marker3D cover points in group `cover`, and a `LevelExit`.
2. Tag static bodies with metadata `surface` (`concrete`, `metal`, `wood`)
   for the right impact and footstep sounds. Untagged counts as concrete.
3. Reusable props are in `levels/kit/` (crates, barrels, shelving, machines,
   lamps, furniture, sandbags, containers, vats, ...). Regenerate or extend
   them in `dev/generators/build_kit.gd`, or replace any prop scene with a
   real model.
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
