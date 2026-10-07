#!/usr/bin/env python3
"""Sign and poster decals for procedural levels: enamel room plates, exit
signs, painted sector letters and names, storey numbers, hazard labels and
safety posters. All weathered (chipped enamel, rust, grime, sun fade).

    python3 dev/asset_gen/signs.py     # writes assets/textures/decals/signs/*.png

Needs a bold sans font: DejaVu Sans Bold or Liberation Sans Bold (Linux), or
Arial Bold (Windows); pass another with --font PATH. Only the rendered PNGs
are used by the game, the font isn't shipped. Deterministic (fixed seeds).
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures", "decals", "signs")
FONTS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]

# Room plates: layout room use -> text (ChunkBuilder / Detailer use the same keys).
PLATES = {
    "offices": "OFFICE", "cubicles": "GENERAL OFFICE", "meeting": "MEETING ROOM", "archive": "RECORDS",
    "boiler": "BOILER ROOM", "electrical": "ELECTRICAL", "lockers": "LOCKER ROOM", "washroom": "WASHROOM",
    "workshop": "WORKSHOP", "parts": "PARTS STORE", "cages": "SECURE STORE", "pumps": "PUMP ROOM",
    "vats": "MIXING ROOM", "lab": "LABORATORY", "stairwell": "STAIRS", "closet": "JANITOR",
    "store": "STORE ROOM",
}
# Sector names by zone type.
SECTORS = {
    "hall": "PRESS SHOP", "foundry": "FOUNDRY", "warehouse": "WAREHOUSE", "loading_dock": "LOADING DOCK",
    "processing": "PROCESSING", "office": "ADMINISTRATION", "maintenance": "MAINTENANCE", "storage": "STORES",
    "corridor": "SERVICE CORRIDOR", "connector": "WALKWAY",
}
LETTERS = "ABCDEFGH"
HAZARDS = {
    "danger_hv": ("DANGER", "HIGH VOLTAGE"), "caution_floor": ("CAUTION", "OPEN FLOOR"),
    "no_smoking": ("NO", "SMOKING"), "ear_protection": ("EAR PROTECTION", "MUST BE WORN"),
    "authorised": ("AUTHORISED", "PERSONNEL ONLY"), "keep_clear": ("KEEP", "CLEAR"),
}
POSTERS = [
    ("SAFETY", "IS EVERYBODY'S", "JOB", (0.75, 0.62, 0.18)),
    ("REPORT", "ALL INCIDENTS", "TO YOUR SUPERVISOR", (0.62, 0.16, 0.12)),
    ("A CLEAN SHOP", "IS A", "SAFE SHOP", (0.18, 0.36, 0.55)),
    ("THINK!", "LOCK OUT", "BEFORE YOU REACH IN", (0.2, 0.42, 0.24)),
    ("YOUR FAMILY", "IS WAITING", "WORK SAFELY", (0.55, 0.38, 0.16)),
    ("QUIET", "PLEASE", "", (0.3, 0.3, 0.34)),
]


def font(size: int) -> ImageFont.FreeTypeFont:
    path = None
    if "--font" in sys.argv:
        path = sys.argv[sys.argv.index("--font") + 1]
    for p in ([path] if path else []) + FONTS:
        if p and os.path.exists(p):
            return ImageFont.truetype(p, size)
    raise SystemExit("no bold sans font found; pass --font PATH")


def noise(rng, h, w, scale):
    g = rng.random((h // scale + 2, w // scale + 2)).astype(np.float32)
    img = Image.fromarray((g * 255).astype(np.uint8)).resize((w + 2 * scale, h + 2 * scale), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32)[scale:scale + h, scale:scale + w] / 255.0


def fbm(rng, h, w):
    return 0.5 * noise(rng, h, w, 48) + 0.3 * noise(rng, h, w, 16) + 0.2 * noise(rng, h, w, 5)


def text_fit(draw, box, text, max_size, fill):
    """Largest font that fits `text` in box (x0, y0, x1, y1), centred."""
    x0, y0, x1, y1 = box
    size = max_size
    while size > 8:
        f = font(size)
        l, t, r, b = draw.textbbox((0, 0), text, font=f)
        if r - l <= x1 - x0 and b - t <= y1 - y0:
            break
        size -= 2
    l, t, r, b = draw.textbbox((0, 0), text, font=f)
    draw.text(((x0 + x1 - (r - l)) / 2 - l, (y0 + y1 - (b - t)) / 2 - t), text, font=f, fill=fill)


def weather(img: Image.Image, seed: int, chips=0.6, rust=0.5, grime=0.5, edge_alpha=True) -> Image.Image:
    """Chipped enamel (to grey steel), rust bloom, grime and fade."""
    rng = np.random.default_rng(seed)
    a = np.asarray(img.convert("RGBA"), dtype=np.float32) / 255.0
    h, w = a.shape[:2]
    rgb, alpha = a[..., :3], a[..., 3]
    n = fbm(rng, h, w)
    fine = noise(rng, h, w, 3)
    # Chips: spots where the enamel came off, more near the edges.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    edge = np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy)) / max(min(h, w) * 0.5, 1)
    chip = (fine * 0.6 + n * 0.4 + (1 - np.clip(edge * 3, 0, 1)) * 0.35) > (1.05 - chips * 0.3)
    steel = np.array([0.42, 0.41, 0.4], np.float32)
    rgb = np.where(chip[..., None], steel * (0.8 + 0.3 * fine[..., None]), rgb)
    # Rust bloom round the chips and in runs from the top.
    rust_m = np.clip((n - (1 - rust * 0.6)) * 3, 0, 1) * np.clip(1 - yy / h + 0.3, 0, 1)
    rust_m = np.maximum(rust_m, np.asarray(Image.fromarray((chip * 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(3)), dtype=np.float32) / 255.0 * rust)
    rgb = rgb * (1 - rust_m[..., None] * 0.8) + np.array([0.36, 0.17, 0.08], np.float32) * rust_m[..., None] * 0.8
    # Grime and fade.
    g = np.clip(n * 1.4 - 0.4, 0, 1) * grime
    rgb = rgb * (1 - g[..., None] * 0.55)
    rgb = rgb * 0.82 + 0.06
    if edge_alpha:
        alpha = alpha * np.clip(0.75 + fine * 0.5, 0, 1)
    out = np.dstack([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)])
    return Image.fromarray((out * 255).astype(np.uint8), "RGBA")


def plate(text, bg, fg, w=512, h=128, seed=0):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((4, 4, w - 5, h - 5), radius=12, fill=bg + (255,))
    d.rounded_rectangle((12, 12, w - 13, h - 13), radius=8, outline=fg + (255,), width=4)
    for x in (24, w - 25):
        d.ellipse((x - 6, h // 2 - 6, x + 6, h // 2 + 6), fill=(120, 120, 118, 255))  # rivets
    text_fit(d, (46, 22, w - 46, h - 22), text, 80, fg + (255,))
    return weather(img, seed)


def exit_sign(arrow: str, seed: int):
    w, h = 512, 192
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 4, w - 5, h - 5), fill=(28, 120, 62, 255))
    d.rectangle((14, 14, w - 15, h - 15), outline=(230, 240, 228, 255), width=5)
    label = "EXIT" if arrow == "" else ("\u2190 EXIT" if arrow == "l" else "EXIT \u2192")
    text_fit(d, (34, 30, w - 34, h - 30), label, 120, (236, 244, 232, 255))
    return weather(img, seed, chips=0.4, rust=0.3)


def hazard(top, bottom, seed):
    w, h = 384, 256
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 4, w - 5, h - 5), fill=(222, 182, 30, 255))
    d.rectangle((4, 4, w - 5, 96), fill=(24, 22, 20, 255))
    text_fit(d, (20, 14, w - 20, 88), top, 70, (222, 182, 30, 255))
    text_fit(d, (20, 112, w - 20, h - 20), bottom, 64, (24, 22, 20, 255))
    return weather(img, seed, chips=0.5, rust=0.6)


def painted(text, size_wh, seed, color=(0.86, 0.84, 0.78), max_font=400):
    """Stencil-style paint straight on the wall: soft overspray, worn through."""
    w, h = size_wh
    rng = np.random.default_rng(seed)
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    text_fit(d, (w * 0.06, h * 0.08, w * 0.94, h * 0.92), text, max_font, 255)
    mask = np.asarray(m, dtype=np.float32) / 255.0
    spray = np.asarray(m.filter(ImageFilter.GaussianBlur(4)), dtype=np.float32) / 255.0
    wear = np.clip(fbm(rng, h, w) * 1.7 - 0.25, 0, 1) * np.clip(0.55 + noise(rng, h, w, 2) * 0.6, 0, 1)
    alpha = np.clip(mask * 0.92 + spray * 0.18, 0, 1) * np.clip(wear * 1.3, 0.15, 1.0)
    # Drips under the strokes.
    drip = np.zeros_like(mask)
    for c in rng.choice(w, size=max(w // 24, 4), replace=False):
        col = mask[:, max(c - 1, 0):c + 2].max(axis=1)
        rows = np.nonzero(col > 0.5)[0]
        if rows.size and rng.random() < 0.5:
            y0 = rows.max()
            length = int(rng.uniform(10, h * 0.25))
            drip[y0:min(y0 + length, h), max(c - 1, 0):c + 2] = np.linspace(0.9, 0.0, min(length, h - y0))[:, None]
    alpha = np.maximum(alpha, drip * 0.7)
    rgb = np.dstack([np.full((h, w), c, np.float32) for c in color]) * (0.85 + 0.15 * noise(rng, h, w, 3)[..., None])
    return Image.fromarray((np.dstack([rgb, alpha]) * 255).astype(np.uint8), "RGBA")


def poster(lines, color, seed):
    w, h = 320, 448
    rng = np.random.default_rng(seed)
    img = Image.new("RGBA", (w, h), (230, 222, 200, 255))
    d = ImageDraw.Draw(img)
    c = tuple(int(v * 255) for v in color)
    d.rectangle((14, 14, w - 15, h - 15), outline=c + (255,), width=6)
    d.rectangle((14, 14, w - 15, 150), fill=c + (255,))
    text_fit(d, (30, 30, w - 30, 136), lines[0], 90, (236, 230, 214, 255))
    # A simple graphic: a gear, a hand or a hazard chevron band.
    kind = seed % 3
    cy = 250
    if kind == 0:
        for i in range(10):
            a = i / 10 * 2 * np.pi
            d.rectangle((w / 2 + np.cos(a) * 62 - 10, cy + np.sin(a) * 62 - 10, w / 2 + np.cos(a) * 62 + 10, cy + np.sin(a) * 62 + 10), fill=c + (255,))
        d.ellipse((w / 2 - 58, cy - 58, w / 2 + 58, cy + 58), fill=c + (255,))
        d.ellipse((w / 2 - 24, cy - 24, w / 2 + 24, cy + 24), fill=(230, 222, 200, 255))
    elif kind == 1:
        for i in range(-3, 9):
            x = 20 + i * 40
            d.polygon([(x, cy - 30), (x + 20, cy - 30), (x + 50, cy + 30), (x + 30, cy + 30)], fill=(24, 22, 20, 255))
        d.rectangle((0, cy - 34, 20, cy + 34), fill=(230, 222, 200, 255))
        d.rectangle((w - 20, cy - 34, w, cy + 34), fill=(230, 222, 200, 255))
    else:
        d.polygon([(w / 2, cy - 70), (w / 2 + 80, cy + 60), (w / 2 - 80, cy + 60)], outline=c + (255,), width=10)
        text_fit(d, (w / 2 - 20, cy - 30, w / 2 + 20, cy + 50), "!", 90, c + (255,))
    text_fit(d, (30, 330, w - 30, 380), lines[1], 46, (30, 28, 26, 255))
    if lines[2]:
        text_fit(d, (30, 384, w - 30, 422), lines[2], 34, c + (255,))
    img = weather(img, seed, chips=0.0, rust=0.15, grime=0.8, edge_alpha=False)
    # Torn corner and creases.
    a = np.asarray(img, dtype=np.float32) / 255.0
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    corner = rng.integers(0, 4)
    cx, cy2 = (0 if corner % 2 == 0 else w), (0 if corner < 2 else h)
    tear = np.hypot(xx - cx, yy - cy2) < rng.uniform(40, 90) + noise(rng, h, w, 4) * 30
    a[..., 3] = np.where(tear, 0, a[..., 3])
    crease = (np.abs(yy - h * rng.uniform(0.3, 0.7)) < 1.5) | (np.abs(xx - w * rng.uniform(0.3, 0.7)) < 1.5)
    a[..., :3] = np.where(crease[..., None], a[..., :3] * 0.8, a[..., :3])
    return Image.fromarray((a * 255).astype(np.uint8), "RGBA")


def main():
    os.makedirs(OUT, exist_ok=True)
    seed = 1
    for key, text in PLATES.items():
        plate(text, (26, 46, 78), (232, 232, 224), seed=seed).save(os.path.join(OUT, f"room_{key}.png"), optimize=True)
        seed += 1
    for arrow, name in (("", "exit"), ("l", "exit_l"), ("r", "exit_r")):
        exit_sign(arrow, seed).save(os.path.join(OUT, f"{name}.png"), optimize=True)
        seed += 1
    for key, (top, bottom) in HAZARDS.items():
        hazard(top, bottom, seed).save(os.path.join(OUT, f"hazard_{key}.png"), optimize=True)
        seed += 1
    for i, ch in enumerate(LETTERS):
        painted(ch, (256, 256), seed, max_font=240).save(os.path.join(OUT, f"sector_{ch}.png"), optimize=True)
        seed += 1
    for key, text in SECTORS.items():
        painted(text, (1024, 160), seed, max_font=130).save(os.path.join(OUT, f"sector_name_{key}.png"), optimize=True)
        seed += 1
    for n in range(0, 6):
        label = "B" if n == 0 else str(n)
        painted(label, (256, 256), seed, color=(0.78, 0.66, 0.2), max_font=240).save(
            os.path.join(OUT, f"storey_{n}.png"), optimize=True)
        seed += 1
    for i, p in enumerate(POSTERS):
        poster(p[:3], p[3], seed + i).save(os.path.join(OUT, f"poster_{i}.png"), optimize=True)
    print("signs:", len(os.listdir(OUT)), "files in", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
