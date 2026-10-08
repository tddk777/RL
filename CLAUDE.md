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
  audio.gd         Pooled 2D/3D one-shots, ambience and music crossfades; owns
                   an Acoustics node (acoustics.gd, not an autoload)
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
player/          Player (FPS controller: stand/crouch/prone, stamina, lean, vault and
                 mantle, aim sway that shots follow) + WeaponHolder (viewmodel, ADS, IK arms)
characters/      NPCBody (body contract), Mannequin (rigged UAL body: clips + arm IK +
                 bone hitboxes), Humanoid (procedural fallback), ArmRig (IK arm)
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
- **NPC bodies**: extend `NPCBody`: `setup(health) -> hitboxes`, `hold_weapon()`,
  `set_motion()`, `set_aim()`, `die()`, `pose_dead()`, plus an `eye` node.
  `characters/mannequin.gd` is the rigged one (Quaternius UAL: clips play,
  then `PoseHook` bends the chest to the aim and solves the arms onto the
  weapon's `Grip_R`/`Grip_L`); `characters/humanoid.gd` is procedural.
- **AI behaviour**: one `AIState` node per behaviour under the NPC's `Brain`
  (idle, patrol, investigate, combat, search, dead). States switch with
  `brain.change(&"name")`. Enemy types = scene + EnemyData.
  `Perception`: awareness builds from sight (distance, stance, movement,
  `Player.light_exposure`, muzzle flash, torch in the face, centre vs edge
  of view) and hearing (`Events.noise_emitted`, halved through walls, placed
  roughly); the AI only ever goes for `last_known_position` (own senses and
  mates' callouts, never the real position). `AIDirector` (one per level):
  callouts passed to mates in earshot after a delay, roles (flank / hold /
  fight), cover reservations, openings (player reloading in earshot, just
  hit). `Tactics.find()` samples navmesh spots and classifies cover (low,
  side, deep) by rays from the threat's eyes. Combat: take cover, peek and
  hide, flank, push, retreat, suppressive fire, tactical reloads; aim error
  starts wide and settles while tracking, grows when moving, hit or pinned
  (`NPC.suppression`, from near misses in `Ballistics`). The player is
  suppressed by NPC fire too (aim sway, darker edges).
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
  stairwell), stairs, doors, maintenance tunnels (`profile.basement`: a
  storey below ground, index -1; `LevelLayout.basement`, `all_storeys()`;
  storey 0 is always the ground floor, so loops over `range(L.storeys)`
  skip the tunnels unless they use `all_storeys()`; tunnel walls stop under
  the ground-floor slab, `ChunkBuilder.BURIED`), cut corners (`CHAMFER`),
  windows (`WINDOW`, upper rooms overlook halls), stub walls (`PARTIAL`),
  collapse, connectivity, then odd ways through
  where they make the biggest shortcuts (per-cell `extra` flags: `BREACH`
  holes anyone fits through, `VENT` crawl vents only the crouching player
  fits, stash rooms whose only way in is a vent), raised platforms and
  sunken pits (`PODIUM`, `PIT`; `ChunkBuilder.level_feature()` places them
  clear of lanes), drop-downs (`DROP`: a corner of an upper floor broken
  through where it saves the longest walk; one way, not in `links()`),
  exits, enemies, pickups, anomalies, and last split rooms (`SPLIT`: a
  thin partition with a doorway walls off a small back room along one
  side of a one-cell room, e.g. an office's records room; only where no
  door, window, hole or entity is in its way). `links()` counts
  breaches; vents only with `crawl`, so enemies and exits never depend on
  them. Everything that isn't a building cell (open ground, yards,
  walkways) is "outdoor" to a building, which builds that wall whole.
  Stairs (`ChunkBuilder._flight`): solid concrete flights with a soffit,
  nosings and a balustrade in interiors, stairwells and tunnels; steel
  stairs (channel stringers, tread plates, posted rails) on factory floors;
  both walk on one ramp collider. `GeoBuilder.extrude()` builds stepped
  profiles.
  `ChunkBuilder` (architecture) and `SetPieces` (machines, conveyor lines,
  furnaces, racks, cubicles, boilers, lockers, yards, open ground, and
  `_clutter` odds and ends checked against `ChunkData.taken`) turn
  8 m cells into merged meshes, collision, occluders and navigation source on
  worker threads. Then `Detailer` dresses each cell from how it meets its
  neighbours (the Townscaper idea: detail follows whatever the layout
  does): every free wall run filled from the room's kit (floor pieces, then
  things hung in the gaps; capped per cell and per room by `PER_CELL` /
  `PER_ROOM`, never the same piece twice running unless it comes in rows,
  movable things often left askew), riser pipes or rubbish in inside
  corners, a rare small scene breaking the pattern (`_oddity`: a camp, a
  toppled rack, dumped furniture, hanging cables, a spill), only the odd
  EXIT sign as a hint (from `ChunkBuilder.exit_dist`; no door plates),
  storey numbers in stairwells, pipes
  and cables down every cramped passage at a fixed side and height per axis
  so runs join cell to cell, walkway lines on factory floors. Hung things
  stand `Detailer.NUDGE` proud so they never share a plane with wall trim. Kit props are merged into the chunk meshes (lamps stay
  nodes). `ProceduralLevel.prepare()` builds the whole level while it loads
  (no streaming), adds the daylight, god rays (`lens_effects` compositor),
  the landscape (`ProceduralLevel.ground_height()`: flat over the site and a
  strip round it, then embankments and hills; a `Landscape` mesh, or
  Terrain3D with `use_terrain3d`, off because Terrain3D 1.0.2 crashed Godot
  4.7.2's Vulkan renderer) and the skyline, bakes one navigation mesh, then
  snaps entities onto it.
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
- **Scanned props** (`levels/procgen/model_props.gd`): Poly Haven models
  (CC0) baked once into one mesh each with a kit-style origin, placed through
  `ChunkBuilder.kit()` by id like kit props (box collider round the bounds if
  `solid`), drawn as one MultiMesh per model per chunk. They face +Z (kit
  props -Z). The Detailer and set pieces skip them when they aren't fetched.
- **World surfaces**: level materials use `assets/shaders/world_surface.gdshader`
  (world-space triplanar, no UVs needed): noise-driven texture offsets hide
  tiling, and grime, water and rust runs, damp, dust and ceiling stains are
  generated from world position. Materials tune it per surface
  (`dev/generators/build_materials.gd`); most use Poly Haven scans
  (`ph/<name>`, scale = 1 / the scan's real size in metres). Normal Z is
  rebuilt from X and Y, so normal maps can be VRAM-compressed (RGTC).
- **Acoustics** (`autoload/acoustics.gd`, `Audio.acoustics`): rays round the
  listener (`listener`, the player's head) every 0.2 s measure how big and
  enclosed the space is and whether there's sky, and steer the World and
  Weapons bus reverbs and the Weapons bus echo taps (timed off far walls
  beyond 12 m). `Audio.play_3d` muffles sounds behind walls (`occlusion()`:
  dB and low-pass cutoff per wall) and holds back Weapons-bus sounds by their
  travel time (`arrival_delay()`, 343 m/s). AI hearing (`Events` noise) is
  not delayed. Bus effects live in `default_bus_layout.tres`.
- **Weapons**: `WeaponData.effective_range` sets how far NPCs carrying it
  want to fight; shot is `AmmoData.pellets` / `pellet_spread` (damage per
  pellet); pump actions and revolvers use the BOLT fire mode with
  `ejects_casings` off. `EnemyData.weapon_pool` / `weapon_weights` give each
  NPC its gun.
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

## Generated and third-party assets

Most art and audio is generated in-repo. Third-party packs live in
`assets/third_party/` and `addons/`, each credited in `CREDITS.md` (keep it
current when adding one): the UAL mannequin and animations, the Soviet PSX
guns, the Sound FX Starter Pack, `lens_effects`, Terrain3D, and the Poly
Haven textures and models (`assets/third_party/polyhaven/`, fetched by
`python3 -I dev/asset_gen/fetch_polyhaven.py`; authors per asset in its
`SOURCES.md`). Review any addon code before enabling it; pure data (glb,
gltf, png, jpg, wav) is safe to drop in. Downloads are image/model/sound
data only, from known sources, checksummed; never executables or archives.
Regenerate the generated ones with:

```
python3 dev/asset_gen/textures.py           # PBR textures + FX sprites (numpy, scipy, Pillow)
python3 dev/asset_gen/audio.py              # all sound effects and ambience (or one family: weapons, people, ...)
godot --headless --path . --script res://dev/generators/build_materials.gd
godot --headless --path . --script res://dev/generators/build_weapons.gd   # -- <id> ... for only those
godot --headless --path . --script res://dev/generators/build_kit.gd
godot --headless --path . --script res://dev/generators/build_content.gd   # overwrites content/*.tres (-- <id> ... for only those)
godot --headless --path . --script res://dev/generators/build_l1_profile.gd  # overwrites the L1 profile
python3 dev/asset_gen/decals.py             # wall symbols, puddles, papers, cracks, oil, moss, peeling plaster
python3 dev/asset_gen/noise.py              # tileable noise for the world surface shader
python3 dev/asset_gen/terrain_textures.py   # Terrain3D landscape textures (packed albedo+height, normal+roughness)
python3 -I dev/asset_gen/fetch_polyhaven.py # Poly Haven scans and models (network; skips what's there)
godot --headless --path . --script res://dev/generators/build_psx_weapons.gd  # PSX gun scenes, markers, stats
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
godot --headless res://dev/tests/movement_test.tscn    # running, stamina, aim sway, vault, mantle, prone, lean
godot --headless res://dev/tests/ai_test.tscn          # cover, peeking, suppression, flanking, pushing, searching
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
