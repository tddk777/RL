# Credits

Most art and audio in RL is generated in-repo (see `dev/`). These third-party
assets and addons are included as downloaded, with the changes noted.

| Asset | Author | License | Where | Used for |
|---|---|---|---|---|
| Universal Animation Library (Standard) | Quaternius | CC0 1.0 | `assets/third_party/quaternius_ual/` | NPC and corpse body (`characters/mannequin.gd`) |
| soviet1960s weapons psx | radint | Apache 2.0 (Godot Asset Store listing; text in `LICENSE-Apache-2.0.txt`) | `assets/third_party/soviet_psx_weapons/` | AK-47, Makarov PM, TT-33, PPSh-41, SKS models (rescaled, markers added) |
| Sound FX Starter Pack Vol. 1 | Ovani Sound | Royalty-free with commercial use, [terms](https://ovanisound.com/policies/terms-of-service) (`Royalty-Free License (Link).pdf`); ship the sounds packed in the game (Godot's .pck does this), not as loose files | `assets/third_party/sound_fx_starter_vol1/` | Wind bed and distant one-shots in Level 1 |
| Compositor Lens Flare / Godrays (`lens_effects`) | ARez | MIT (`addons/lens_effects/LICENSE`) | `addons/lens_effects/` | God rays toward the sun. Changed: added a minimal `godot/scene_data_inc.glsl` (missing from the download) and the shader no longer reads version-specific scene-data fields |
| Terrain3D 1.0.2 | Cory Petkovsek, Roope Palmroos and contributors | MIT (`addons/terrain_3d/LICENSE.txt`) | `addons/terrain_3d/` | Optional landscape (`LevelProfile.use_terrain3d`, off: it crashed Godot 4.7.2's Vulkan renderer in testing) |

## Shipping checklist

All of the above allow a paid, commercial release:
- CC0 (Quaternius): no conditions.
- MIT (lens_effects, Terrain3D) and Apache 2.0 (radint's guns): keep the
  copyright and licence texts with the game (a credits/licences screen or a
  file next to the executable). Apache 2.0 also asks that changed files say
  they were changed; the gun scenes are new files built around the models.
- Ovani Sound: royalty-free; don't redistribute the raw sound files on their own.
- Godot Engine itself (MIT) and the libraries inside it (FreeType, Jolt, ...)
  need their notices shipped too: see
  https://docs.godotengine.org/en/stable/about/complying_with_licenses.html
