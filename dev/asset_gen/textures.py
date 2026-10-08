#!/usr/bin/env python3
"""Procedural PBR texture and FX sprite generator.

Run from the repo root:

    python3 dev/asset_gen/textures.py              # regenerate everything
    python3 dev/asset_gen/textures.py brick rubber # only the named materials
    python3 dev/asset_gen/textures.py fx           # only the FX sprites
    python3 dev/asset_gen/textures.py --fast ...   # skip PNG optimisation

Everything is deterministic (fixed seeds). Material maps are seamlessly
tileable on both axes: every noise source is built on a periodic lattice
(gradient / value / cellular noise) or is FFT-filtered white noise, and all
filters (blur, derivatives, warps, convolutions) wrap around the edges.

Outputs
    assets/textures/<material>/albedo.png     sRGB RGB (RGBA for steel_grate)
    assets/textures/<material>/normal.png     tangent space, OpenGL (+Y up)
    assets/textures/<material>/roughness.png  L
    assets/textures/<material>/metallic.png   L (metal materials only)
    assets/textures/fx/*.png                  straight-alpha RGBA sprites
    dev/asset_gen/previews/*.png              contact sheets for QA

Height fields are expressed in pixel units (a value of 2.0 means "two texels
tall"), so the normal map is simply normalize(-dh/dx, +dh/dy_img, 1).
"""
from __future__ import annotations

import math
import os
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
TEX_DIR = ROOT / "assets" / "textures"
FX_DIR = TEX_DIR / "fx"
PREVIEW_DIR = ROOT / "dev" / "asset_gen" / "previews"

F32 = np.float32
OPTIMIZE_PNG = True


# =============================================================================
# Small helpers
# =============================================================================
class Seeds:
    """Deterministic seed stream: each call returns the next seed."""

    def __init__(self, base: int):
        self.base = base * 7919
        self.i = 0

    def __call__(self) -> int:
        self.i += 1
        return self.base + self.i * 104729


def rgb(r, g, b) -> np.ndarray:
    return np.array([r, g, b], dtype=F32) / 255.0


def sstep(e0, e1, x):
    """Smoothstep that also works with e0 > e1 (falling edge)."""
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return (t * t * (3.0 - 2.0 * t)).astype(F32)


def lerp(a, b, t):
    if isinstance(t, np.ndarray) and t.ndim == 2 and (
        (isinstance(a, np.ndarray) and a.ndim >= 1 and a.shape[-1] == 3)
        or (isinstance(b, np.ndarray) and b.ndim >= 1 and b.shape[-1] == 3)
    ):
        t = t[..., None]
    return (a + (b - a) * t).astype(F32)


def zscore(x):
    x = x.astype(F32)
    return (x - x.mean()) / (x.std() + 1e-8)


def norm01(x):
    x = x.astype(F32)
    lo, hi = x.min(), x.max()
    return (x - lo) / (hi - lo + 1e-8)


def blur(x, sigma):
    """Periodic gaussian blur (works on 2D or HxWxC)."""
    if sigma <= 0:
        return x
    if x.ndim == 3:
        return ndimage.gaussian_filter(x, (sigma, sigma, 0), mode="wrap").astype(F32)
    return ndimage.gaussian_filter(x, sigma, mode="wrap").astype(F32)


def grad(h):
    """Periodic central differences, returns (d/dx, d/dy_img)."""
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    return gx.astype(F32), gy.astype(F32)


def srgb_to_lin(c):
    c = np.asarray(c, dtype=F32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(F32)


def lin_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=F32), 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055).astype(F32)


def finish_albedo(a, lo=0.12, hi=0.92):
    """Clamp albedo (sRGB) to a physically plausible range: never pure black
    (sRGB 0.12 ~ 0.013 linear, only reached by black rubber/polymer) and
    never pure white (sRGB 0.92 ~ 0.83 linear)."""
    return np.clip(a, lo, hi).astype(F32)


def gray3(x):
    return np.repeat(x[..., None], 3, axis=2).astype(F32)


# =============================================================================
# Tileable noise
# =============================================================================
def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def perlin(n, freq, seed):
    """Periodic gradient (Perlin) noise. `freq` = lattice cells across the
    tile (int, or (fx, fy) for anisotropic noise). Output roughly [-1, 1]."""
    fx, fy = (freq, freq) if np.isscalar(freq) else freq
    fx, fy = int(fx), int(fy)
    rng = np.random.default_rng(seed)
    ang = rng.uniform(0, 2 * np.pi, (fy, fx))
    gx, gy = np.cos(ang).astype(F32), np.sin(ang).astype(F32)
    x = (np.arange(n, dtype=F32) + 0.5) * fx / n
    y = (np.arange(n, dtype=F32) + 0.5) * fy / n
    xi = np.floor(x).astype(np.int64)
    yi = np.floor(y).astype(np.int64)
    xf = (x - xi)[None, :]
    yf = (y - yi)[:, None]
    x0, x1 = (xi % fx)[None, :], ((xi + 1) % fx)[None, :]
    y0, y1 = (yi % fy)[:, None], ((yi + 1) % fy)[:, None]
    n00 = gx[y0, x0] * xf + gy[y0, x0] * yf
    n10 = gx[y0, x1] * (xf - 1) + gy[y0, x1] * yf
    n01 = gx[y1, x0] * xf + gy[y1, x0] * (yf - 1)
    n11 = gx[y1, x1] * (xf - 1) + gy[y1, x1] * (yf - 1)
    u, v = _fade(xf), _fade(yf)
    a = n00 + u * (n10 - n00)
    b = n01 + u * (n11 - n01)
    return ((a + v * (b - a)) * 1.414).astype(F32)


def fbm(n, freq, octaves, seed, gain=0.5, lac=2, ridged=False):
    """Fractal sum of periodic Perlin octaves, z-scored (mean 0, std 1).
    ridged=True builds ridged multifractal-ish sharp creases."""
    fx, fy = (freq, freq) if np.isscalar(freq) else freq
    total = np.zeros((n, n), F32)
    amp = 1.0
    for i in range(octaves):
        cx, cy = int(fx * lac ** i), int(fy * lac ** i)
        if max(cx, cy) > n // 2:
            break
        p = perlin(n, (cx, cy), seed + i * 31)
        if ridged:
            p = 1.0 - np.abs(p)
            p = p * p
        total += amp * p
        amp *= gain
    return zscore(total)


def spectral(n, seed, beta=1.0, fmin=1.0, fmax=None, aniso=(1.0, 1.0)):
    """FFT-filtered white noise with a 1/f^beta amplitude spectrum, band-limited
    to [fmin, fmax] cycles per tile. Periodic by construction. z-scored.
    aniso scales the x/y frequency axes (aniso=(1, 8) makes vertical streaks)."""
    rng = np.random.default_rng(seed)
    w = rng.standard_normal((n, n)).astype(F32)
    fy = np.fft.fftfreq(n)[:, None] * n * aniso[1]
    fx = np.fft.rfftfreq(n)[None, :] * n * aniso[0]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    amp = f ** (-beta)
    amp[f < fmin] *= np.exp(-((fmin - f[f < fmin]) / max(fmin * 0.5, 0.5)) ** 2)
    if fmax is not None:
        amp *= np.exp(-np.maximum(f - fmax, 0) ** 2 / (2 * (fmax * 0.25) ** 2))
    amp[0, 0] = 0.0
    out = np.fft.irfft2(np.fft.rfft2(w) * amp, s=(n, n))
    return zscore(out)


def white(n, seed):
    return np.random.default_rng(seed).random((n, n), dtype=F32)


def worley(n, freq, seed, jitter=0.85):
    """Periodic cellular noise. Returns (F1, F2, cell_id) with distances in
    cell units. freq = cells across the tile (square cells)."""
    rng = np.random.default_rng(seed)
    pts = (rng.random((freq, freq, 2)) * jitter + (1 - jitter) * 0.5).astype(F32)
    c = (np.arange(n, dtype=F32) + 0.5) * freq / n
    ci = np.floor(c).astype(np.int64)
    X, Y = c[None, :], c[:, None]
    f1 = np.full((n, n), 9.0, F32)
    f2 = np.full((n, n), 9.0, F32)
    idx = np.zeros((n, n), np.int64)
    for dy in (-1, 0, 1):
        ny = (ci + dy)[:, None]
        wy = ny % freq
        for dx in (-1, 0, 1):
            nx = (ci + dx)[None, :]
            wx = nx % freq
            p = pts[wy, wx]
            d = np.sqrt((X - (nx + p[..., 0])) ** 2 + (Y - (ny + p[..., 1])) ** 2)
            cid = wy * freq + wx
            m = d < f1
            f2 = np.where(m, f1, np.minimum(f2, d))
            idx = np.where(m, cid, idx)
            f1 = np.where(m, d, f1)
    return f1, f2, idx


def cell_rand(ids, seed, count=None):
    """Random value in [0,1) per cell id."""
    count = int(ids.max()) + 1 if count is None else count
    table = np.random.default_rng(seed).random(count, dtype=F32)
    return table[ids]


def cell_rand_like(n, seed):
    """Smooth-ish random field useful for modulating sparse features."""
    return norm01(fbm(n, 16, 2, seed))


def warp(img, dx, dy, order=1):
    """Sample img at (x+dx, y+dy) with wrap-around. Works on 2D or HxWxC."""
    n0, n1 = img.shape[:2]
    yy, xx = np.mgrid[0:n0, 0:n1].astype(F32)
    coords = [yy + dy, xx + dx]
    if img.ndim == 3:
        return np.stack(
            [ndimage.map_coordinates(img[..., c], coords, order=order, mode="grid-wrap")
             for c in range(img.shape[2])], axis=-1).astype(F32)
    return ndimage.map_coordinates(img, coords, order=order, mode="grid-wrap").astype(F32)


def warped_fbm(n, freq, octaves, seed, amount, wfreq=None, gain=0.5, ridged=False):
    """fBm sampled through a domain warp (another pair of fBm fields)."""
    base = fbm(n, freq, octaves, seed, gain=gain, ridged=ridged)
    wf = wfreq or max(2, freq)
    dx = fbm(n, wf, 4, seed + 7) * amount
    dy = fbm(n, wf, 4, seed + 13) * amount
    return zscore(warp(base, dx, dy))


def zero_lines(field, width):
    """Thin lines along the zero set of a field, with approximately constant
    pixel width (distance estimate |f| / |grad f|). Great for cracks."""
    gx, gy = grad(field)
    d = np.abs(field) / (np.sqrt(gx * gx + gy * gy) + 1e-6)
    return sstep(width, 0.0, d)


def scatter_discs(n, freq, seed, prob, rmin, rmax, power=2.0, jitter=0.8):
    """Randomly sized discs on a periodic jittered grid (at most one per cell).
    Returns (dome profile 0..1, disc mask, per-cell random) arrays."""
    f1, _, ids = worley(n, freq, seed, jitter=jitter)
    cell = n / freq
    r = rmin + (rmax - rmin) * cell_rand(ids, seed + 1) ** power
    keep = cell_rand(ids, seed + 2) < prob
    d = f1 * cell
    mask = sstep(r + 0.75, r - 0.75, d) * keep
    dome = np.sqrt(np.clip(1 - (d / np.maximum(r, 1e-3)) ** 2, 0, 1)) * keep
    return dome.astype(F32), mask.astype(F32), cell_rand(ids, seed + 3)


def strokes(n, count, seed, length=(10, 60), width=(1.0, 2.0), curve=0.15,
            intensity=(0.4, 1.0), ss=2, segs=8, angle=None, angle_jitter=None, turn=(0.0, 0.0)):
    """Tileable anti-aliased polyline strokes (scratches, scuffs, creases).
    Lines are drawn at the 9 wrap offsets so they continue across edges."""
    rng = np.random.default_rng(seed)
    img = Image.new("L", (n * ss, n * ss), 0)
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x, y = rng.random(2) * n
        a = rng.uniform(0, 2 * np.pi) if angle is None else angle + rng.normal(0, angle_jitter or 0.05)
        L = rng.uniform(*length)
        w = rng.uniform(*width)
        val = int(255 * rng.uniform(*intensity))
        pts = [(x, y)]
        step = L / segs
        tr = rng.uniform(*turn) * rng.choice([-1, 1])
        for _ in range(segs):
            a += rng.normal(0, curve) + tr
            x += math.cos(a) * step
            y += math.sin(a) * step
            pts.append((x, y))
        lw = max(1, int(round(w * ss)))
        for ox in (-n, 0, n):
            for oy in (-n, 0, n):
                d.line([((px + ox) * ss, (py + oy) * ss) for px, py in pts], fill=val, width=lw)
    img = img.resize((n, n), Image.BOX)
    return np.asarray(img, dtype=F32) / 255.0


def periodic_convolve(src, kernel):
    return np.fft.irfft2(np.fft.rfft2(src) * np.fft.rfft2(kernel), s=src.shape).astype(F32)


def drip_kernel(n, length, width, down=True):
    """Kernel that smears a source downward (image +y) with exponential fade,
    for streaks and runs. Wraps around."""
    dy = np.arange(n, dtype=F32)[:, None]            # 0..n-1 downward distance
    dx = ((np.arange(n) + n // 2) % n - n // 2).astype(F32)[None, :]
    k = np.exp(-dy / length) * (dy < n * 0.9)
    k = k * np.exp(-0.5 * (dx / width) ** 2)
    if not down:
        k = np.roll(k[::-1], 1, axis=0)
    return (k / k.sum()).astype(F32)


def streaks(n, seed, count, length, width, src_mask=None, xnoise=True):
    """Vertical run/drip streaks hanging below random source points."""
    rng = np.random.default_rng(seed)
    src = np.zeros((n, n), F32)
    ys = rng.integers(0, n, count)
    xs = rng.integers(0, n, count)
    vals = rng.uniform(0.3, 1.0, count).astype(F32)
    if src_mask is not None:
        vals *= src_mask[ys, xs]
    np.add.at(src, (ys, xs), vals)
    out = periodic_convolve(src, drip_kernel(n, length, width))
    if xnoise:
        out *= 0.4 + 0.6 * norm01(spectral(n, seed + 1, beta=0.8, fmin=4, aniso=(1.0, 12.0)))
    return norm01(out) ** 0.7


def height_to_normal(h, strength=1.0):
    """Tangent-space normal map from a height field in texel units.
    OpenGL convention: +X right, +Y up (green up), as Godot expects."""
    gx, gy = grad(h * strength)
    nx, ny, nz = -gx, gy, np.ones_like(gx)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx / l, ny / l, nz / l], axis=-1).astype(F32)


def encode_normal(nrm):
    return (nrm * 0.5 + 0.5).astype(F32)


def cavity(h, sigma):
    """Positive where the surface sits above its local average."""
    return (h - blur(h, sigma)).astype(F32)


# =============================================================================
# Output
# =============================================================================
def _to_u8(a, dither_seed=None):
    a = np.clip(a, 0, 1) * 255.0
    if dither_seed is not None:
        a = a + (np.random.default_rng(dither_seed).random(a.shape, dtype=F32) - 0.5)
    return np.clip(np.round(a), 0, 255).astype(np.uint8)


def save_png(path: Path, arr, mode, dither_seed=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    img = Image.fromarray(_to_u8(arr, dither_seed), mode=None)
    if img.mode != mode:
        img = img.convert(mode)
    img.save(path, optimize=OPTIMIZE_PNG, compress_level=9)


def save_material(name, maps):
    out = TEX_DIR / name
    a = maps["albedo"]
    if a.shape[-1] == 4:
        save_png(out / "albedo.png", a, "RGBA")
    else:
        save_png(out / "albedo.png", a, "RGB")
    save_png(out / "normal.png", encode_normal(maps["normal"]), "RGB")
    save_png(out / "roughness.png", maps["roughness"], "L")
    if "metallic" in maps:
        save_png(out / "metallic.png", maps["metallic"], "L")


# =============================================================================
# Materials. Each returns dict(albedo HxWx3 sRGB [or x4], normal HxWx3 unit,
# roughness HxW, [metallic HxW], height HxW). Height is in texel units.
# =============================================================================

# ---------------------------------------------------------------- concrete ---
def mat_concrete_floor(N=1024):
    S = Seeds(101)
    big = warped_fbm(N, 3, 7, S(), amount=50)
    mid = fbm(N, 8, 5, S())
    fine = spectral(N, S(), beta=0.9, fmin=30)
    grain = zscore(blur(white(N, S()), 0.6))
    grain2 = zscore(blur(white(N, S()), 1.3))
    # Patchy cement-paste tone with defined (not cloudy) edges.
    patch = sstep(0.3, 0.7, warped_fbm(N, 6, 6, S(), amount=30))

    # Sand / fine aggregate: small cells with individual tones.
    f1, f2, ids = worley(N, 150, S())
    sand = sstep(0.45, 0.25, f1) * (cell_rand(ids, S()) > 0.3)
    sand_tone = (cell_rand(ids, S()) - 0.5) * sand
    # Larger exposed aggregate where the cream layer is worn away.
    wear = sstep(0.8, 1.8, warped_fbm(N, 4, 6, S(), amount=40))
    f1b, _, idb = worley(N, 48, S(), jitter=0.9)
    stone_r = 0.18 + 0.22 * cell_rand(idb, S())
    stone = sstep(stone_r + 0.06, stone_r - 0.04, f1b + 0.04 * fbm(N, 64, 2, S())) * (cell_rand(idb, S()) > 0.35)
    stone_tone = cell_rand(idb, S()) - 0.5
    stone_vis = stone * wear

    # Pores / small pits.
    pore_dome, pore, _ = scatter_discs(N, 110, S(), prob=0.14, rmin=0.6, rmax=2.0, power=3)

    # Hairline cracks: zero set of a warped fBm, kept only in a few places.
    cf = warped_fbm(N, 3, 8, S(), amount=35, gain=0.55)
    crack = zero_lines(cf, 0.8) * sstep(0.7, 1.5, fbm(N, 3, 4, S()))
    crack_halo = blur(crack, 2.0)

    # Oil stains: several soft, uneven soaks + drip clusters, grain stays visible.
    of = warped_fbm(N, 4, 7, S(), amount=45, gain=0.55)
    oil = sstep(1.35, 2.2, of) * (0.75 + 0.25 * norm01(mid))
    clus = sstep(0.6, 1.6, fbm(N, 5, 4, S()))
    drips_d, drips, _ = scatter_discs(N, 40, S(), prob=0.5, rmin=1.5, rmax=9, power=2.5)
    drips = blur(drips, 1.5) * clus * (0.4 + 0.6 * cell_rand_like(N, S()))
    oil = np.clip(oil + drips * 0.7, 0, 1)
    oil_soak = np.clip(blur(oil, 10) * 0.7, 0, 1)

    # Power-trowel swirl arcs (sheen + slight tone), rubber scuffs, scratches.
    trowel = blur(strokes(N, 220, S(), length=(120, 320), width=(6, 16), curve=0.02,
                          turn=(0.12, 0.25), intensity=(0.2, 0.6), segs=14), 3.0)
    scuff_dark = blur(strokes(N, 160, S(), length=(20, 120), width=(1.5, 5), curve=0.12,
                              intensity=(0.15, 0.6)), 1.2)
    scuff_dark *= sstep(0.0, 1.4, fbm(N, 4, 3, S()))
    scratch = strokes(N, 400, S(), length=(8, 60), width=(0.6, 1.2), curve=0.08,
                      intensity=(0.2, 0.8)) * sstep(-0.5, 1.0, fbm(N, 3, 3, S()))

    # Dust layer (fine grain modulated, so it reads as dust and not as a cloud).
    dust = sstep(0.0, 2.0, warped_fbm(N, 4, 7, S(), amount=40))
    dust = dust * (0.6 + 0.4 * norm01(grain2))

    # --- height (texels)
    h = (1.5 * big + 0.6 * mid + 0.35 * fine + 0.25 * grain + 0.2 * grain2
         + 0.4 * sand + 0.9 * stone_vis + 0.15 * patch
         - 1.6 * pore_dome - 1.5 * crack - 0.2 * scratch)

    # --- albedo
    base = rgb(124, 122, 118)
    tone = (1.0 + 0.025 * big + 0.02 * mid + 0.03 * fine + 0.04 * grain + 0.03 * grain2
            + 0.04 * (patch - 0.5))
    a = base[None, None, :] * tone[..., None]
    tint = 0.004 * fbm(N, 3, 4, S())
    a[..., 0] += tint
    a[..., 2] -= tint
    a *= (1.0 + 0.22 * sand_tone)[..., None]
    stone_col = lerp(rgb(100, 98, 95), rgb(160, 154, 146), stone_tone + 0.5)
    a = lerp(a, stone_col, stone_vis * 0.8)
    a = lerp(a, a * 0.97, trowel * 0.6)
    a = lerp(a, a * 0.45, pore * 0.7)
    a = lerp(a, a * 0.85, crack_halo * 0.6)
    a = lerp(a, a * 0.5, crack * 0.6)
    a = a * (1.0 - 0.18 * oil_soak)[..., None]
    a = lerp(a, a * rgb(118, 108, 96) / 0.47, oil * 0.85)
    a = lerp(a, a * 0.62, scuff_dark * 0.55)
    a = lerp(a, a * 1.15, scratch * 0.45)
    dust_col = rgb(150, 144, 134) * (1 + 0.05 * grain)[..., None]
    a = lerp(a, dust_col, dust * (1 - oil) * 0.45)
    a *= (1.0 + 0.08 * np.clip(cavity(h, 2.0), -1, 1))[..., None]

    rough = (0.84 + 0.03 * mid + 0.03 * grain - 0.4 * oil - 0.1 * oil_soak - 0.12 * trowel
             - 0.1 * scuff_dark - 0.08 * scratch + 0.08 * dust - 0.05 * stone_vis)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.3, 1.0))


def mat_concrete_wall(N=1024):
    S = Seeds(202)
    big = warped_fbm(N, 3, 7, S(), amount=50)
    mid = fbm(N, 8, 5, S())
    fine = spectral(N, S(), beta=0.85, fmin=24)
    grain = zscore(blur(white(N, S()), 0.7))
    coarse = zscore(blur(white(N, S()), 1.8))

    # Cement-tone patches (lighter laitance areas with defined edges).
    blotch = sstep(0.3, 0.9, warped_fbm(N, 6, 6, S(), amount=25))
    blotch2 = sstep(0.6, 1.0, warped_fbm(N, 10, 5, S(), amount=12))
    # Bug holes (air voids of cast concrete) in clusters.
    cluster = sstep(-0.4, 1.2, fbm(N, 5, 4, S()))
    hd1, hm1, _ = scatter_discs(N, 90, S(), prob=0.30, rmin=0.8, rmax=3.5, power=2.5)
    hd2, hm2, _ = scatter_discs(N, 34, S(), prob=0.18, rmin=2.0, rmax=6.5, power=2.5)
    hdp, hmp, _ = scatter_discs(N, 200, S(), prob=0.2, rmin=0.5, rmax=1.3, power=1.5)
    holes_d = np.maximum(np.maximum(hd1 * cluster, hd2 * cluster), hdp * 0.6)
    holes_m = np.maximum(np.maximum(hm1 * cluster, hm2 * cluster), hmp * 0.6)

    # Water staining: runs hanging below random sources (vertical streaks).
    src_mask = sstep(-0.2, 1.2, fbm(N, 3, 3, S()))
    wet = streaks(N, S(), 320, length=240, width=2.0, src_mask=src_mask)
    wet2 = streaks(N, S(), 70, length=520, width=6.0, src_mask=src_mask)
    vert = norm01(spectral(N, S(), beta=1.0, fmin=3, aniso=(1.0, 14.0)))
    stain = np.clip((0.8 * wet + 0.6 * wet2) * (0.4 + 0.9 * vert), 0, 1)
    stain = sstep(0.08, 0.8, stain)
    tide = np.clip(blur(stain, 1.0) - blur(stain, 4.0), 0, 1) * 3
    efflo = streaks(N, S(), 40, length=160, width=2.5) * sstep(0.5, 1.5, fbm(N, 3, 3, S()))

    crack = zero_lines(warped_fbm(N, 3, 8, S(), amount=30, gain=0.55), 0.8) * sstep(0.9, 1.6, fbm(N, 3, 3, S()))

    h = (1.5 * big + 0.6 * mid + 0.35 * fine + 0.3 * grain + 0.45 * coarse + 0.2 * blotch2
         - 2.5 * holes_d - 1.2 * crack)

    base = rgb(146, 143, 137)
    tone = (1.0 + 0.025 * big + 0.02 * mid + 0.025 * fine + 0.035 * grain + 0.03 * coarse
            + 0.05 * (blotch - 0.5) - 0.03 * blotch2)
    a = base[None, None, :] * tone[..., None]
    warm = 0.003 * fbm(N, 2, 4, S())
    a[..., 0] += warm
    a[..., 2] -= warm
    stain_col = rgb(86, 86, 80) * (1 + 0.1 * fbm(N, 12, 3, S()))[..., None]
    a = lerp(a, stain_col, stain * 0.65)
    a = lerp(a, a * 0.85, np.clip(tide, 0, 1) * 0.3)
    a = lerp(a, rgb(176, 174, 166), efflo * 0.35)
    a = lerp(a, a * 0.5, holes_m * 0.85)
    a = lerp(a, a * 0.55, crack * 0.7)
    a *= (1.0 + 0.07 * np.clip(cavity(h, 2.0), -1, 1))[..., None]

    rough = 0.9 + 0.03 * grain - 0.06 * stain + 0.03 * blotch
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.6, 1.0))


# ------------------------------------------------------------------ metals ---
RUST_DARK = rgb(46, 30, 22)
RUST_MID = rgb(86, 48, 30)
RUST_ORANGE = rgb(124, 64, 33)
RUST_OCHRE = rgb(136, 92, 52)


def rust_layer(N, S, scale=1.0):
    """Shared rust look: colour (sRGB), height (texels, with lifted flakes)
    and a granular noise for roughness variation."""
    c1 = fbm(N, max(2, int(6 * scale)), 6, S())
    c2 = warped_fbm(N, max(2, int(12 * scale)), 5, S(), amount=12)
    c3 = spectral(N, S(), beta=0.7, fmin=40)
    granular = zscore(blur(white(N, S()), 0.8))
    t = norm01(0.55 * c1 + 0.45 * c2 + 0.12 * c3)
    col = lerp(RUST_DARK, RUST_MID, sstep(0.2, 0.5, t))
    col = lerp(col, RUST_ORANGE, sstep(0.5, 0.85, t))
    col = lerp(col, RUST_OCHRE, sstep(0.55, 1.0, norm01(c2 + 0.6 * c3)) * 0.5)
    col *= (1.0 + 0.1 * c3 + 0.06 * granular)[..., None]
    # Granular scale: dark and bright specks.
    _, dk, _ = scatter_discs(N, int(160 * scale), S(), prob=0.3, rmin=0.5, rmax=1.6)
    _, lt, _ = scatter_discs(N, int(140 * scale), S(), prob=0.2, rmin=0.5, rmax=1.3)
    col = lerp(col, col * 0.55, dk * 0.7)
    col = lerp(col, RUST_OCHRE * 1.1, lt * 0.4)
    # Flakes: irregular plates (warped cells) lifted with crisp edges.
    f1, f2, ids = worley(N, max(4, int(40 * scale)), S())
    wdx = fbm(N, max(2, int(24 * scale)), 3, S()) * 4.0
    wdy = fbm(N, max(2, int(24 * scale)), 3, S()) * 4.0
    edge = warp(sstep(0.0, 0.1, f2 - f1), wdx, wdy)
    lift = warp(cell_rand(ids, S()), wdx, wdy, order=0)
    flake_zone = sstep(0.4, 1.2, fbm(N, max(2, int(8 * scale)), 4, S()))
    flakes = edge * lift * flake_zone
    h = 1.0 * c1 + 0.6 * c2 + 1.8 * flakes + 0.4 * granular + 0.35 * c3 + 0.6 * lt - 0.6 * dk
    col = lerp(col, col * 0.6, (1 - edge) * flake_zone * 0.45)       # dark gaps between flakes
    col = lerp(col, RUST_OCHRE, flakes * (lift > 0.7) * 0.25)         # fresh flaky tops
    return col.astype(F32), h.astype(F32), granular


def mat_rusted_metal(N=1024):
    S = Seeds(303)
    cov = warped_fbm(N, 3, 7, S(), amount=60, gain=0.55)
    ragged = fbm(N, 48, 3, S())
    # Blooms: circular rust spots radiating from points.
    f1, _, ids = worley(N, 10, S())
    br = 0.25 + 0.3 * cell_rand(ids, S())
    bloom_d = f1 / br + 0.25 * fbm(N, 24, 3, S())
    bloom = sstep(1.0, 0.4, bloom_d) * (cell_rand(ids, S()) > 0.25)
    field = cov + 1.5 * bloom + 0.25 * ragged
    rust = sstep(-0.45, -0.25, field)
    rust_heavy = sstep(0.0, 1.5, field)
    # Isolated rust pustules scattered over the bare steel.
    pd_, pus, _ = scatter_discs(N, 70, S(), prob=0.25, rmin=1.0, rmax=4.0, power=2)
    pus = pus * sstep(-1.6, -0.6, field)
    rust = np.maximum(rust, pus)

    rcol, rh, granular = rust_layer(N, S)
    # Bare steel: dark grey, crisp mill-scale islands, sanded/scratched spots.
    sfine = spectral(N, S(), beta=0.8, fmin=16)
    steel = rgb(104, 104, 105) * (1 + 0.05 * sfine + 0.03 * fbm(N, 6, 4, S()))[..., None]
    mill = sstep(0.2, 0.35, warped_fbm(N, 8, 6, S(), amount=15))
    steel = lerp(steel, rgb(76, 76, 78) * (1 + 0.05 * sfine)[..., None], mill * 0.8)
    sscr = strokes(N, 450, S(), length=(10, 50), width=(0.6, 1.2), curve=0.05, intensity=(0.2, 0.7))
    steel = lerp(steel, rgb(160, 160, 162), sscr * 0.35)
    halo = sstep(0.0, 0.7, blur(rust, 8))
    steel = lerp(steel, rgb(92, 66, 50), halo * 0.55)          # brown oxide tint near rust

    pd, pm, _ = scatter_discs(N, 80, S(), prob=0.35, rmin=0.8, rmax=3.0, power=2)
    pits_zone = sstep(-1.2, -0.3, field)
    pits = pm * pits_zone
    pits_d = pd * pits_zone

    a = lerp(steel, rcol, rust)
    a = lerp(a, a * 0.4, pits * 0.8)
    ring = sstep(0.5, 0.8, bloom_d) * sstep(1.1, 0.8, bloom_d) * (bloom > 0)
    a = lerp(a, RUST_ORANGE, ring * 0.25 * rust)

    h = (0.2 * sfine - 1.4 * pits_d + 0.3 * mill
         + rust * (1.0 + 0.6 * rust_heavy) + rust * rh * (0.6 + 0.6 * rust_heavy))
    a *= (1.0 + 0.1 * np.clip(cavity(h, 2.5), -1, 1))[..., None]

    metal = (1 - rust) * (0.9 - 0.35 * mill - 0.3 * halo) * (1 - 0.5 * pits)
    rough = lerp(0.45 + 0.05 * sfine - 0.1 * sscr + 0.25 * mill + 0.15 * halo,
                 0.88 + 0.05 * granular, rust)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.25, 1.0), metallic=np.clip(metal, 0, 1))


def mat_painted_steel(N=1024):
    S = Seeds(404)
    paint = rgb(98, 104, 90)          # industrial green-grey
    fade = fbm(N, 4, 6, S())
    mid = fbm(N, 10, 4, S())
    fine = spectral(N, S(), beta=0.8, fmin=40)
    speck = zscore(blur(white(N, S()), 0.7))
    # Chips: large warped patches + small cellular flecks.
    chip_f = warped_fbm(N, 5, 7, S(), amount=25, gain=0.6) + 0.15 * fbm(N, 64, 2, S())
    small_f1, small_f2, sid = worley(N, 70, S())
    small = sstep(0.42, 0.3, small_f1 * (0.7 + 0.6 * cell_rand(sid, S()))) * (cell_rand(sid, S()) > 0.8)
    small = small * sstep(-0.3, 0.6, chip_f)
    density = sstep(-1.0, 1.0, fbm(N, 3, 3, S()))
    chip_val = chip_f + 0.7 * density
    chip = np.maximum(sstep(1.5, 1.58, chip_val), small)
    chip_core = sstep(2.3, 2.6, chip_val)                          # worn through to bare steel
    primer = np.clip(sstep(1.38, 1.46, chip_val) - chip, 0, 1)      # red-oxide primer ring
    primer = np.maximum(primer, np.clip(blur(small, 0.8) * 1.6 - small, 0, 1) * 0.7)
    halo = np.clip(blur(chip, 8) * 2.0 - chip, 0, 1)                # rust bleed under paint
    # Blisters where rust pushes up the paint.
    bd, bm, _ = scatter_discs(N, 70, S(), prob=0.5, rmin=1.5, rmax=4.5, power=2)
    blisters = bd * sstep(0.15, 0.5, halo) * (1 - chip)
    grime = sstep(0.0, 1.8, warped_fbm(N, 5, 7, S(), amount=30)) * (0.6 + 0.4 * norm01(speck))
    chalk = sstep(0.6, 1.8, fade) * (0.7 + 0.3 * norm01(speck))
    scr = strokes(N, 350, S(), length=(10, 70), width=(0.6, 1.3), curve=0.06, intensity=(0.2, 0.9))
    scr *= (1 - chip)

    rcol, rh, granular = rust_layer(N, S, scale=1.5)
    steel = rgb(104, 104, 106) * (1 + 0.05 * fine)[..., None]

    pcol = paint[None, None, :] * (1 + 0.015 * fade + 0.015 * mid + 0.015 * fine + 0.015 * speck)[..., None]
    pcol = lerp(pcol, rgb(122, 127, 116), chalk * 0.3)             # chalky fading
    pcol = lerp(pcol, rgb(106, 74, 50), halo * 0.5)                 # rust bleed
    pcol = lerp(pcol, pcol * 0.6, grime * 0.5)
    pcol = lerp(pcol, rgb(128, 133, 127), scr * 0.4)                # scratches through top coat
    under = lerp(rcol, steel, chip_core)
    a = lerp(pcol, rgb(118, 56, 38), primer * 0.85)
    a = lerp(a, under, chip)

    paint_th = 1.4
    h = (paint_th * (1 - chip) + 0.15 * mid + 0.08 * fine + 0.04 * speck + 1.2 * blisters
         + chip * (1 - chip_core) * (0.5 * rh - 0.3) - 0.35 * scr)
    a *= (1.0 + 0.08 * np.clip(cavity(h, 2.0), -1, 1))[..., None]

    metal = chip * chip_core * 0.9
    rough = lerp(0.5 + 0.12 * chalk + 0.12 * grime + 0.03 * fine + 0.1 * scr, 0.9 + 0.05 * granular, chip)
    rough = lerp(rough, 0.45, chip * chip_core)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.2, 1.0), metallic=np.clip(metal, 0, 1))


def mat_corrugated_metal(N=1024):
    S = Seeds(505)
    x = (np.arange(N, dtype=F32) + 0.5) / N
    period = 8                                      # corrugations per tile
    prof = np.sin(2 * np.pi * period * x)
    prof = np.sign(prof) * np.abs(prof) ** 0.85     # slightly flatter crests
    amp = 20.0                                      # texels
    valley = sstep(0.2, -0.9, prof)[None, :].repeat(N, 0)
    crest = sstep(0.3, 0.95, prof)[None, :].repeat(N, 0)

    # Zinc spangle: crystal grains with individual brightness.
    f1, f2, ids = worley(N, 46, S(), jitter=0.95)
    sp = cell_rand(ids, S())
    sp2 = cell_rand(ids, S())
    spangle_edge = sstep(0.06, 0.0, f2 - f1)
    fine = spectral(N, S(), beta=0.7, fmin=40)
    speck = zscore(blur(white(N, S()), 0.7))

    zinc = rgb(148, 150, 152) * (1 + 0.07 * (sp - 0.5) + 0.02 * fine + 0.015 * speck)[..., None]
    patina = sstep(0.0, 0.6, warped_fbm(N, 6, 6, S(), amount=25) + 0.3 * fbm(N, 32, 3, S()))
    white_rust = sstep(1.3, 1.9, warped_fbm(N, 8, 6, S(), amount=15) + 0.4 * fbm(N, 48, 2, S()))
    a = lerp(zinc, rgb(118, 120, 119) * (1 + 0.04 * fine + 0.03 * speck)[..., None], patina * 0.75)
    a = lerp(a, rgb(170, 170, 165), white_rust * 0.55)
    a = lerp(a, a * 0.92, spangle_edge * 0.4 * (1 - patina))

    # Red rust: ragged patches favouring valleys, plus thin runs streaking down.
    rust_f = warped_fbm(N, 5, 7, S(), amount=30) + 0.3 * fbm(N, 48, 3, S())
    rust_patch = sstep(1.35, 1.6, rust_f + 0.7 * valley - 0.3 * crest)
    _, pus, _ = scatter_discs(N, 60, S(), prob=0.3, rmin=1.0, rmax=3.5, power=2)
    rust_patch = np.maximum(rust_patch, pus * sstep(0.3, 1.2, rust_f))
    src = np.clip(rust_patch * 0.8 + 0.5 * valley * sstep(1.0, 1.8, fbm(N, 6, 4, S())), 0, 1)
    runs = streaks(N, S(), 140, length=260, width=2.0, src_mask=src)
    runs2 = norm01(periodic_convolve(rust_patch, drip_kernel(N, 160, 1.5)))
    runs = np.clip(0.6 * runs + 1.2 * runs2, 0, 1) * (0.55 + 0.45 * valley)
    runs = sstep(0.12, 0.9, runs)
    rcol, rh, granular = rust_layer(N, S, scale=1.2)
    run_col = lerp(rgb(126, 92, 66), rgb(104, 58, 32), sstep(0.3, 0.9, runs))
    a = lerp(a, run_col, runs * 0.7)
    a = lerp(a, rcol, rust_patch)
    grime = sstep(0.3, 2.0, fbm(N, 4, 5, S())) * (0.6 + 0.4 * norm01(speck))
    a = lerp(a, a * 0.7, grime * 0.4)

    hp = (prof[None, :] * amp).repeat(N, 0)
    h = hp + 0.15 * fine - 0.15 * spangle_edge + rust_patch * (0.6 + 0.5 * rh) + 0.25 * runs
    a *= (0.9 + 0.1 * sstep(-1.0, 0.6, prof))[None, :, None]   # mild valley occlusion

    rust_any = np.clip(rust_patch + 0.6 * runs, 0, 1)
    metal = lerp(0.85 - 0.4 * patina - 0.6 * white_rust, 0.05, rust_any)
    rough = lerp(0.32 + 0.12 * (sp2 - 0.5) + 0.25 * patina + 0.35 * white_rust,
                 0.85 + 0.05 * granular, rust_any)
    rough = lerp(rough, rough + 0.15, grime * 0.5)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.2, 1.0), metallic=np.clip(metal, 0, 1))


def mat_steel_grate(N=512):
    S = Seeds(606)
    cells = 8
    pitch = N / cells
    c = np.arange(N, dtype=F32) + 0.5
    # distance (texels) from nearest bar centre-line
    dxb = np.abs(((c + pitch / 2) % pitch) - pitch / 2)[None, :].repeat(N, 0)   # bearing bars (vertical)
    dyb = np.abs(((c + pitch / 2) % pitch) - pitch / 2)[:, None].repeat(N, 1)   # cross bars (horizontal)
    bw, cw = 6.0, 4.0                                                            # half widths
    jit = 0.6 * fbm(N, 16, 3, S())
    bear = sstep(bw + 0.7, bw - 0.7, dxb + jit)
    cross = sstep(cw + 0.7, cw - 0.7, dyb + jit)
    alpha = np.maximum(bear, cross)

    # Heights: rounded bar tops, cross bars sit slightly lower; serrated bearing tops.
    bear_h = 6.0 * np.sqrt(np.clip(1 - (dxb / (bw + 0.5)) ** 2, 0, 1)) ** 0.5
    cross_h = 4.5 * np.sqrt(np.clip(1 - (dyb / (cw + 0.5)) ** 2, 0, 1)) ** 0.5
    serr = 0.6 * (0.5 + 0.5 * np.cos(2 * np.pi * c / (pitch / 8)))[:, None].repeat(N, 1)
    fine = spectral(N, S(), beta=0.7, fmin=30)
    h = np.maximum(bear_h * bear + serr * bear * sstep(bw * 0.6, 0, dxb), cross_h * cross)
    h = h + 0.15 * fine

    # Wear: tops of bars polished by boots, edges bright.
    top = sstep(bw * 0.8, 0.0, dxb) * bear
    wear = sstep(-0.3, 1.0, fbm(N, 6, 4, S())) * top
    # Rust near intersections (radial falloff) and grime.
    inter = np.exp(-(dxb ** 2 + dyb ** 2) / (2 * 9.0 ** 2))
    rust_n = fbm(N, 24, 4, S())
    rust = sstep(0.25, 0.75, inter + 0.25 * rust_n + 0.15 * fbm(N, 4, 3, S())) * alpha
    rust = np.maximum(rust, sstep(1.2, 1.9, warped_fbm(N, 8, 5, S(), amount=6)) * alpha)
    rcol, rh, granular = rust_layer(N, S, scale=0.6)

    steel = rgb(78, 79, 82) * (1 + 0.08 * fine + 0.06 * fbm(N, 12, 4, S()))[..., None]
    a = lerp(steel, rgb(150, 150, 152), wear * 0.75)
    a = lerp(a, rcol, rust * 0.95)
    # Side faces of bars darker (grime collects), mild.
    side = sstep(0.0, 1.0, 1 - np.maximum(top, sstep(cw * 0.7, 0, dyb) * cross))
    a = lerp(a, a * 0.7, side * 0.5)
    h = h + rust * (0.3 + 0.4 * rh)
    a = finish_albedo(a)
    rgba = np.concatenate([a, alpha[..., None]], axis=-1)

    metal = (0.85 + 0.1 * wear) * (1 - rust)
    rough = lerp(0.55 - 0.25 * wear + 0.05 * fine, 0.88, rust)
    return dict(albedo=rgba, height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.2, 1.0), metallic=np.clip(metal, 0, 1))


# ---------------------------------------------------------------- wood -------
def wood_grain_field(N, S, rings=40, warp_amt=18.0, fiber_aniso=14.0):
    """Long grain along +x: ring lines (meandering) plus fibres. Returns
    (ring 0..1 latewood mask, fibre noise, figure noise)."""
    y = (np.arange(N, dtype=F32) + 0.5)[:, None]
    w1 = fbm(N, (2, 6), 5, S()) * warp_amt
    w2 = fbm(N, (4, 24), 3, S()) * warp_amt * 0.15
    ph = 2 * np.pi * rings * (y + w1 + w2) / N
    ring = 0.5 + 0.5 * np.sin(ph)
    ring = ring ** 3.0                      # thin dark latewood bands
    fibre = spectral(N, S(), beta=0.6, fmin=8, aniso=(fiber_aniso, 1.0))
    figure = fbm(N, (3, 10), 4, S())
    return ring.astype(F32), fibre, figure


def mat_wood_planks(N=1024):
    S = Seeds(707)
    rows = 5
    joists = 4                               # joist spacing N/4: joints & nails sit on joists
    ring, fibre, figure = wood_grain_field(N, S, rings=60, warp_amt=12)
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + 0.5
    edges = np.round(np.arange(rows + 1) * N / rows).astype(int)
    rng = np.random.default_rng(S())
    row_of = np.zeros((N, N), np.int64)
    v_local = np.zeros((N, N), F32)
    pw = np.zeros((N, N), F32)
    for r in range(rows):
        row_of[edges[r]:edges[r + 1]] = r
        v_local[edges[r]:edges[r + 1]] = yy[edges[r]:edges[r + 1]] - edges[r]
        pw[edges[r]:edges[r + 1]] = edges[r + 1] - edges[r]
    # Staggered end joints on joist lines (1-2 per row, never the same as the row above).
    joint_x = []
    prev = set()
    for r in range(rows):
        choices = [j for j in range(joists) if j not in prev]
        k = rng.choice([1, 2], p=[0.7, 0.3])
        js = sorted(rng.choice(choices, size=min(k, len(choices)), replace=False).tolist())
        prev = set(js)
        joint_x.append([(j + 0.5) * N / joists + rng.uniform(-6, 6) for j in js])
    seg_id = np.zeros((N, N), np.int64)
    du = np.full((N, N), 1e4, F32)          # distance to nearest end joint along u
    for r in range(rows):
        sl = slice(edges[r], edges[r + 1])
        xs = np.array(joint_x[r], F32)
        X = xx[sl]
        # segment index = number of joints to the left (mod count, wrap merges last & first)
        cnt = (X[..., None] > xs[None, None, :]).sum(-1)
        cnt = np.where(cnt == len(xs), 0, cnt)
        seg_id[sl] = r * 8 + cnt
        d = np.abs(((X[..., None] - xs[None, None, :]) + N / 2) % N - N / 2).min(-1)
        du[sl] = d
    nseg = rows * 8
    seg_dx = rng.uniform(0, N, nseg).astype(F32)
    seg_dy = rng.uniform(0, N, nseg).astype(F32)
    seg_tone = rng.uniform(-1, 1, nseg).astype(F32)
    seg_grey = rng.uniform(0, 1, nseg).astype(F32)
    off_x, off_y = seg_dx[seg_id], seg_dy[seg_id]
    # Knots: elliptical (stretched along the grain); grain lines bend around them.
    knot = np.zeros((N, N), F32)
    knot_ring = np.zeros((N, N), F32)
    bend = np.zeros((N, N), F32)
    for _ in range(5):
        kx, ky = rng.uniform(0, N), rng.uniform(0, N)
        rx, ry = rng.uniform(9, 18), rng.uniform(5, 9)
        dx = (xx - kx + N / 2) % N - N / 2
        dy = (yy - ky + N / 2) % N - N / 2
        d = np.sqrt((dx / rx) ** 2 + (dy / ry) ** 2)
        knot = np.maximum(knot, sstep(1.0, 0.75, d))
        knot_ring = np.maximum(knot_ring, (0.5 + 0.5 * np.cos(d * 9.0)) * sstep(1.4, 0.8, d))
        bend += np.sign(dy) * 14.0 * np.exp(-0.5 * ((dx / (rx * 3.5)) ** 2 + (dy / (ry * 2.5)) ** 2))
    off_y = off_y - bend
    ring_s = warp(ring, off_x, off_y)
    fibre_s = warp(fibre, off_x, off_y)
    figure_s = warp(figure, off_x, off_y)
    tone = seg_tone[seg_id]
    greyness = seg_grey[seg_id]

    # Gaps between boards and at end joints.
    gap_v = np.minimum(v_local, pw - v_local)
    gap = np.maximum(sstep(2.2, 0.8, gap_v), sstep(2.0, 0.6, du))
    edge_near = np.maximum(sstep(14, 0, gap_v), sstep(14, 0, du))
    # Cupping across each board + slight bevel at the edges.
    cup = 1.5 * ((v_local / pw - 0.5) * 2) ** 2
    bevel = sstep(0.0, 5.0, np.minimum(gap_v, du))
    # Checks (drying cracks) along the grain.
    ck_f = warp(fbm(N, (1, 24), 3, S(), gain=0.35), off_x, off_y)
    checks = zero_lines(ck_f, 0.6) * sstep(0.9, 1.6, warp(fbm(N, (3, 6), 3, S()), off_x, off_y))
    # Nail holes: two per board per joist.
    nails = np.zeros((N, N), F32)
    stain = np.zeros((N, N), F32)
    for r in range(rows):
        for j in range(joists):
            jx = (j + 0.5) * N / joists
            for fv in (0.25, 0.75):
                for side in ((-14, 14) if any(abs(jx - x) < 20 for x in joint_x[r]) else (0,)):
                    cx = (jx + side + rng.uniform(-3, 3)) % N
                    cy = edges[r] + fv * (edges[r + 1] - edges[r]) + rng.uniform(-4, 4)
                    dx = (xx - cx + N / 2) % N - N / 2
                    dy = (yy - cy + N / 2) % N - N / 2
                    d2 = dx * dx + dy * dy
                    rad = rng.uniform(2.0, 3.0)
                    nails = np.maximum(nails, sstep(rad + 0.7, rad - 0.7, np.sqrt(d2)))
                    stain = np.maximum(stain, np.exp(-d2 / (2 * rng.uniform(6, 10) ** 2)))
    weather = sstep(-1.2, 1.2, warp(fbm(N, (3, 10), 5, S()), off_x, off_y))

    h = (cup * -1 + 1.0 * (1 - ring_s) * 0.8 + 0.35 * fibre_s + 0.3 * figure_s
         - 1.4 * checks - 2.5 * nails - 4.0 * gap + 0.6 * knot - 0.4 * knot_ring)
    h = h * bevel + (1 - bevel) * (h - 1.5)

    brown = rgb(112, 86, 62)
    silver = rgb(140, 133, 122)
    g = np.clip(0.35 + 0.5 * greyness + 0.25 * weather, 0, 1)
    a = lerp(brown * (1 + 0.1 * tone)[..., None], silver * (1 + 0.06 * tone)[..., None], g)
    a = a * (1 + 0.06 * figure_s + 0.05 * fibre_s)[..., None]
    a = lerp(a, a * rgb(165, 145, 125) / 0.7, ring_s * 0.75)        # darker, browner latewood
    a = lerp(a, a * 0.75, edge_near * 0.35)                           # dirt along board edges
    knot_col = rgb(74, 56, 42)
    a = lerp(a, knot_col, np.clip(knot * 0.85 + knot_ring * 0.35, 0, 1))
    a = lerp(a, a * 0.5, checks * 0.85)
    a = lerp(a, a * rgb(170, 120, 95) / 0.7, stain * 0.5)            # rust bleed around nails
    a = lerp(a, rgb(36, 30, 26), nails * 0.9)
    a = lerp(a, rgb(34, 30, 27), gap)
    a *= (1.0 + 0.06 * np.clip(cavity(h, 2.0), -1, 1))[..., None]
    rough = 0.8 + 0.06 * ring_s + 0.04 * fibre_s + 0.08 * g - 0.05 * (1 - g)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.5, 1.0))


# ---------------------------------------------------------------- masonry ----
def _running_bond(N, cols, rows, offset_jitter=0.0, coord_warp=None, rng=None):
    """Brick-style running bond layout. Returns (row, col, id, lx, ly, bw, bh)."""
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + 0.5
    if coord_warp is not None:
        xx = xx + coord_warp[0]
        yy = yy + coord_warp[1]
    bh = N / rows
    bw = N / cols
    r = np.floor(yy / bh).astype(np.int64)
    rr = r % rows
    shifts = (rr % 2) * (bw / 2)
    if offset_jitter:
        sj = rng.uniform(-offset_jitter, offset_jitter, rows).astype(F32)
        shifts = shifts + sj[rr]
    u = xx + shifts
    c = np.floor(u / bw).astype(np.int64) % cols
    lx = (u % bw)
    ly = yy - r * bh
    ids = rr * cols + c
    return rr, c, ids, lx.astype(F32), ly.astype(F32), bw, bh


def mat_brick(N=1024):
    S = Seeds(808)
    rng = np.random.default_rng(S())
    cols, rows = 4, 12
    cw = (fbm(N, 16, 4, S()) * 1.2, fbm(N, 16, 4, S()) * 1.2)
    rr, cc, ids, lx, ly, bw, bh = _running_bond(N, cols, rows, coord_warp=cw)
    nb = rows * cols
    m = 5.0 + rng.uniform(-0.8, 1.2, (nb, 4)).astype(F32)       # mortar half-widths per side
    dl, dr = lx - m[ids, 0], (bw - lx) - m[ids, 1]
    dt, db = ly - m[ids, 2], (bh - ly) - m[ids, 3]
    dist = np.minimum(np.minimum(dl, dr), np.minimum(dt, db))   # >0 inside brick
    # Rough brick edges.
    dist = dist + 1.6 * fbm(N, 48, 4, S())
    brick = sstep(-0.6, 0.6, dist)
    face = sstep(0.0, 4.5, dist)

    # Broken bricks: a corner knocked off / face spalled.
    broken = (np.random.default_rng(S()).random(nb) < 0.12)[ids]
    corner_x = np.random.default_rng(S()).integers(0, 2, nb)[ids]
    corner_y = np.random.default_rng(S()).integers(0, 2, nb)[ids]
    cut_size = np.random.default_rng(S()).uniform(0.6, 1.2, nb).astype(F32)[ids]
    ux = np.where(corner_x == 0, lx / bw, 1 - lx / bw)
    uy = np.where(corner_y == 0, ly / bh, 1 - ly / bh)
    cut = (ux * 2.6 + uy) + 0.12 * fbm(N, 32, 4, S())
    chip = sstep(0.55 * cut_size, 0.45 * cut_size, cut) * broken * brick
    spall_f = fbm(N, 20, 5, S()) + 2.2 * (np.random.default_rng(S()).random(nb) < 0.1)[ids]
    spall = sstep(1.9, 2.1, spall_f) * brick * sstep(1.0, 4.0, dist)
    dmg = np.clip(chip + spall, 0, 1)
    crack_b = zero_lines(fbm(N, 6, 6, S()), 0.8) * (np.random.default_rng(S()).random(nb) < 0.15)[ids] * face

    # Brick colours: per-brick base, internal mottling, speckles.
    pal = np.array([rgb(118, 62, 48), rgb(102, 54, 42), rgb(128, 72, 54), rgb(86, 48, 38),
                    rgb(110, 70, 56), rgb(72, 44, 38), rgb(134, 82, 62), rgb(98, 66, 54)], F32)
    pick = np.random.default_rng(S()).integers(0, len(pal), nb)
    bcol = pal[pick][ids]
    bvar = np.random.default_rng(S()).uniform(0.88, 1.1, nb).astype(F32)[ids]
    mott = fbm(N, 24, 5, S())
    fine = spectral(N, S(), beta=0.6, fmin=50)
    a_b = bcol * (bvar * (1 + 0.07 * mott + 0.05 * fine))[..., None]
    # Flashed (darker) ends on some bricks.
    flash = (np.random.default_rng(S()).random(nb) < 0.3)[ids] * sstep(0.35, 0.0, np.minimum(lx, bw - lx) / bw)
    a_b = lerp(a_b, a_b * 0.65, flash * 0.6)
    sd, sm, _ = scatter_discs(N, 160, S(), prob=0.25, rmin=0.5, rmax=1.6)
    a_b = lerp(a_b, a_b * 0.5, sm * 0.6)
    sd2, sm2, _ = scatter_discs(N, 140, S(), prob=0.2, rmin=0.5, rmax=1.4)
    a_b = lerp(a_b, a_b * 1.35, sm2 * 0.5)
    inner = rgb(150, 78, 52) * (1 + 0.08 * fine)[..., None]
    a_b = lerp(a_b, inner, dmg * 0.85)

    mort_n = zscore(blur(white(N, S()), 0.8))
    a_m = rgb(118, 112, 102) * (1 + 0.06 * mort_n + 0.05 * mott)[..., None]
    a = lerp(a_m, a_b, brick)

    # Soot: blotchy, heavier in some areas, rising streaks.
    soot = sstep(-0.3, 1.6, warped_fbm(N, 3, 7, S(), amount=50))
    soot_up = periodic_convolve(sstep(0.8, 1.8, fbm(N, 6, 4, S())), drip_kernel(N, 160, 6, down=False))
    soot = np.clip(soot + 0.8 * norm01(soot_up), 0, 1)
    a = lerp(a, a * rgb(64, 62, 62) / 0.42, soot * 0.7)
    efflo = sstep(1.0, 1.8, warped_fbm(N, 6, 6, S(), amount=20)) * (1 - soot)
    efflo *= 0.5 + 0.5 * norm01(zscore(blur(white(N, S()), 1.0)))
    a = lerp(a, rgb(170, 165, 156), efflo * 0.3 * (0.4 + 0.6 * (1 - face)))
    a = lerp(a, a * 0.5, crack_b * 0.8)

    hb = 5.0 + 3.0 * np.sqrt(face) + 0.35 * mott + 0.25 * fine
    hb = hb - 3.5 * dmg * (0.7 + 0.3 * fine) - 1.2 * crack_b
    hm = 1.0 + 0.3 * mort_n
    h = lerp(hm, hb, brick)
    a *= (1.0 + 0.08 * np.clip(cavity(h, 3.0) / 2, -1, 1))[..., None]

    rough = lerp(0.95 + 0.03 * mort_n, 0.86 + 0.04 * mott + 0.04 * dmg, brick) - 0.04 * soot
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.5, 1.0))


def mat_tiles_dirty(N=1024):
    S = Seeds(909)
    n_t = 10
    p = N / n_t
    rng = np.random.default_rng(S())
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + 0.5
    jx = fbm(N, 20, 3, S()) * 0.4
    tx = np.floor(xx / p).astype(np.int64) % n_t
    ty = np.floor(yy / p).astype(np.int64) % n_t
    tid = ty * n_t + tx
    lx = xx % p
    ly = yy % p
    g = 2.6
    d = np.minimum(np.minimum(lx, p - lx), np.minimum(ly, p - ly)) - g + jx
    tile = sstep(-0.5, 0.5, d)
    cushion = sstep(0.0, 6.0, d)
    nt = n_t * n_t
    missing = (rng.random(nt) < 0.035)[tid]
    cracked = (rng.random(nt) < 0.12)[tid]
    tile_tone = rng.uniform(-1, 1, nt).astype(F32)[tid]
    yellow = rng.uniform(0, 1, nt).astype(F32)[tid]
    crazed = (rng.random(nt) < 0.2)[tid]

    # Tile cracks: jagged near-straight lines from edge to edge of a cracked tile.
    cimg = Image.new("L", (N * 2, N * 2), 0)
    cd = ImageDraw.Draw(cimg)
    crk_tiles = np.flatnonzero(rng.random(nt) < 0.12)
    for t in crk_tiles:
        x0, y0 = (t % n_t) * p, (t // n_t) * p
        for _ in range(rng.integers(1, 3)):
            e1, e2 = rng.choice(4, 2, replace=False)
            def edge_pt(e):
                u = rng.uniform(0.15, 0.85) * p
                return [(x0 + u, y0), (x0 + p, y0 + u), (x0 + u, y0 + p), (x0, y0 + u)][e]
            (ax, ay), (bx, by) = edge_pt(e1), edge_pt(e2)
            pts = []
            for k in range(7):
                t_ = k / 6
                jx_ = rng.normal(0, 2.0) if 0 < k < 6 else 0
                jy_ = rng.normal(0, 2.0) if 0 < k < 6 else 0
                pts.append(((ax + (bx - ax) * t_ + jx_) * 2, (ay + (by - ay) * t_ + jy_) * 2))
            cd.line(pts, fill=255, width=2)
    crack = (np.asarray(cimg.resize((N, N), Image.BOX), F32) / 255.0) * tile
    # Fine glaze crazing.
    f1, f2, _ = worley(N, 90, S())
    craze = sstep(0.04, 0.0, f2 - f1) * crazed * tile * sstep(-0.5, 0.8, fbm(N, 8, 3, S()))
    # Corner chips.
    corner_d = np.minimum(np.hypot(np.minimum(lx, p - lx), np.minimum(ly, p - ly)), 99)
    chip_r = rng.uniform(0, 1, nt).astype(F32)[tid]
    chips = sstep(9.0, 7.0, corner_d + 3 * fbm(N, 40, 3, S())) * (chip_r < 0.25) * tile

    grime = sstep(-0.5, 1.8, warped_fbm(N, 3, 7, S(), amount=40))
    grout_blur = blur(1 - tile, 5)
    edge_dirt = np.clip(grout_blur * 2.0, 0, 1) * tile
    streak = blur(streaks(N, S(), 90, length=200, width=4.0), 1.5) * sstep(0.0, 1.2, fbm(N, 3, 3, S()))
    fine = spectral(N, S(), beta=0.7, fmin=40)

    glaze = rgb(222, 222, 214) * (1 + 0.02 * tile_tone)[..., None]
    glaze = lerp(glaze, rgb(216, 212, 194), yellow * 0.4)
    a = glaze * (1 + 0.01 * fine)[..., None]
    gspeck = norm01(zscore(blur(white(N, S()), 1.2)))
    a = lerp(a, a * rgb(146, 140, 128) / 0.6, np.clip(grime * (0.35 + 0.3 * gspeck) + edge_dirt * 0.55, 0, 1))
    a = lerp(a, rgb(128, 120, 106), streak * 0.4)
    a = lerp(a, rgb(80, 72, 60), craze * 0.5)
    a = lerp(a, rgb(70, 62, 52), crack * 0.85)
    a = lerp(a, rgb(170, 165, 155) * (1 + 0.08 * fine)[..., None], chips)          # exposed biscuit
    grout_n = zscore(blur(white(N, S()), 0.7))
    grout = rgb(98, 92, 82) * (1 + 0.08 * grout_n + 0.1 * fbm(N, 16, 3, S()))[..., None]
    mildew = sstep(0.4, 1.6, fbm(N, 12, 4, S()))
    grout = lerp(grout, grout * 0.55, np.clip(grime * 0.7 + mildew * 0.5, 0, 1))
    a = lerp(grout, a, tile)
    # Missing tiles: grey adhesive with notched-trowel ridges.
    trowel = 0.5 + 0.5 * np.sin(2 * np.pi * (xx + yy * 0.15 + 6 * fbm(N, 6, 3, S())) / 9.0)
    adh = rgb(120, 118, 112) * (1 + 0.1 * grout_n + 0.12 * (trowel - 0.5))[..., None]
    mt = missing * sstep(-2.0, 0.0, d + 3)
    a = lerp(a, adh, mt)

    h = (tile * (2.5 + 1.5 * cushion) + 0.05 * fine - 1.2 * crack - 0.4 * craze
         - 1.6 * chips + (1 - tile) * 0.3 * grout_n)
    h = lerp(h, 0.2 + 0.6 * trowel + 0.2 * grout_n, mt)
    a *= (1.0 + 0.06 * np.clip(cavity(h, 3.0), -1, 1))[..., None]

    rough = lerp(0.92 + 0.04 * grout_n, 0.12 + 0.35 * grime + 0.25 * edge_dirt + 0.15 * streak, tile)
    rough = lerp(rough, 0.85, chips)
    rough = lerp(rough, 0.95, mt)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.05, 1.0))


# ---------------------------------------------------------------- weapons ----
def wear_mask(N, seed, freq=8, thresh=1.2, soft=0.7, breakup=0.6):
    """Small, broken-up wear/dirt spots (avoids big camo-like blobs)."""
    v = fbm(N, freq, 6, seed) + breakup * fbm(N, freq * 8, 3, seed + 5)
    return sstep(thresh, thresh + soft, v)


def mat_gun_metal(N=512):
    S = Seeds(1010)
    grain = zscore(blur(white(N, S()), 0.6))
    grain2 = zscore(blur(white(N, S()), 1.5))
    mott = fbm(N, 6, 5, S())
    wear = wear_mask(N, S(), freq=8, thresh=1.5, soft=0.9, breakup=0.7)
    scr = strokes(N, 260, S(), length=(6, 40), width=(0.5, 1.0), curve=0.04, intensity=(0.2, 0.8), ss=3)
    base = rgb(56, 57, 60) * (1 + 0.025 * mott + 0.07 * grain + 0.03 * grain2)[..., None]
    a = lerp(base, rgb(116, 117, 120), wear * 0.38)
    a = lerp(a, rgb(118, 119, 122), scr * 0.5)
    h = 0.3 * grain + 0.2 * grain2 - 0.3 * scr
    metal = 0.88 + 0.07 * wear
    rough = 0.5 + 0.04 * grain2 + 0.02 * mott - 0.12 * wear - 0.12 * scr
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.35, 0.55), metallic=np.clip(metal, 0, 1))


def mat_gun_polymer(N=512):
    S = Seeds(1111)
    f1, f2, ids = worley(N, 110, S(), jitter=0.95)
    bump = (1 - np.clip(f1 / 0.75, 0, 1)) ** 1.5 * (0.6 + 0.4 * cell_rand(ids, S()))
    micro = zscore(blur(white(N, S()), 0.5))
    mott = fbm(N, 5, 5, S())
    wear = wear_mask(N, S(), freq=8, thresh=1.4, soft=0.9)
    scuff = blur(strokes(N, 120, S(), length=(8, 40), width=(0.8, 2.0), intensity=(0.2, 0.6)), 0.6)
    h = 1.6 * bump * (1 - 0.5 * wear) + 0.1 * micro - 0.3 * scuff
    a = rgb(44, 44, 46) * (1 + 0.02 * mott + 0.04 * micro + 0.1 * (bump - 0.4))[..., None]
    a = lerp(a, rgb(60, 60, 62), wear * 0.5)
    a = lerp(a, rgb(74, 74, 76), scuff * 0.45)
    rough = 0.7 + 0.03 * micro + 0.02 * mott - 0.08 * wear - 0.05 * scuff - 0.04 * (bump - 0.4)
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.58, 0.76))


def mat_gun_wood(N=512):
    S = Seeds(1212)
    yy = (np.arange(N, dtype=F32) + 0.5)[:, None]
    # Laminate: veneer layers along x with dark glue lines, plus wood grain.
    lam_w = fbm(N, (2, 4), 4, S()) * 6.0
    layers = 24
    lph = (yy + lam_w) * layers / N
    glue = sstep(0.06, 0.0, np.abs((lph % 1.0) - 0.5) - 0.44)
    ring, fibre, figure = wood_grain_field(N, S, rings=70, warp_amt=8, fiber_aniso=16)
    lay_id = np.floor(lph).astype(np.int64) % layers
    lay_tone = np.random.default_rng(S()).uniform(-1, 1, layers).astype(F32)[lay_id]
    dd, dm, _ = scatter_discs(N, 16, S(), prob=0.18, rmin=1.0, rmax=3.0, power=2)
    dd, dm = blur(dd, 0.7), blur(dm, 0.7)
    scr = strokes(N, 90, S(), length=(6, 40), width=(0.5, 1.2), intensity=(0.2, 0.7), ss=3)
    worn = wear_mask(N, S(), freq=6, thresh=1.2, soft=1.0)
    base = rgb(92, 47, 30)
    a = base * (1 + 0.08 * lay_tone + 0.04 * figure + 0.04 * fibre)[..., None]
    a = lerp(a, a * rgb(150, 115, 100) / 0.65, ring * 0.5)
    a = lerp(a, a * 0.72, glue * 0.6)
    a = lerp(a, a * 1.2 * rgb(255, 230, 205) / 1.0, worn * 0.4)
    a = lerp(a, a * 0.7, dm * 0.5)
    a = lerp(a, a * 1.3, scr * 0.45)
    h = 0.25 * fibre + 0.15 * (1 - ring) - 1.5 * dd - 0.4 * scr + 0.15 * figure
    rough = 0.4 + 0.03 * fibre + 0.04 * ring + 0.06 * worn + 0.06 * dm + 0.08 * scr
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.35, 0.5))


# ---------------------------------------------------------------- textiles ---
def weave(N, threads, pattern, S, jitter=0.12, slub=0.25):
    """Generic woven cloth. pattern(i, j) -> 1 where the warp (vertical thread)
    is on top at crossing (i warp index, j weft index). Returns
    (height, warp_mask, thread_tone)."""
    T = threads
    c = (np.arange(N, dtype=F32) + 0.5) * T / N
    # Thread wobble (keeps periodic since noise is periodic).
    wobx = fbm(N, (T // 4, 4), 3, S()) * jitter
    woby = fbm(N, (4, T // 4), 3, S()) * jitter
    X = c[None, :] + wobx
    Y = c[:, None] + woby
    i = np.floor(X).astype(np.int64)
    j = np.floor(Y).astype(np.int64)
    fx = X - i
    fy = Y - j
    W = np.array([[pattern(ii, jj) for ii in range(T)] for jj in range(T)], F32)  # [j, i]
    # Lift of warp thread i along y: interpolate W between crossing centres.
    t = Y - 0.5
    j0 = np.floor(t).astype(np.int64)
    s = _fade(t - j0)
    lw = W[j0 % T, i % T] * (1 - s) + W[(j0 + 1) % T, i % T] * s
    t2 = X - 0.5
    i0 = np.floor(t2).astype(np.int64)
    s2 = _fade(t2 - i0)
    lf = (1 - W[j % T, i0 % T]) * (1 - s2) + (1 - W[j % T, (i0 + 1) % T]) * s2
    cw = np.sqrt(np.clip(1 - ((fx - 0.5) / 0.48) ** 2, 0, 1))
    cf = np.sqrt(np.clip(1 - ((fy - 0.5) / 0.48) ** 2, 0, 1))
    # Slubs: thickness variation along each thread.
    sl_w = 1 + slub * fbm(N, (T, 8), 2, S()) * 0.5
    sl_f = 1 + slub * fbm(N, (8, T), 2, S()) * 0.5
    hw = cw * (0.45 + 0.55 * lw) * sl_w
    hf = cf * (0.45 + 0.55 * lf) * sl_f
    warp_top = sstep(-0.05, 0.05, hw - hf)
    h = np.maximum(hw, hf)
    # Fibre streaks along each thread direction.
    fib_w = spectral(N, S(), beta=0.5, fmin=10, aniso=(1.0, 12.0))
    fib_f = spectral(N, S(), beta=0.5, fmin=10, aniso=(12.0, 1.0))
    fib = lerp(fib_f, fib_w, warp_top)
    tone_w = np.random.default_rng(S()).uniform(-1, 1, T).astype(F32)[i % T]
    tone_f = np.random.default_rng(S()).uniform(-1, 1, T).astype(F32)[j % T]
    tone = lerp(tone_f, tone_w, warp_top)
    return h.astype(F32), warp_top, tone, fib


def mat_fabric_canvas(N=512):
    S = Seeds(1313)
    h, wt, tone, fib = weave(N, 96, lambda i, j: float((i + j) % 2 == 0), S)
    wear = wear_mask(N, S(), freq=6, thresh=1.0, soft=1.0, breakup=0.8)
    dirt = wear_mask(N, S(), freq=4, thresh=0.3, soft=1.6, breakup=0.8)
    spots_d, spots, _ = scatter_discs(N, 14, S(), prob=0.25, rmin=2, rmax=8, power=1.5)
    spots = blur(spots, 2.0) * (0.5 + 0.5 * norm01(fbm(N, 32, 2, S())))
    col_w, col_f = rgb(108, 102, 72), rgb(98, 94, 66)
    a = lerp(col_f, col_w, wt) * (1 + 0.06 * tone + 0.07 * fib)[..., None]
    a *= (0.78 + 0.22 * np.clip(h, 0, 1.2))[..., None]   # valleys between threads read darker
    fuzz_h = np.clip(h, 0, 1.2)
    a = lerp(a, rgb(132, 126, 100), wear * fuzz_h * 0.35)
    a = lerp(a, a * rgb(150, 132, 108) / 0.68, dirt * 0.35)
    a = lerp(a, a * 0.75, spots * 0.4)
    hh = 1.6 * h + 0.15 * fib - 0.4 * wear * h
    rough = 0.88 + 0.04 * fib - 0.04 * dirt
    return dict(albedo=finish_albedo(a), height=hh, normal=height_to_normal(hh, 1.0),
                roughness=np.clip(rough, 0.7, 1.0))


def mat_fabric_dark(N=512):
    S = Seeds(1414)
    h, wt, tone, fib = weave(N, 128, lambda i, j: float((i - j) % 3 != 0), S, jitter=0.1, slub=0.2)
    wear = wear_mask(N, S(), freq=6, thresh=1.1, soft=1.0, breakup=0.8)
    fuzz = blur(strokes(N, 700, S(), length=(3, 10), width=(0.4, 0.8), curve=0.6,
                        intensity=(0.2, 0.6), ss=3), 0.4)
    dust = wear_mask(N, S(), freq=4, thresh=0.6, soft=1.6, breakup=0.8)
    a = lerp(rgb(44, 44, 46), rgb(52, 52, 55), wt) * (1 + 0.07 * tone + 0.07 * fib)[..., None]
    a *= (0.8 + 0.2 * np.clip(h, 0, 1.2))[..., None]
    a = lerp(a, rgb(72, 70, 70), wear * np.clip(h, 0, 1) * 0.5)
    a = lerp(a, rgb(88, 86, 84), fuzz * 0.3)
    a = lerp(a, rgb(88, 84, 78), dust * 0.2)
    hh = 1.2 * h + 0.1 * fib - 0.3 * wear * h + 0.2 * fuzz
    rough = 0.86 + 0.04 * fib - 0.06 * wear
    return dict(albedo=finish_albedo(a), height=hh, normal=height_to_normal(hh, 1.0),
                roughness=np.clip(rough, 0.65, 1.0))


def mat_leather(N=512):
    S = Seeds(1515)
    f1, f2, ids = worley(N, 72, S(), jitter=0.95)
    pebble = sstep(0.0, 0.22, f2 - f1) * (0.7 + 0.3 * cell_rand(ids, S()))
    pebble = pebble * (1 - 0.3 * f1)
    mott = fbm(N, 6, 5, S())
    fine = spectral(N, S(), beta=0.7, fmin=30)
    # Creases: families of roughly parallel wrinkles (zero sets of strongly
    # anisotropic noise), each family confined to its own region.
    cr = np.zeros((N, N), F32)
    for fr in [(3, 22), (22, 3), (4, 16), (16, 4)]:
        fld = fbm(N, fr, 4, S(), gain=0.45)
        region = sstep(0.4, 1.1, fbm(N, 3, 3, S()))
        cr = np.maximum(cr, zero_lines(fld, 1.0) * region * (0.5 + 0.5 * norm01(fbm(N, 24, 2, S()))))
    cr_wide = blur(cr, 2.0)
    wear = wear_mask(N, S(), freq=5, thresh=0.9, soft=1.2, breakup=0.7)
    scuff = blur(strokes(N, 80, S(), length=(6, 30), width=(1, 3), intensity=(0.3, 0.8)), 0.8)
    h = (1.1 * pebble * (1 - 0.5 * wear) + 0.2 * fine - 1.2 * cr - 1.0 * cr_wide + 0.3 * mott
         - 0.3 * scuff)
    a = rgb(68, 44, 30) * (1 + 0.04 * mott + 0.04 * fine + 0.1 * (pebble - 0.5))[..., None]
    a = lerp(a, rgb(98, 70, 48), wear * 0.45)
    a = lerp(a, a * 0.65, cr * 0.6)
    a = lerp(a, rgb(104, 82, 62), scuff * 0.45)
    rough = 0.62 + 0.06 * (1 - pebble) - 0.12 * wear + 0.08 * cr + 0.1 * scuff + 0.02 * mott
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.4, 0.85))


def mat_rubber(N=512):
    S = Seeds(1616)
    grain = zscore(blur(white(N, S()), 0.9))
    fine = spectral(N, S(), beta=0.8, fmin=20)
    mott = fbm(N, 5, 5, S())
    dust = wear_mask(N, S(), freq=6, thresh=1.0, soft=1.4, breakup=0.8)
    pd, pm, _ = scatter_discs(N, 60, S(), prob=0.15, rmin=0.6, rmax=1.5)
    scuff = blur(strokes(N, 60, S(), length=(6, 30), width=(0.8, 2.0), intensity=(0.2, 0.6)), 0.6)
    h = 0.2 * grain + 0.25 * fine + 0.15 * mott - 0.8 * pd - 0.2 * scuff
    a = rgb(40, 40, 41) * (1 + 0.02 * mott + 0.03 * grain)[..., None]
    a = lerp(a, rgb(66, 64, 61), dust * 0.35)
    a = lerp(a, rgb(54, 54, 55), scuff * 0.45)
    a = lerp(a, a * 0.75, pm)
    rough = 0.7 + 0.03 * grain + 0.02 * mott + 0.1 * dust - 0.06 * scuff
    return dict(albedo=finish_albedo(a), height=h, normal=height_to_normal(h, 1.0),
                roughness=np.clip(rough, 0.62, 0.88))


MATERIALS = {
    "concrete_floor": (mat_concrete_floor, 1024),
    "concrete_wall": (mat_concrete_wall, 1024),
    "rusted_metal": (mat_rusted_metal, 1024),
    "painted_steel": (mat_painted_steel, 1024),
    "corrugated_metal": (mat_corrugated_metal, 1024),
    "steel_grate": (mat_steel_grate, 512),
    "wood_planks": (mat_wood_planks, 1024),
    "brick": (mat_brick, 1024),
    "tiles_dirty": (mat_tiles_dirty, 1024),
    "gun_metal": (mat_gun_metal, 512),
    "gun_polymer": (mat_gun_polymer, 512),
    "gun_wood": (mat_gun_wood, 512),
    "fabric_canvas": (mat_fabric_canvas, 512),
    "fabric_dark": (mat_fabric_dark, 512),
    "leather": (mat_leather, 512),
    "rubber": (mat_rubber, 512),
}


# =============================================================================
# FX sprites (non-tiling, straight alpha)
# =============================================================================
def _grid_xy(w, h, cx, cy):
    yy, xx = np.mgrid[0:h, 0:w].astype(F32) + 0.5
    return xx - cx, yy - cy


def _local_noise(w, h, freq, seed, octaves=5):
    """Non-tiling helper: crop an fbm tile to a w x h sprite."""
    n = max(w, h)
    return fbm(n, freq, octaves, seed)[:h, :w]


def _fire_ramp(t):
    """Intensity 0..1 -> straight-alpha flame colour."""
    stops = [(0.0, rgb(170, 40, 8)), (0.25, rgb(245, 110, 25)), (0.5, rgb(255, 185, 70)),
             (0.75, rgb(255, 232, 150)), (1.0, rgb(255, 252, 235))]
    out = np.zeros(t.shape + (3,), F32)
    for (t0, c0), (t1, c1) in zip(stops[:-1], stops[1:]):
        m = (t >= t0) & (t <= t1)
        s = ((t - t0) / (t1 - t0))[m][:, None]
        out[m] = c0 * (1 - s) + c1 * s
    out[t > 1] = stops[-1][1]
    return out


def _petal(dx, dy, ang, length, width):
    """Leaf-shaped lobe from the origin along `ang`."""
    ca, sa = math.cos(ang), math.sin(ang)
    along = dx * ca + dy * sa
    lat = -dx * sa + dy * ca
    t = np.clip(along / length, 0, 1)
    wprof = width * np.maximum(np.sin(np.pi * np.clip(t, 0, 1)), 0) ** 0.8 * (1 - 0.35 * t) + 1.0
    v = np.exp(-0.5 * (lat / wprof) ** 2) * (along > -2) * (1 - t) ** 0.9
    return v.astype(F32)


def fx_muzzle_side(seed=1):
    W, H = 512, 256
    rng = np.random.default_rng(seed)
    ox, oy = 36, H / 2
    dx, dy = _grid_xy(W, H, ox, oy)
    n1 = _local_noise(W, H, 8, seed + 1)
    n2 = _local_noise(W, H, 24, seed + 2)
    # Turbulent breakup advected along the flash axis.
    dxw = dx + 10 * n1
    dyw = dy + 6 * n2
    I = np.zeros((H, W), F32)
    for k in range(11):
        ang = rng.normal(0, 0.2) if k > 0 else 0.0
        L = rng.uniform(200, 470) if k > 0 else 470
        wdt = rng.uniform(14, 34) if k > 0 else 30
        I = np.maximum(I, _petal(dxw, dyw, ang, L, wdt) * rng.uniform(0.55, 1.0))
    # Side jets (gas escaping sideways from a brake).
    for ang in (-1.25, 1.25, -2.0, 2.0):
        I = np.maximum(I, 0.6 * _petal(dxw, dyw, ang + rng.normal(0, 0.1), rng.uniform(70, 110), 14))
    core = np.exp(-0.5 * ((dx / 90) ** 2 + (dy / 32) ** 2))
    hot = np.exp(-0.5 * ((dx / 36) ** 2 + (dy / 20) ** 2))
    I = I * (0.65 + 0.45 * norm01(n2)) + 0.6 * core + 0.6 * hot
    I = np.clip(I, 0, 1.3)
    I = I * sstep(-30, 0, dx)                     # nothing behind the muzzle
    I = I * sstep(W - ox, W - ox - 40, dx) * sstep(H / 2, H / 2 - 16, np.abs(dy))
    col = _fire_ramp(np.clip(I, 0, 1))
    alpha = sstep(0.06, 0.55, I)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_muzzle_front(seed=2):
    S_ = 256
    rng = np.random.default_rng(seed)
    dx, dy = _grid_xy(S_, S_, S_ / 2, S_ / 2)
    n1 = _local_noise(S_, S_, 8, seed + 1)
    n2 = _local_noise(S_, S_, 20, seed + 2)
    dxw, dyw = dx + 4 * n1, dy + 4 * n2
    I = np.zeros((S_, S_), F32)
    count = 6
    base = rng.uniform(0, 2 * np.pi)
    for k in range(count):
        ang = base + k * 2 * np.pi / count + rng.normal(0, 0.15)
        I = np.maximum(I, _petal(dxw, dyw, ang, rng.uniform(80, 122), rng.uniform(10, 16)) * rng.uniform(0.7, 1.0))
    for k in range(count):
        ang = base + (k + 0.5) * 2 * np.pi / count + rng.normal(0, 0.2)
        I = np.maximum(I, 0.55 * _petal(dxw, dyw, ang, rng.uniform(40, 70), 7))
    r = np.hypot(dx, dy)
    I = I * (0.7 + 0.4 * norm01(n2)) + 0.9 * np.exp(-0.5 * (r / 20) ** 2) + 0.25 * np.exp(-0.5 * (r / 55) ** 2)
    I = np.clip(I, 0, 1.3) * sstep(127, 110, r)
    col = _fire_ramp(np.clip(I, 0, 1))
    alpha = sstep(0.05, 0.5, I)
    return np.concatenate([col, alpha[..., None]], -1)


def _puff(size, seed, blobs=14, spread=0.22, rad=(0.12, 0.22), detail=0.5):
    rng = np.random.default_rng(seed)
    dx, dy = _grid_xy(size, size, size / 2, size / 2)
    D = np.zeros((size, size), F32)
    for _ in range(blobs):
        bx, by = rng.normal(0, spread * size, 2)
        br = rng.uniform(*rad) * size
        D += np.exp(-0.5 * ((dx - bx) ** 2 + (dy - by) ** 2) / br ** 2)
    n = norm01(_local_noise(size, size, 6, seed + 1, 6))
    D = D * (1 - detail + detail * 1.4 * n)
    rn, _, _, _ = _radial_noise(size, seed + 2, k=5)
    r0 = np.hypot(dx, dy) / (size / 2)
    D *= sstep(1.0, 0.7, r0 * (1 + 0.12 * rn)) * sstep(0.98, 0.85, r0)
    return D, n


def fx_smoke(seed=3):
    D, n = _puff(256, seed, blobs=18, spread=0.15, rad=(0.08, 0.17), detail=0.6)
    alpha = 1 - np.exp(-1.6 * D)
    alpha = np.clip(alpha * 0.92, 0, 1)
    gy = grad(blur(D, 3))[1]
    shade = np.clip(0.5 - 2.5 * gy, 0, 1)        # lit from above
    c = 0.42 + 0.22 * shade + 0.08 * n
    col = np.stack([c, c * 0.99, c * 0.97], -1)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_dust(seed=4):
    D, n = _puff(256, seed, blobs=18, spread=0.16, rad=(0.08, 0.17), detail=0.7)
    grit = norm01(blur(np.random.default_rng(seed + 9).random((256, 256), dtype=F32), 0.8))
    alpha = 1 - np.exp(-1.4 * D * (0.7 + 0.6 * grit))
    gy = grad(blur(D, 3))[1]
    shade = np.clip(0.5 - 2.5 * gy, 0, 1)
    c = 0.5 + 0.18 * shade + 0.08 * n
    col = np.stack([c * 1.0, c * 0.92, c * 0.8], -1)
    return np.concatenate([col, np.clip(alpha, 0, 1)[..., None]], -1)


def fx_blood_puff(seed=5):
    D, n = _puff(256, seed, blobs=12, spread=0.12, rad=(0.07, 0.16), detail=0.75)
    alpha = np.clip((1 - np.exp(-1.5 * D)) * 0.9, 0, 1)
    col = np.stack([0.32 + 0.12 * n, 0.03 + 0.02 * n, 0.03 + 0.02 * n], -1)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_spark():
    dx, dy = _grid_xy(64, 64, 32, 32)
    I = np.exp(-0.5 * ((dx / 15) ** 2 + (dy / 2.2) ** 2)) + 0.8 * np.exp(-0.5 * ((dx / 7) ** 2 + (dy / 1.2) ** 2))
    I = np.clip(I, 0, 1.2) * sstep(32, 24, np.abs(dx)) * sstep(32, 24, np.abs(dy))
    col = _fire_ramp(np.clip(0.45 + 0.6 * I, 0, 1))
    alpha = np.clip(I * 1.1, 0, 1)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_dust_mote():
    dx, dy = _grid_xy(32, 32, 16, 16)
    r = np.hypot(dx, dy)
    alpha = np.exp(-0.5 * (r / 5.0) ** 2) * sstep(15.5, 12, r)
    col = np.ones((32, 32, 3), F32) * rgb(240, 236, 226)
    return np.concatenate([col, alpha[..., None]], -1)


def _radial_noise(w, seed, k=6):
    """Smooth periodic function of angle, sum of a few harmonics."""
    rng = np.random.default_rng(seed)
    dx, dy = _grid_xy(w, w, w / 2, w / 2)
    th = np.arctan2(dy, dx)
    out = np.zeros_like(th)
    for m in range(1, k + 1):
        out += rng.normal(0, 1.0 / m) * np.cos(m * th + rng.uniform(0, 2 * np.pi))
    for m in range(k + 1, 3 * k):
        out += rng.normal(0, 0.6 / m) * np.cos(m * th + rng.uniform(0, 2 * np.pi))
    return out.astype(F32), dx, dy, th


def fx_hole_metal(seed=6):
    w = 128
    rn, dx, dy, th = _radial_noise(w, seed)
    r = np.hypot(dx, dy)
    n = norm01(_local_noise(w, w, 16, seed + 1))
    hole_r = 9 + 1.2 * rn
    hole = sstep(hole_r + 0.8, hole_r - 0.8, r)
    ring_r = 20 + 2.5 * rn
    ring = sstep(ring_r + 2, ring_r - 2, r) * (1 - hole)
    scorch = np.exp(-0.5 * (r / 26) ** 2)
    col = rgb(150, 148, 145) * (0.8 + 0.4 * n)[..., None]                 # bright scuffed metal
    col = lerp(col, rgb(160, 152, 140), sstep(hole_r + 6, hole_r + 1, r) * 0.6)
    col = lerp(np.broadcast_to(rgb(40, 38, 36), col.shape).copy(), col, ring)
    col = lerp(col, rgb(10, 9, 9), hole)
    alpha = np.clip(np.maximum(hole, ring * 0.95) + scorch * 0.5 * (1 - ring), 0, 1)
    alpha *= sstep(60, 40, r)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_hole_concrete(seed=7):
    w = 128
    rn, dx, dy, th = _radial_noise(w, seed, k=8)
    r = np.hypot(dx, dy)
    n = norm01(_local_noise(w, w, 16, seed + 1))
    crater_r = 17 + 4 * rn
    crater = sstep(crater_r + 1, crater_r - 1, r)
    depth = np.clip(1 - r / np.maximum(crater_r, 1), 0, 1)
    rng = np.random.default_rng(seed)
    cracks = np.zeros((w, w), F32)
    img = Image.new("L", (w * 4, w * 4), 0)
    d = ImageDraw.Draw(img)
    for k in range(7):
        a = rng.uniform(0, 2 * np.pi)
        x, y = w / 2 + math.cos(a) * 14, w / 2 + math.sin(a) * 14
        L = rng.uniform(18, 40)
        pts = [(x * 4, y * 4)]
        for _ in range(6):
            a += rng.normal(0, 0.35)
            x += math.cos(a) * L / 6
            y += math.sin(a) * L / 6
            pts.append((x * 4, y * 4))
        d.line(pts, fill=int(255 * rng.uniform(0.6, 1)), width=4)
    cracks = np.asarray(img.resize((w, w), Image.BOX), F32) / 255 * sstep(55, 30, r)
    dust_ring = np.exp(-0.5 * ((r - crater_r - 6) / 9) ** 2) * (0.6 + 0.4 * n)
    col = lerp(rgb(170, 165, 155), rgb(80, 76, 70), depth ** 0.7)          # fresh light chip -> dark core
    col = col * (0.85 + 0.3 * n)[..., None]
    col = lerp(col, rgb(28, 26, 24), sstep(0.65, 0.95, depth))
    out_col = lerp(rgb(185, 178, 165) * np.ones_like(col), rgb(50, 48, 45), cracks)
    col = lerp(out_col, col, crater)
    alpha = np.clip(np.maximum(crater, np.maximum(cracks * 0.9, dust_ring * 0.55)), 0, 1)
    alpha *= sstep(62, 45, r)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_hole_wood(seed=8):
    w = 128
    rn, dx, dy, th = _radial_noise(w, seed, k=7)
    r = np.hypot(dx, dy)
    rng = np.random.default_rng(seed)
    hole_r = 8 + 1.0 * rn
    hole = sstep(hole_r + 0.8, hole_r - 0.8, r)
    # Splinters: elongated slivers mostly along the grain (x axis).
    spl = np.zeros((w, w), F32)
    img = Image.new("L", (w * 4, w * 4), 0)
    d = ImageDraw.Draw(img)
    for k in range(16):
        side = rng.choice([-1, 1])
        a = (0 if side > 0 else np.pi) + rng.normal(0, 0.35)
        x0 = w / 2 + math.cos(a) * rng.uniform(5, 9)
        y0 = w / 2 + math.sin(a) * rng.uniform(5, 9)
        L = rng.uniform(12, 40)
        wd = rng.uniform(1.5, 4)
        x1, y1 = x0 + math.cos(a) * L, y0 + math.sin(a) * L
        nx, ny = -math.sin(a) * wd, math.cos(a) * wd
        d.polygon([((x0 + nx) * 4, (y0 + ny) * 4), ((x0 - nx) * 4, (y0 - ny) * 4), (x1 * 4, y1 * 4)],
                  fill=int(255 * rng.uniform(0.6, 1.0)))
    spl = np.asarray(img.resize((w, w), Image.BOX), F32) / 255
    torn = sstep(18 + 3 * rn, 10 + 2 * rn, r)
    grain = 0.5 + 0.5 * np.sin(dy * 1.6 + 2 * _local_noise(w, w, 8, seed + 3))
    col = lerp(rgb(150, 110, 70), rgb(200, 165, 115), grain[..., None] * 0.6 + 0.2)
    col = lerp(col, rgb(70, 48, 30), sstep(hole_r + 6, hole_r, r) * 0.7)
    col = lerp(col, rgb(16, 12, 10), hole)
    alpha = np.clip(np.maximum(np.maximum(hole, spl * 0.95), torn * 0.9), 0, 1)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_blood_splatter(seed=9):
    w = 256
    rn, dx, dy, th = _radial_noise(w, seed, k=10)
    r = np.hypot(dx, dy)
    rng = np.random.default_rng(seed)
    n = norm01(_local_noise(w, w, 12, seed + 1))
    main_r = 46 + 10 * rn + 6 * (n - 0.5)
    m = sstep(main_r + 1, main_r - 1, r)
    img = Image.new("L", (w * 4, w * 4), 0)
    d = ImageDraw.Draw(img)
    # Spikes and droplets radiating out, droplets elongated along their direction.
    for k in range(70):
        a = rng.uniform(0, 2 * np.pi)
        dist = rng.uniform(40, 118) ** 1.0
        rad = max(1.0, rng.uniform(1.0, 8.0) * (1 - dist / 140) ** 1.2)
        cx, cy = w / 2 + math.cos(a) * dist, w / 2 + math.sin(a) * dist
        el = rng.uniform(1.0, 2.6)
        pts = []
        for t in np.linspace(0, 2 * np.pi, 24, endpoint=False):
            ex, ey = math.cos(t) * rad * el, math.sin(t) * rad
            pts.append(((cx + ex * math.cos(a) - ey * math.sin(a)) * 4,
                        (cy + ex * math.sin(a) + ey * math.cos(a)) * 4))
        d.polygon(pts, fill=255)
        if rng.random() < 0.4:   # streak tail back toward the centre
            tx, ty = cx - math.cos(a) * rad * 4, cy - math.sin(a) * rad * 4
            d.line([(cx * 4, cy * 4), (tx * 4, ty * 4)], fill=255, width=max(1, int(rad * 2.4)))
    for k in range(9):   # spikes from main blob
        a = rng.uniform(0, 2 * np.pi)
        L = rng.uniform(55, 80)
        wd = rng.uniform(1.2, 2.5)
        x1, y1 = w / 2 + math.cos(a) * L, w / 2 + math.sin(a) * L
        nx, ny = -math.sin(a) * wd, math.cos(a) * wd
        d.polygon([((w / 2 + nx * 3) * 4, (w / 2 + ny * 3) * 4), ((w / 2 - nx * 3) * 4, (w / 2 - ny * 3) * 4),
                   (x1 * 4, y1 * 4)], fill=255)
    drops = np.asarray(img.resize((w, w), Image.BOX), F32) / 255
    mask = np.clip(np.maximum(m, drops), 0, 1)
    thick = blur(mask, 4)
    col = lerp(rgb(128, 14, 12), rgb(78, 6, 6), np.clip(thick * 1.2, 0, 1))
    col = col * (0.85 + 0.25 * n)[..., None]
    alpha = mask * (0.85 + 0.15 * np.clip(thick * 2, 0, 1))
    return np.concatenate([col, alpha[..., None]], -1)


def fx_scope_overlay():
    w = 1024
    ss = 2
    W = w * ss
    dx, dy = _grid_xy(W, W, W / 2, W / 2)
    dx, dy = dx / ss, dy / ss      # in output pixels
    r = np.hypot(dx, dy)
    R = 0.46 * w
    outside = sstep(R - 1.0, R + 1.0, r)
    vign = 0.75 * sstep(R - 70, R, r) ** 2
    thin = 0.9
    post = 5.0
    post_start = 0.36 * R
    hline = sstep(thin + 0.5, thin - 0.5, np.abs(dy))
    vline = sstep(thin + 0.5, thin - 0.5, np.abs(dx))
    hpost = sstep(post + 0.5, post - 0.5, np.abs(dy)) * sstep(post_start - 0.5, post_start + 0.5, np.abs(dx))
    vpost = sstep(post + 0.5, post - 0.5, np.abs(dx)) * sstep(post_start - 0.5, post_start + 0.5, np.abs(dy))
    # Post tips taper to a point.
    tip_h = sstep(post_start + 18, post_start, np.abs(dx)) * (np.abs(dy) > (np.abs(dx) - post_start) / 18 * post)
    tip_v = sstep(post_start + 18, post_start, np.abs(dy)) * (np.abs(dx) > (np.abs(dy) - post_start) / 18 * post)
    hpost *= 1 - tip_h
    vpost *= 1 - tip_v
    # Mil dots along the thin lines.
    spacing = post_start / 5
    dots = np.zeros_like(r)
    for k in range(1, 5):
        for s in (-1, 1):
            dots = np.maximum(dots, sstep(3.2, 2.2, np.hypot(dx - s * k * spacing, dy)))
            dots = np.maximum(dots, sstep(3.2, 2.2, np.hypot(dx, dy - s * k * spacing)))
    cross = np.maximum.reduce([hline, vline, hpost, vpost, dots])
    alpha = np.clip(np.maximum.reduce([outside, vign, cross]), 0, 1)
    alpha = alpha.reshape(w, ss, w, ss).mean(axis=(1, 3))
    col = np.zeros((w, w, 3), F32)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_scope_pso1():
    """PSO-1 reticle: the aiming chevron, three smaller holdover chevrons
    under it, a windage scale either side, the stadiametric rangefinder
    curve lower left."""
    w = 1024
    ss = 2
    W = w * ss
    dx, dy = _grid_xy(W, W, W / 2, W / 2)
    dx, dy = dx / ss, dy / ss
    r = np.hypot(dx, dy)
    R = 0.46 * w
    outside = sstep(R - 1.0, R + 1.0, r)
    vign = 0.8 * sstep(R - 80, R, r) ** 2
    lw = 1.4

    def chevron(cy, size):
        # Inverted V with its apex at (0, cy): two strokes down-left and down-right.
        u = dy - cy
        d1 = np.abs(u - np.abs(dx) * 1.0) / np.sqrt(2.0)
        inside = (u >= 0) & (u <= size) & (np.abs(dx) <= size)
        return sstep(lw + 0.5, lw - 0.5, d1) * inside

    marks = chevron(0.0, 26.0)
    for k in range(1, 4):
        marks = np.maximum(marks, chevron(k * 62.0, 15.0))
    # Windage scale: ticks every 20 px either side, longer every 100.
    scale = sstep(lw + 0.5, lw - 0.5, np.abs(dy)) * (np.abs(dx) > 70) * (np.abs(dx) < 300)
    for k in range(4, 16):
        h = 14.0 if k % 5 == 0 else 7.0
        for sgn in (-1, 1):
            scale = np.maximum(scale, sstep(lw + 0.5, lw - 0.5, np.abs(dx - sgn * k * 20)) * (dy < 0) * (dy > -h))
    # Rangefinder: a horizontal base line and a curved upper line, lower left.
    base = sstep(lw + 0.5, lw - 0.5, np.abs(dy - 210)) * (dx > -330) * (dx < -90)
    t = np.clip((dx + 330) / 240.0, 0, 1)
    curve_y = 210 - (10 + 60 * (1 - t) ** 1.6)
    curve = sstep(lw + 0.5, lw - 0.5, np.abs(dy - curve_y)) * (dx > -330) * (dx < -90)
    cross = np.maximum.reduce([marks, scale, base, curve])
    alpha = np.clip(np.maximum.reduce([outside, vign, cross]), 0, 1)
    alpha = alpha.reshape(w, ss, w, ss).mean(axis=(1, 3))
    col = np.zeros((w, w, 3), F32)
    return np.concatenate([col, alpha[..., None]], -1)


def fx_light_cone():
    w = 128
    x = (np.arange(w, dtype=F32) + 0.5) / w
    y = (np.arange(w, dtype=F32) + 0.5) / w
    across = np.exp(-0.5 * ((x - 0.5) / 0.2) ** 2)
    along = (1 - y) ** 1.5
    a = (along[:, None] * across[None, :])
    col = np.ones((w, w, 3), F32)
    return np.concatenate([col, a[..., None]], -1)


FX = {
    "muzzle_flash_side": fx_muzzle_side,
    "muzzle_flash_front": fx_muzzle_front,
    "smoke_puff": fx_smoke,
    "spark": fx_spark,
    "dust_puff": fx_dust,
    "blood_puff": fx_blood_puff,
    "bullet_hole_metal": fx_hole_metal,
    "bullet_hole_concrete": fx_hole_concrete,
    "bullet_hole_wood": fx_hole_wood,
    "blood_splatter": fx_blood_splatter,
    "dust_mote": fx_dust_mote,
    "scope_overlay": fx_scope_overlay,
    "scope_overlay_pso1": fx_scope_pso1,
    "light_cone_falloff": fx_light_cone,
}


# =============================================================================
# QA: seam check and preview sheets
# =============================================================================
def seam_ratio(img):
    """Wrap-around edge difference relative to the typical neighbour difference
    (1.0 == the seam is statistically indistinguishable from any other column)."""
    a = img.astype(F32)
    if a.ndim == 3:
        a = a.mean(-1)
    inner_x = np.abs(np.diff(a, axis=1)).mean()
    inner_y = np.abs(np.diff(a, axis=0)).mean()
    seam_x = np.abs(a[:, 0] - a[:, -1]).mean()
    seam_y = np.abs(a[0, :] - a[-1, :]).mean()
    return seam_x / (inner_x + 1e-8), seam_y / (inner_y + 1e-8)


LIGHT = np.array([-0.45, 0.55, 0.70], F32)
LIGHT /= np.linalg.norm(LIGHT)


def lit_render(albedo, normal):
    nd = np.clip((normal * LIGHT).sum(-1), 0, 1)
    shade = 0.18 + 0.95 * nd
    lin = srgb_to_lin(albedo[..., :3]) * shade[..., None]
    return lin_to_srgb(lin)


def tile2(a):
    return np.concatenate([np.concatenate([a, a], 1)] * 2, 0)


def to_img(a, size=None):
    im = Image.fromarray(_to_u8(a))
    if size:
        im = im.resize((size, size), Image.LANCZOS)
    return im


def _font(sz):
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "DejaVuSans-Bold.ttf"]:
        try:
            return ImageFont.truetype(p, sz)
        except OSError:
            continue
    return ImageFont.load_default()


def material_preview(name, maps, cell=300):
    a = maps["albedo"]
    if a.shape[-1] == 4:
        bg = np.ones_like(a[..., :3]) * 0.18
        a3 = lerp(bg, a[..., :3], a[..., 3])
    else:
        a3 = a
    lit = lit_render(a3, maps["normal"])
    rough = gray3(maps["roughness"])
    met = gray3(maps["metallic"]) if "metallic" in maps else None
    imgs = [to_img(tile2(a3), cell), to_img(tile2(lit), cell), to_img(tile2(rough), cell // 2)]
    if met is not None:
        imgs.append(to_img(tile2(met), cell // 2))
    return imgs


def build_material_sheet(previews, path):
    cell = 300
    pad = 10
    lab = 26
    cols = 2
    names = list(previews)
    rows = math.ceil(len(names) / cols)
    block_w = cell * 2 + cell // 2 + pad * 3
    block_h = cell + lab + pad
    W = cols * block_w + pad
    H = rows * block_h + pad
    sheet = Image.new("RGB", (W, H), (28, 28, 30))
    d = ImageDraw.Draw(sheet)
    f = _font(18)
    fs = _font(12)
    for k, name in enumerate(names):
        cx = pad + (k % cols) * block_w
        cy = pad + (k // cols) * block_h
        d.text((cx, cy + 2), name, fill=(235, 235, 235), font=f)
        imgs = previews[name]
        sheet.paste(imgs[0], (cx, cy + lab))
        sheet.paste(imgs[1], (cx + cell + pad, cy + lab))
        sheet.paste(imgs[2], (cx + 2 * cell + 2 * pad, cy + lab))
        d.text((cx + 2 * cell + 2 * pad, cy + lab + cell // 2 - 14), "", font=fs)
        if len(imgs) > 3:
            sheet.paste(imgs[3], (cx + 2 * cell + 2 * pad, cy + lab + cell // 2))
        d.text((cx + 4, cy + lab + 4), "albedo 2x2", fill=(255, 255, 0), font=fs)
        d.text((cx + cell + pad + 4, cy + lab + 4), "lit 2x2", fill=(255, 255, 0), font=fs)
        d.text((cx + 2 * cell + 2 * pad + 4, cy + lab + 4), "rough", fill=(255, 255, 0), font=fs)
        if len(imgs) > 3:
            d.text((cx + 2 * cell + 2 * pad + 4, cy + lab + cell // 2 + 4), "metal", fill=(255, 255, 0), font=fs)
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, optimize=True)


def build_fx_sheet(sprites, path):
    pad = 12
    lab = 22
    thumbs = []
    for name, arr in sprites.items():
        h, w = arr.shape[:2]
        scale = min(256 / w, 256 / h, 2.0 if max(w, h) <= 64 else 1.0)
        if max(w, h) <= 64:
            scale = 4.0 if max(w, h) <= 32 else 3.0
        tw, th = int(w * scale), int(h * scale)
        bg = np.ones((h, w, 3), F32) * 0.5
        comp = lerp(bg, arr[..., :3], arr[..., 3])
        im = Image.fromarray(_to_u8(comp)).resize((tw, th), Image.LANCZOS if scale < 1 else Image.BICUBIC)
        thumbs.append((name, im))
    cols = 4
    cw, ch = 256 + pad, 256 + lab + pad
    rows = math.ceil(len(thumbs) / cols)
    sheet = Image.new("RGB", (cols * cw + pad, rows * ch + pad), (128, 128, 128))
    d = ImageDraw.Draw(sheet)
    f = _font(14)
    for k, (name, im) in enumerate(thumbs):
        x = pad + (k % cols) * cw
        y = pad + (k // cols) * ch
        d.text((x, y), name, fill=(20, 20, 20), font=f)
        sheet.paste(im, (x, y + lab))
    sheet.save(path, optimize=True)


# =============================================================================
# Main
# =============================================================================
def main(argv):
    global OPTIMIZE_PNG
    args = [a for a in argv if not a.startswith("--")]
    if "--fast" in argv:
        OPTIMIZE_PNG = False
    want_all = not args
    want_fx = want_all or "fx" in args
    names = [n for n in MATERIALS if want_all or n in args]
    unknown = [a for a in args if a != "fx" and a not in MATERIALS]
    if unknown:
        sys.exit(f"unknown material(s): {unknown}")

    previews = {}
    for name in names:
        fn, size = MATERIALS[name]
        t0 = time.time()
        maps = fn(size)
        save_material(name, maps)
        sx, sy = seam_ratio(maps["albedo"][..., :3])
        nx, ny = seam_ratio(maps["normal"])
        lin = srgb_to_lin(maps["albedo"][..., :3])
        print(f"{name:18s} {size:5d}px {time.time() - t0:5.1f}s  seam albedo x{sx:4.2f} y{sy:4.2f} "
              f"normal x{nx:4.2f} y{ny:4.2f}  albedo lin p1={np.percentile(lin, 1):.3f} "
              f"p99={np.percentile(lin, 99):.3f}")
        previews[name] = material_preview(name, maps)
        if "--big" in argv:
            al = maps["albedo"]
            if al.shape[-1] == 4:
                al = lerp(np.full(al.shape[:2] + (3,), 0.18, F32), al[..., :3], al[..., 3])
            big = np.concatenate([tile2(al), tile2(lit_render(al, maps["normal"]))], 1)
            dbg = Path(os.environ.get("TEX_DEBUG_DIR", PREVIEW_DIR / "debug"))
            dbg.mkdir(parents=True, exist_ok=True)
            to_img(big).save(dbg / f"{name}.png")
    if want_all:
        build_material_sheet(previews, PREVIEW_DIR / "textures_contact_sheet.png")
    elif previews:
        dbg = Path(os.environ.get("TEX_DEBUG_DIR", PREVIEW_DIR / "debug"))
        dbg.mkdir(parents=True, exist_ok=True)
        build_material_sheet(previews, dbg / "partial_contact_sheet.png")

    if want_fx:
        sprites = {}
        for name, fn in FX.items():
            arr = fn()
            save_png(FX_DIR / f"{name}.png", arr, "RGBA", dither_seed=7)
            sprites[name] = arr
        build_fx_sheet(sprites, PREVIEW_DIR / "fx_contact_sheet.png")
        print("fx sprites:", ", ".join(sprites))


if __name__ == "__main__":
    main(sys.argv[1:])
