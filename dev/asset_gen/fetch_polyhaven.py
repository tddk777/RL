#!/usr/bin/env python3
"""Downloads the CC0 textures and models RL uses from Poly Haven
(https://polyhaven.com, all assets CC0: free for any use, no credit needed,
credited anyway in CREDITS.md and assets/third_party/polyhaven/SOURCES.md).

    python3 dev/asset_gen/fetch_polyhaven.py            # everything in the manifest
    python3 dev/asset_gen/fetch_polyhaven.py textures   # or: models

Safe by construction: only files the Poly Haven API lists for an asset, only
from dl.polyhaven.org, only image (.jpg/.png) and glTF (.gltf/.bin) files,
each checked against the MD5 the API gives. Nothing is executed or unpacked.
Files already present with the right checksum are skipped.

Writes into the repo (on the developer's machine that is E:\\Projects\\RL);
no cache anywhere else.
"""
from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "third_party" / "polyhaven"
API = "https://api.polyhaven.com"
ALLOWED_HOST = "https://dl.polyhaven.org/"
ALLOWED_EXT = (".jpg", ".png", ".gltf", ".bin")

# Textures: local folder name -> Poly Haven id. Maps fetched at TEX_RES.
TEXTURES = {
    "concrete_floor_02": "concrete_floor_02",
    "concrete_layers_02": "concrete_layers_02",
    "dirty_concrete": "dirty_concrete",
    "brick_wall_09": "brick_wall_09",
    "plastered_wall_04": "plastered_wall_04",
    "painted_plaster_wall": "painted_plaster_wall",
    "corrugated_iron_02": "corrugated_iron_02",
    "rusty_metal_04": "rusty_metal_04",
    "rusty_metal_02": "rusty_metal_02",
    "old_wood_floor": "old_wood_floor",
    "floor_tiles_08": "floor_tiles_08",
    "dirty_tiles": "dirty_tiles",
    "asphalt_02": "asphalt_02",
    "gravel_ground_01": "gravel_ground_01",
    "withered_grass": "withered_grass",
    "dry_ground_rocks": "dry_ground_rocks",
}
TEX_RES = "2k"
# API map name -> local file name (height only kept where something uses it).
TEX_MAPS = {"Diffuse": "albedo", "nor_gl": "normal", "Rough": "roughness", "Displacement": "height"}
NEEDS_HEIGHT: set[str] = set()  # nothing uses height maps yet

# Models, fetched as glTF at MODEL_RES (with their textures)
# (levels/procgen/model_props.gd says how each is used). Left out on purpose:
# things that read as loot (ammo_box, medical_box, russian_food_cans_01) until
# loot is designed.
MODELS = [
    "Barrel_01", "Barrel_02", "barrel_03", "cardboard_box_01", "metal_tool_chest", "metal_toolbox",
    "steel_frame_shelves_01", "steel_frame_shelves_02", "worn_metal_rack", "metal_office_desk", "SchoolChair_01",
    "WetFloorSign_01", "fire_alarm", "power_box_01", "utility_box_01", "utility_box_02", "hand_truck", "tool_cart",
    "industrial_storage_cart", "cement_bag", "metal_trash_can", "old_tyre", "concrete_road_barrier",
    "ladder_sectioned_01", "bench_vice_01", "portable_generator", "drill_press_01", "metal_stool_01", "security_camera_01",
]
MODEL_RES = "1k"


def get(url: str) -> bytes:
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "RL-asset-fetch"}), timeout=60) as r:
                return r.read()
        except Exception as e:  # network hiccup: back off and retry
            if attempt == 3:
                raise
            print(f"  retry {url}: {e}")
            time.sleep(2 ** (attempt + 1))
    return b""


def fetch_file(url: str, md5: str, dest: Path, shrink: int = 0) -> None:
    """Downloads url to dest after checking its MD5. `shrink` re-encodes an
    image to keep the repo small (JPEG quality 85, at most `shrink` px); the
    source checksum is kept beside it (.src_md5) so reruns skip it."""
    if not url.startswith(ALLOWED_HOST) or not url.lower().endswith(ALLOWED_EXT):
        raise SystemExit(f"refusing {url}")
    stamp = dest.with_suffix(dest.suffix + ".src_md5")
    if dest.exists() and ((stamp.exists() and stamp.read_text().strip() == md5)
                          or hashlib.md5(dest.read_bytes()).hexdigest() == md5):
        return
    data = get(url)
    if hashlib.md5(data).hexdigest() != md5:
        raise SystemExit(f"checksum mismatch for {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if shrink and dest.suffix == ".jpg":
        import io
        from PIL import Image
        im = Image.open(io.BytesIO(data))
        if max(im.size) > shrink:
            im = im.resize((shrink, shrink * im.size[1] // im.size[0]), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=85, optimize=True)
        data = buf.getvalue()
        stamp.write_text(md5)
    dest.write_bytes(data)
    print(f"  {dest.relative_to(ROOT)} ({len(data) // 1024} KB)")


def info(asset: str) -> dict:
    return json.loads(get(f"{API}/info/{asset}"))


def fetch_texture(local: str, asset: str) -> dict:
    files = json.loads(get(f"{API}/files/{asset}"))
    for api_map, name in TEX_MAPS.items():
        if name == "height" and local not in NEEDS_HEIGHT:
            continue
        entry = files[api_map][TEX_RES]
        f = entry.get("jpg") or entry.get("png")
        ext = ".jpg" if "jpg" in entry else ".png"
        # Colour re-encoded at full size, roughness and height at half
        # (normals left as they are: JPEG artefacts show in the shading).
        shrink = {"albedo": 4096, "roughness": 1024, "height": 1024}.get(name, 0)
        fetch_file(f["url"], f["md5"], OUT / "textures" / local / (name + ext), shrink)
    return info(asset)


def fetch_model(asset: str) -> dict:
    files = json.loads(get(f"{API}/files/{asset}"))
    g = files["gltf"][MODEL_RES]["gltf"]
    base = OUT / "models" / asset
    fetch_file(g["url"], g["md5"], base / f"{asset}.gltf")
    for rel, f in g.get("include", {}).items():
        if ".." in rel or rel.startswith("/"):
            raise SystemExit(f"refusing path {rel}")
        # Colour and AO/roughness/metal maps re-encoded (same size and name);
        # normals as they come.
        shrink = 0 if "_nor_" in rel or not rel.endswith(".jpg") else 4096
        fetch_file(f["url"], f["md5"], base / rel, shrink)
    return info(asset)


def main() -> None:
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    sources_path = OUT / "sources.json"
    sources = json.loads(sources_path.read_text()) if sources_path.exists() else {}
    if which in ("all", "textures"):
        for local, asset in TEXTURES.items():
            print("texture", asset)
            i = fetch_texture(local, asset)
            sources[asset] = {"kind": "texture", "folder": f"textures/{local}", "authors": list(i.get("authors", {})),
                              "dimensions_mm": i.get("dimensions"), "url": f"https://polyhaven.com/a/{asset}"}
    if which in ("all", "models"):
        for asset in MODELS:
            print("model", asset)
            i = fetch_model(asset)
            sources[asset] = {"kind": "model", "folder": f"models/{asset}", "authors": list(i.get("authors", {})),
                              "dimensions_mm": i.get("dimensions"), "url": f"https://polyhaven.com/a/{asset}"}
    OUT.mkdir(parents=True, exist_ok=True)
    sources_path.write_text(json.dumps(sources, indent=1, sort_keys=True))
    lines = ["# Poly Haven assets", "", "All CC0 1.0 (https://polyhaven.com/license). Fetched by dev/asset_gen/fetch_polyhaven.py.", "",
             "| Asset | Kind | Authors | Source |", "|---|---|---|---|"]
    for asset, s in sorted(sources.items()):
        lines.append(f"| {asset} | {s['kind']} | {', '.join(s['authors'])} | {s['url']} |")
    (OUT / "SOURCES.md").write_text("\n".join(lines) + "\n")
    print("done:", len(sources), "assets")


if __name__ == "__main__":
    main()
