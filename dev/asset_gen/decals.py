"""Decal textures for procedural levels: alchemical wall symbols (chalk,
paint, scratches), a wet puddle and a salt circle.

    python3 dev/asset_gen/decals.py      # writes assets/textures/decals/*.png

Deterministic (fixed seeds). Straight-alpha RGBA PNGs.
"""
import math
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "decals")
S = 512


def noise(rng, size, scale):
    """Smooth value noise in 0..1 (bilinear upsample of random grid)."""
    g = rng.random((size // scale + 2, size // scale + 2))
    img = Image.fromarray((g * 255).astype(np.uint8)).resize((size + 2 * scale, size + 2 * scale), Image.BICUBIC)
    a = np.asarray(img, dtype=np.float32)[scale:scale + size, scale:scale + size] / 255.0
    return a


def fbm(rng, size, scales=(64, 24, 8, 3), weights=(0.5, 0.25, 0.15, 0.1)):
    out = np.zeros((size, size), np.float32)
    for sc, w in zip(scales, weights):
        out += noise(rng, size, sc) * w
    return out


def stroke_mask(draw_fn, width_px):
    """Draw strokes at 2x for smooth edges, return 0..1 mask at S."""
    big = Image.new("L", (S * 2, S * 2), 0)
    d = ImageDraw.Draw(big)
    draw_fn(d, width_px * 2, 2.0)
    return np.asarray(big.resize((S, S), Image.LANCZOS), dtype=np.float32) / 255.0


def save(name, rgb, alpha):
    a = np.clip(alpha, 0, 1)
    img = np.dstack([np.clip(rgb, 0, 1), a])
    Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, name + ".png"), optimize=True)


def chalk(mask, rng, color=(0.88, 0.86, 0.8)):
    grain = rng.random((S, S)).astype(np.float32)
    streak = noise(rng, S, 3)
    alpha = mask * np.clip(0.35 + 0.65 * grain * (0.6 + 0.6 * streak), 0, 1) * 0.85
    alpha *= np.clip(fbm(rng, S) * 1.6 - 0.15, 0.25, 1.0)  # rubbed away in places
    rgb = np.dstack([np.full((S, S), c, np.float32) for c in color])
    return rgb, alpha


def paint(mask, rng, color=(0.42, 0.06, 0.04)):
    # Drips: smear the mask downward with decaying strength from random columns.
    drip = np.zeros_like(mask)
    cols = rng.choice(S, size=40, replace=False)
    for c in cols:
        col = mask[:, max(c - 2, 0):c + 3].max(axis=1)
        starts = np.nonzero(col > 0.6)[0]
        if starts.size == 0:
            continue
        y0 = starts.max()
        length = int(rng.integers(20, 120))
        for i in range(length):
            y = y0 + i
            if y >= S:
                break
            w = 1 - i / length
            drip[y, max(c - 1, 0):c + 2] = np.maximum(drip[y, max(c - 1, 0):c + 2], w * 0.9)
    m = np.maximum(mask, drip)
    edge = np.clip(fbm(rng, S, (16, 6, 3), (0.5, 0.3, 0.2)) * 1.4, 0.6, 1.0)
    alpha = np.clip(m * edge, 0, 1) * 0.92
    shade = 0.75 + 0.35 * noise(rng, S, 12)
    rgb = np.dstack([np.full((S, S), c, np.float32) * shade for c in color])
    return rgb, alpha


def scratch(mask, rng):
    grain = rng.random((S, S)).astype(np.float32)
    alpha = mask * (0.5 + 0.5 * grain) * 0.8
    rgb = np.dstack([np.full((S, S), c, np.float32) for c in (0.62, 0.6, 0.55)])
    return rgb, alpha


def wobble(points, rng, amount=6.0):
    return [(x + rng.normal(0, amount), y + rng.normal(0, amount)) for x, y in points]


def circle_pts(cx, cy, r, n=72, start=0.0, end=math.tau):
    return [(cx + r * math.cos(start + (end - start) * i / n), cy + r * math.sin(start + (end - start) * i / n)) for i in range(n + 1)]


def symbols():
    c = S  # drawing happens at 2x: center = S
    specs = []

    # 0: Sulfur - triangle over a cross (chalk)
    def sulfur(d, w, k):
        rng = np.random.default_rng(10)
        tri = [(c, c - 300), (c - 240, c + 90), (c + 240, c + 90), (c, c - 300)]
        d.line(wobble(tri, rng, 4), fill=255, width=w, joint="curve")
        d.line(wobble([(c, c + 90), (c, c + 420)], rng, 4), fill=255, width=w)
        d.line(wobble([(c - 150, c + 260), (c + 150, c + 260)], rng, 4), fill=255, width=w)
    specs.append(("chalk", sulfur, 22))

    # 1: Mercury - horns, circle, cross (chalk)
    def mercury(d, w, k):
        rng = np.random.default_rng(11)
        d.line(wobble(circle_pts(c, c - 120, 150), rng, 3), fill=255, width=w, joint="curve")
        d.line(wobble(circle_pts(c, c - 330, 120, 36, 0.15 * math.pi, 0.85 * math.pi), rng, 3), fill=255, width=w, joint="curve")
        d.line(wobble([(c, c + 30), (c, c + 400)], rng, 4), fill=255, width=w)
        d.line(wobble([(c - 130, c + 230), (c + 130, c + 230)], rng, 4), fill=255, width=w)
    specs.append(("chalk", mercury, 20))

    # 2: Salt - circle with a bar (red paint)
    def salt(d, w, k):
        rng = np.random.default_rng(12)
        d.line(wobble(circle_pts(c, c, 300), rng, 6), fill=255, width=w, joint="curve")
        d.line(wobble([(c - 300, c), (c + 300, c)], rng, 6), fill=255, width=w)
    specs.append(("paint", salt, 34))

    # 3: Squared circle seal (chalk): circle, square, triangle, circle
    def seal(d, w, k):
        rng = np.random.default_rng(13)
        d.line(wobble(circle_pts(c, c, 420, 96), rng, 3), fill=255, width=w, joint="curve")
        sq = [(c - 300, c - 300), (c + 300, c - 300), (c + 300, c + 300), (c - 300, c + 300), (c - 300, c - 300)]
        d.line(wobble(sq, rng, 3), fill=255, width=w, joint="curve")
        tri = [(c, c - 290), (c + 260, c + 250), (c - 260, c + 250), (c, c - 290)]
        d.line(wobble(tri, rng, 3), fill=255, width=w, joint="curve")
        d.line(wobble(circle_pts(c, c + 60, 120, 48), rng, 3), fill=255, width=w, joint="curve")
    specs.append(("chalk", seal, 16))

    # 4: Ringed eye (dark red paint): circle of ticks around an almond eye
    def eye(d, w, k):
        rng = np.random.default_rng(14)
        for i in range(16):
            a = math.tau * i / 16
            r0, r1 = 330, 420 if i % 2 == 0 else 380
            d.line(wobble([(c + r0 * math.cos(a), c + r0 * math.sin(a)), (c + r1 * math.cos(a), c + r1 * math.sin(a))], rng, 3),
                   fill=255, width=w)
        top = circle_pts(c, c + 160, 300, 40, math.pi * 1.2, math.pi * 1.8)
        bot = circle_pts(c, c - 160, 300, 40, math.pi * 0.2, math.pi * 0.8)
        d.line(wobble(top, rng, 3), fill=255, width=w, joint="curve")
        d.line(wobble(bot, rng, 3), fill=255, width=w, joint="curve")
        d.ellipse((c - 45, c - 45, c + 45, c + 45), fill=255)
    specs.append(("paint", eye, 26))

    # 5: Earth (inverted triangle with bar) scratched, with tally marks below
    def earth(d, w, k):
        rng = np.random.default_rng(15)
        tri = [(c - 260, c - 260), (c + 260, c - 260), (c, c + 200), (c - 260, c - 260)]
        d.line(wobble(tri, rng, 5), fill=255, width=w, joint="curve")
        d.line(wobble([(c - 150, c - 60), (c + 150, c - 60)], rng, 5), fill=255, width=w)
        for i in range(7):
            x = c - 300 + i * 90
            d.line(wobble([(x, c + 330), (x + 10, c + 460)], rng, 3), fill=255, width=max(w // 2, 3))
        d.line(wobble([(c - 320, c + 420), (c - 20, c + 360)], rng, 3), fill=255, width=max(w // 2, 3))
    specs.append(("scratch", earth, 10))

    for i, (style, fn, width) in enumerate(specs):
        rng = np.random.default_rng(100 + i)
        mask = stroke_mask(fn, width)
        if style == "chalk":
            rgb, alpha = chalk(mask, rng)
        elif style == "paint":
            rgb, alpha = paint(mask, rng, (0.42, 0.06, 0.04) if i != 4 else (0.25, 0.04, 0.03))
        else:
            rgb, alpha = scratch(mask, rng)
        save("symbol_%d" % i, rgb, alpha)


def puddle():
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    r = np.hypot(xx - S / 2, yy - S / 2) / (S / 2)
    shape = 1.0 - r + (fbm(rng, S, (96, 40, 12), (0.6, 0.3, 0.1)) - 0.5) * 0.9
    alpha = np.clip((shape - 0.15) * 3.0, 0, 1) * 0.75
    rgb = np.dstack([np.full((S, S), v, np.float32) for v in (0.035, 0.035, 0.032)])
    save("puddle", rgb, alpha)


def salt_circle():
    rng = np.random.default_rng(8)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    r = np.hypot(xx - S / 2, yy - S / 2) / (S / 2)
    band = np.exp(-((r - 0.82) / 0.035) ** 2)
    wobble_r = np.exp(-((r - 0.82 - (noise(rng, S, 32) - 0.5) * 0.05) / 0.03) ** 2)
    grain = rng.random((S, S)).astype(np.float32)
    alpha = np.clip(np.maximum(band, wobble_r) * (grain > 0.35) * (0.6 + 0.4 * grain), 0, 1) * 0.9
    scatter = (rng.random((S, S)) > 0.997) * (r < 0.95) * 0.7
    alpha = np.maximum(alpha, scatter.astype(np.float32))
    rgb = np.dstack([np.full((S, S), v, np.float32) for v in (0.92, 0.91, 0.88)])
    save("salt_circle", rgb, alpha)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    symbols()
    puddle()
    salt_circle()
    print("decals written to", os.path.normpath(OUT))
