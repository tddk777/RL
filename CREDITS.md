# Credits

Most art and audio in RL is generated in-repo (see `dev/`). These third-party
assets and addons are included as downloaded, with the changes noted.

| Asset | Author | License | Where | Used for |
|---|---|---|---|---|
| Universal Animation Library (Standard) | Quaternius | CC0 1.0 | `assets/third_party/quaternius_ual/` | NPC and corpse body (`characters/mannequin.gd`) |
| 1960s Soviet Weapons PSX | *author to confirm* (pack asks to be credited) | see `readme.txt` | `assets/third_party/soviet_psx_weapons/` | AK-47, Makarov PM, TT-33, PPSh-41, SKS models |
| Sound FX Starter Pack Vol. 1 | Ovani Sound | Royalty-free, [terms](https://ovanisound.com/policies/terms-of-service) (`Royalty-Free License (Link).pdf`) | `assets/third_party/sound_fx_starter_vol1/` | Wind bed and distant one-shots in Level 1 |
| Compositor Lens Flare / Godrays (`lens_effects`) | ARez | MIT (`addons/lens_effects/LICENSE`) | `addons/lens_effects/` | God rays toward the sun. Changed: added a minimal `godot/scene_data_inc.glsl` (missing from the download) and the shader no longer reads version-specific scene-data fields |
| Terrain3D 1.0.2 | Cory Petkovsek, Roope Palmroos and contributors | MIT (`addons/terrain_3d/LICENSE.txt`) | `addons/terrain_3d/` | Optional landscape (`LevelProfile.use_terrain3d`, off: it crashed Godot 4.7.2's Vulkan renderer in testing) |

The PSX weapon pack's author name isn't in the files that were downloaded;
fill it in from the store page before shipping.
