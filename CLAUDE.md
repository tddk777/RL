# RL

A 3D card game built with **Godot 4.7 (GDScript)**. The camera looks down at a
fixed table; there is no free movement around a world.

## Local machine rule: everything lives on E:

The developer's Windows machine keeps all local installs on the **E: drive**.
Never install, download, cache or extract anything to C: (no default
`Program Files`, `%APPDATA%`, `%LOCALAPPDATA%` or `%TEMP%` locations).

| What | Where |
|---|---|
| Godot editor (versioned) | `E:\Tools\Godot\<version>\` |
| Godot editor data, settings, export templates | `E:\Tools\Godot\<version>\editor_data\` (self-contained mode) |
| Downloads for tool installs | `E:\Tools\_downloads\` |
| Any other tool / SDK | `E:\Tools\<name>\` |
| This repo | `E:\Projects\RL` |

When giving install steps or writing scripts for the local machine:
- Pass an explicit E: install path. If a tool's installer has no path option,
  say so and ask before using it.
- Point download and cache locations at E: as well (for example
  `npm config set cache E:\Tools\_cache\npm`, `PIP_CACHE_DIR=E:\Tools\_cache\pip`).
- Scripts must refuse to run when E: is missing rather than fall back to C:.
- `tools/setup-windows.ps1` installs Godot this way; extend it rather than
  adding one-off instructions.

This rule is about the developer's machine. Cloud or CI containers can use
their own scratch locations.

## Project layout

- `project.godot`: project settings. The repo root is the Godot project root.
- `scenes/`: `main.tscn` (table, camera, lights, HUD) and `card.tscn`.
- `scripts/`: one script per scene node type (`Card`, `Hand`, `PlayZone`, `Deck`, table controller).
- `data/cards/`: one `CardData` `.tres` per card. The deck loads every file in this folder.
- `tools/`: Windows setup and launch scripts (`.gdignore` keeps Godot from importing them).

## Conventions

- GDScript with static types (`var x: int`, `-> void`), tabs for indentation.
- Use `class_name` for reusable node scripts and resources.
- Card definitions are data (`CardData` resources), not code.
- A card's root transform belongs to whatever lays it out (`Hand`, `PlayZone`);
  hover effects only move its `Visual` child.
- Mouse picking goes through the `cards` physics layer (layer 2) and a ray cast
  in `_physics_process`, so overlapping cards resolve to the top one.
- Commit `.uid` files that Godot generates next to scripts. `.godot/` is ignored.

## Checking changes

From the repo root, with Godot on PATH or via its full path:

```
godot --headless --import            # re-import, surfaces parse errors
godot --headless --quit-after 120    # run the main scene for ~2s headless
```
