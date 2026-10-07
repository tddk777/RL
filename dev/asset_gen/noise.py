#!/usr/bin/env python3
"""Tileable noise used by the world surface shader to break up texture tiling
and to place grime, water stains and rust.

    python3 dev/asset_gen/noise.py     # writes assets/textures/noise/world_noise.png

Channels (all 0..1, seamless):
    R  medium fbm         - picks the texture offset (anti-tiling) and patchy dirt
    G  low-frequency fbm  - large-scale colour and brightness variation
    B  vertical streaks   - water and rust runs on walls (sample stretched in y)
    A  blotches           - damp patches, stains, missing paint
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from textures import fbm, norm01, spectral, worley, blur  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "textures" / "noise"
N = 512


def main() -> None:
    r = norm01(fbm(N, 8, 6, 9101))
    g = norm01(fbm(N, 3, 5, 9202))
    b = norm01(spectral(N, 9303, beta=1.2, fmin=2, aniso=(1.0, 10.0)))
    f1, f2, _ = worley(N, 10, 9404)
    blot = norm01(blur(norm01(fbm(N, 6, 5, 9505)) * 0.7 + norm01(f2 - f1) * 0.3, 1.5))
    rgba = np.dstack([r, g, b, blot])
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA").save(OUT / "world_noise.png", optimize=True)
    print("wrote", OUT / "world_noise.png")


if __name__ == "__main__":
    main()
