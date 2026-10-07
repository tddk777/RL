# RL

Single-player, first-person extraction shooter built with **Godot 4.7 (GDScript,
Forward+, Jolt physics)**. Realistic, tense, post-apocalyptic, with an esoteric /
alchemical layer that grows level by level. The player goes through stages
(levels) in order to reach the end, Road to Vostok style.

Gameplay rules beyond the current foundation (inventory, looting, extraction
rules, armor, medical) have **not been designed yet**. Don't invent them; ask.
See "Planned, not built" below.

## Local machine rule: everything lives on E:

The developer's Windows machine keeps all local installs on the **E: drive**.
Never install, download, cache or extract anything to C: (no default
`Program Files`, `%APPDATA%`, `%LOCALAPPDATA%` or `%TEMP%` locations).

| What | Where |
|---|---|
| Godot editor (versioned) | `E:\Tools\Godot\<version>\` |
| Godot editor data, settings, export templates | `E:\Tools\Godot\<version>\editor_data\` (self-contained mode) |
| Downloads for tool installs | `E:\Tools\_downloads\` |
| Any other tool / SDK (Python, Blender, ...) | `E:\Tools\<name>\` |
| This repo | `E:\Projects\RL` |

When giving install steps or writing scripts for the local machine:
- Pass an explicit E: install path. If a tool's installer has no path option,
  say so and ask before using it.
- Point download and cache locations at E: as well (for example
  `PIP_CACHE_DIR=E:\Tools\_cache\pip`).
- Scripts must refuse to run when E: is missing rather than fall back to C:.
- `tools/setup-windows.ps1` installs Godot this way; extend it rather than
  adding one-off instructions.
- Known gap: an *exported* game build writes `user://` (settings) under
  `%APPDATA%`. Running from the self-contained editor keeps it on E:. Decide
  how exported builds should store data before shipping one.

This rule is about the developer's machine. Cloud or CI containers can use
their own scratch locations.

## Architecture

Data-driven and modular: new content is a resource file (plus a scene/model),
not new code. See `docs/ADDING_CONTENT.md` for step-by-step recipes.

```
autoload/        Global services (autoloads, in load order)
  events.gd        Signal bus (noise for AI hearing, damage, kills, spawns, settings)
  settings.gd      Input bindings, graphics presets, volumes; user://settings.cfg
  registry.gd      Indexes every .tres under res://content/<category>/ by `id`
  audio.gd         Pooled 2D/3D one-shots, ambience and music crossfades
  ballistics.gd    Projectile simulation (velocity, drop, flyby cracks)
  effects.gd       Impact particles, decals, casings, tracers (from SurfaceData)
  game.gd          Run flow: menu -> level N -> next level -> end; pause; death
ui/ui.tscn       UI autoload: screen stack, HUD, scope overlay, fades, title cards
core/            Engine-agnostic building blocks
  data/            Resource classes: ItemData, WeaponData, AmmoData, AttachmentData,
                   EnemyData, LevelData, SurfaceData
  health_component, hitbox, hit_info, interactable, surface, layers, ik,
  action_timeline, mesh_kit (procedural modelling, also used by generators)
weapons/         Weapon (runtime firearm), WeaponModel (marker contract), MuzzleFlash
player/          Player (FPS controller) + WeaponHolder (viewmodel, ADS, sway, IK arms)
characters/      Humanoid (procedural body + hitboxes), ArmRig (IK arm)
ai/              NPC, Perception (sight + hearing), AIBrain + AIState scripts in states/
levels/          Level base, EnemySpawn, LevelExit, FlickerLight, kit/ props
  procgen/         Procedural levels: profile/style resources, layout generator,
                   chunk builder, set pieces, ProceduralLevel, entities/ (exits,
                   levers, pickups, corpses, anomalies, leaks)
  l1_industrial/   Level 1 scene + its LevelProfile (l1_profile.tres)
content/         The data: weapons, ammo, attachments, enemies, levels, surfaces (.tres)
assets/          Generated textures, audio, materials, models
dev/             Generators (rebuild assets) and tests. Not game code.
tools/           Windows setup/launch scripts (.gdignore)
```

Key contracts:
- **Weapon models**: scene root with `WeaponModel` script and marker nodes
  `Muzzle`, `Eject`, `ADS`, `Grip_R`, `Grip_L`, optional `Magazine`, `Bolt`,
  `Mount_<slot>`. Origin at the bore axis / rear of receiver, barrel along -Z.
- **NPC bodies**: `setup(health) -> hitboxes`, `hold_weapon()`, `set_motion()`,
  `set_aim()`, `die()`, plus an `eye` node. `characters/humanoid.gd` is the
  reference implementation; a rigged imported model can implement the same API.
- **AI behaviour**: one `AIState` node per behaviour under the NPC's `Brain`.
  States switch with `brain.change(&"name")`. Enemy types = scene + EnemyData.
- **Levels**: root has a `Level` script and `player_spawn_transform()`;
  `Game` calls `configure(seed)` (if present), adds it, then awaits
  `prepare()` before placing the player. Register with a `LevelData` (order
  decides sequence). Hand-built levels use a `PlayerSpawn` marker, `EnemySpawn`
  markers, a `LevelExit` and a baked `NavigationRegion3D`.
- **Procedural levels** (`levels/procgen/`): a `ProceduralLevel` scene with a
  `LevelProfile` (grid, storeys, how the site grows, districts, population,
  anomalies, atmosphere and daylight) whose `ZoneStyle`s set materials,
  doors, lights, shape (cramped passages, drop ceilings) and dressing per
  space type. Each style belongs to a family (`factory`, `interior`,
  `storage`); districts of those families blend at their borders.
  `LayoutGenerator.generate(profile, seed)` makes a `LevelLayout` (3D cell
  grid, zones with an irregular footprint `cols`, rooms with a use, entity
  records), deterministic per seed. It grows the site like a real one: a
  loading dock at the edge, then buildings of irregular shape (wings,
  notches, setbacks) each set against its parent or joined to it by a
  covered walkway (zone type `connector`), biased toward open ground; then
  walled courtyards (`yard`), bridges between upper floors, fills each
  building (tall halls with catwalk rings and bridges, foundries,
  warehouses, docks; storeyed blocks of rooms off a hallway with a
  stairwell), stairs, doors, cut corners (`CHAMFER`), windows (`WINDOW`),
  stub walls (`PARTIAL`), collapse, connectivity, exits, enemies, pickups,
  anomalies. Everything that isn't a building cell (open ground, yards,
  walkways) is "outdoor" to a building, which builds that wall whole.
  `ChunkBuilder` (architecture) and `SetPieces` (machines, conveyor lines,
  furnaces, racks, cubicles, boilers, lockers, yards, open ground...) turn
  8 m cells into merged meshes, collision, occluders and navigation source on
  worker threads. Kit props are merged into the chunk meshes (lamps stay
  nodes). `ProceduralLevel.prepare()` builds the whole level while it loads
  (no streaming), adds the daylight, ground and skyline, bakes one
  navigation mesh, then snaps entities onto it.
  No two faces may share a plane (that flickers): walls run between pillars
  at the grid vertices, a slab stops at the full-height walls of the storey
  below it (their tops make the floor there), fills tuck under slabs, and
  trim (sills, frames, lintels) overlaps the cut edges of a wall rather than
  meeting them flush.
  A new seed is drawn every run and every retry (`Game.level_seed`, shown in
  pause). Any per-cell randomness must use a seeded RNG (`hash([seed, x, z,
  s, purpose])`), never the global one: `Array.shuffle()` uses the global RNG.
  Navigation gotchas: the baker sees only surfaces, so tall solid boxes are
  also added as projected obstructions (`GeoBuilder.obstructions`); the
  agent radius must be a whole number of cells (it is rounded up, and 0.5 m
  closes the 1.4 m office doors); query
  paths across the level with `path_search_max_polygons = 0` (the default
  4096 gives up on long paths); wait for a map iteration before querying a
  newly added region.
- **World surfaces**: level materials use `assets/shaders/world_surface.gdshader`
  (world-space triplanar, no UVs needed): noise-driven texture offsets hide
  tiling, and grime, water and rust runs, damp, dust and ceiling stains are
  generated from world position. Materials tune it per surface
  (`dev/generators/build_materials.gd`).
- **Surfaces**: tag a collider with metadata `surface` (`concrete`, `metal`,
  `wood`, `flesh`, ...); `SurfaceData` drives impact sound/particles/decals,
  footsteps and casing sounds.
- **Physics layers** (`core/layers.gd`): 1 world, 2 player, 3 npc, 4 hitbox,
  5 interact, 6 debris, 7 trigger, 8 clip (blocks movement, not bullets).
- Bullets hit `world | hitbox`. Hitboxes forward damage (with zone
  multiplier) to a `HealthComponent`.

## Conventions

- GDScript with static types, tabs, `class_name` for reusable scripts.
- Gameplay numbers live in resources (`content/`), not in code.
- Systems talk through `Events` signals instead of direct references.
- A weapon or prop root transform belongs to whatever lays it out; visual
  offsets (hover, recoil kick) go on child nodes.
- Commit Godot's `.uid` and `.import` files. `.godot/` is ignored.
- Scripts that reference autoloads cannot be the main script of
  `godot --script` (autoload names aren't known yet at compile time); load
  them at runtime there, or run a scene instead (see dev/tests).

## Generated assets

All art and audio is generated in-repo (no third-party assets, no licenses to
track). Regenerate with:

```
python3 dev/asset_gen/textures.py           # PBR textures + FX sprites (numpy, scipy, Pillow)
python3 dev/asset_gen/audio.py              # all sound effects and ambience
godot --headless --path . --script res://dev/generators/build_materials.gd
godot --headless --path . --script res://dev/generators/build_weapons.gd
godot --headless --path . --script res://dev/generators/build_kit.gd
godot --headless --path . --script res://dev/generators/build_content.gd   # overwrites content/*.tres
godot --headless --path . --script res://dev/generators/build_l1_profile.gd  # overwrites the L1 profile
python3 dev/asset_gen/decals.py             # wall symbols, puddles, papers, cracks, oil, moss, peeling plaster
python3 dev/asset_gen/noise.py              # tileable noise for the world surface shader
```

Generators are bootstraps. Once a file is hand-edited in the editor, don't
re-run the generator that owns it unless the user wants their edits replaced.
Real art (e.g. Poly Haven / Sketchfab / freesound) can replace any generated
file as long as the contract above is kept.

## Checking changes

```
godot --headless --import                              # re-import, surfaces parse errors
godot --headless res://dev/tests/smoke_test.tscn       # end-to-end test, prints PASS/FAIL, exit code
godot --headless res://dev/tests/procgen_test.tscn     # generation, navigation, stairs, doors, exits, pickups
godot --headless --script res://dev/tests/layout_test.gd   # layout invariants over several seeds
godot --rendering-driver vulkan res://dev/tests/smoke_test.tscn -- <dir>   # also saves screenshots
godot --rendering-driver vulkan res://dev/tests/procgen_tour.tscn -- <dir> [seed]   # one shot per space type, plus views from outside
godot --headless res://dev/tests/coplanar_check.tscn -- <file> [seed] && python3 dev/tests/coplanar_check.py <file>   # faces that would flicker
```

## Planned, not built

Described by the user, waiting on their design decisions: loot (lying around,
on bodies, in containers that hold the rarest loot; L1 currently has
placeholder weapon/ammo pickups only), inventory, armor, the
realistic attachment system beyond mounting (only the M40 scope exists),
pills (healing), bandages (bleeding), extraction rules, levels 2-5
(L2 residential wood/concrete housing and towers, L3 TBD, L4 futuristic
experimentation labs, L5 TBD), with esoteric/alchemical elements increasing
each level. Lore: a Cold War US program revived alchemy; humanity gained too
much power and the world fell; deities, monsters and entities remain.
