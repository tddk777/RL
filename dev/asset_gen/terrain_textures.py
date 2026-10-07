#!/usr/bin/env python3
"""Ground textures for the Terrain3D landscape round the site, packed the way
Terrain3D wants them:

    assets/textures/terrain/<name>_albedo_height.png   sRGB albedo + height in alpha
    assets/textures/terrain/<name>_normal_rough.png    OpenGL normal + roughness in alpha

    python3 dev/asset_gen/terrain_textures.py

Uses the noise helpers of textures.py; tileable and deterministic like it.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import textures as T  # noqa: E402
from textures import (Seeds, blur, cell_rand, encode_normal, fbm, finish_albedo, height_to_normal, lerp,  # noqa: E402
                      norm01, rgb, scatter_discs, spectral, sstep, strokes, warped_fbm, white, worley, zero_lines,
                      zscore)

OUT = T.TEX_DIR / "terrain"


def mat_dirt(N=1024):
    """Packed soil and gravel with pebbles, tyre-pressed patches and dry cracks."""
    S = Seeds(901)
    big = warped_fbm(N, 3, 6, S(), amount=40)
    mid = fbm(N, 10, 5, S())
    grain = zscore(blur(white(N, S()), 0.8))
    fine = spectral(N, S(), beta=0.9, fmin=40)
    f1, _, ids = worley(N, 70, S(), jitter=0.9)
    r = 0.16 + 0.22 * cell_rand(ids, S())
    pebble = T.sstep(r + 0.05, r - 0.05, f1 + 0.05 * fbm(N, 80, 2, S())) * (cell_rand(ids, S()) > 0.45)
    pebble_tone = cell_rand(ids, S()) - 0.5
    gravel_mask = sstep(-0.2, 0.9, warped_fbm(N, 5, 5, S(), amount=30))
    f1s, _, ids_s = worley(N, 180, S())
    grit = sstep(0.4, 0.2, f1s) * (cell_rand(ids_s, S()) > 0.4)
    dry = sstep(0.4, 1.4, warped_fbm(N, 4, 6, S(), amount=35))
    crack = zero_lines(warped_fbm(N, 6, 6, S(), amount=20), 1.0) * dry
    _, puddle_pits, _ = scatter_discs(N, 30, S(), prob=0.3, rmin=4, rmax=14, power=2)
    damp = sstep(0.6, 1.6, fbm(N, 4, 4, S()))

    h = (2.0 * big + 0.8 * mid + 0.3 * fine + 0.3 * grain + 0.6 * grit
         + 2.2 * pebble * gravel_mask - 1.4 * crack - 0.8 * blur(puddle_pits, 3))
    a = rgb(92, 80, 64)[None, None, :] * (1 + 0.05 * big + 0.05 * mid + 0.06 * grain)[..., None]
    a = lerp(a, rgb(120, 108, 90), dry * 0.5)
    a = lerp(a, a * 0.62, damp * 0.6)
    stone = lerp(rgb(96, 94, 90), rgb(150, 144, 134), pebble_tone + 0.5)
    a = lerp(a, stone, pebble * gravel_mask * 0.85)
    a = lerp(a, a * 1.18, grit * 0.4)
    a = lerp(a, a * 0.5, crack * 0.7)
    a *= (1.0 + 0.1 * np.clip(T.cavity(h, 2.0), -1, 1))[..., None]
    rough = 0.92 - 0.25 * damp + 0.04 * grain - 0.06 * pebble * gravel_mask
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.2), roughness=np.clip(rough, 0.5, 1.0))


def mat_scrub(N=1024):
    """Dead grass and weeds over soil: tufts of pale blades, dark gaps, moss."""
    S = Seeds(902)
    big = warped_fbm(N, 3, 6, S(), amount=45)
    mid = fbm(N, 9, 5, S())
    grain = zscore(blur(white(N, S()), 0.7))
    cover = sstep(-0.6, 0.8, warped_fbm(N, 6, 6, S(), amount=30))
    blades = strokes(N, 9000, S(), length=(10, 34), width=(0.7, 1.6), curve=0.25, intensity=(0.4, 1.0))
    blades = np.clip(blades, 0, 1) * cover
    blades_dark = strokes(N, 4000, S(), length=(8, 26), width=(0.7, 1.4), curve=0.3, intensity=(0.3, 0.9))
    blades_dark = np.clip(blades_dark, 0, 1) * cover
    moss = sstep(0.8, 1.8, fbm(N, 5, 5, S())) * (1 - cover * 0.5)
    green = sstep(0.4, 1.6, fbm(N, 4, 4, S()))

    h = 1.5 * big + 0.5 * mid + 0.3 * grain + 2.2 * blur(blades, 0.6) + 1.2 * blur(blades_dark, 0.6) + 0.6 * moss
    soil = rgb(70, 60, 48)[None, None, :] * (1 + 0.06 * mid + 0.06 * grain)[..., None]
    straw = lerp(rgb(150, 132, 92), rgb(118, 112, 70), green)
    a = lerp(soil, straw * (1 + 0.1 * grain)[..., None], np.clip(blades * 0.9, 0, 1))
    a = lerp(a, rgb(88, 84, 56), np.clip(blades_dark * 0.7, 0, 1))
    a = lerp(a, rgb(58, 66, 40), moss * 0.7)
    a *= (1.0 + 0.12 * np.clip(T.cavity(h, 2.0), -1, 1))[..., None]
    rough = 0.9 + 0.04 * grain - 0.1 * moss
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 0.9), roughness=np.clip(rough, 0.6, 1.0))


def save(name, maps):
    h = norm01(maps["height"])
    T.save_png(OUT / f"{name}_albedo_height.png", np.concatenate([maps["albedo"], h[..., None]], -1), "RGBA")
    T.save_png(OUT / f"{name}_normal_rough.png",
               np.concatenate([encode_normal(maps["normal"]), maps["roughness"][..., None]], -1), "RGBA")


if __name__ == "__main__":
    for name, fn in (("dirt", mat_dirt), ("scrub", mat_scrub)):
        save(name, fn())
        print("terrain texture", name)
