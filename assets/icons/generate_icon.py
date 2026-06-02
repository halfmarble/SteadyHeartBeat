#!/usr/bin/env python3
"""Regenerate iOS app-icon set from `app_icon_source.png`.

Reads `assets/icons/app_icon_source.png` (any size, any aspect ratio),
pads it to a black square, resizes to 1024x1024 as `assets/icons/app_icon.png`
(the master we render previews against), then stamps every Xcode-required
size into `ios/Runner/Assets.xcassets/AppIcon.appiconset/` driven by the
filenames listed in that folder's `Contents.json`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "assets" / "icons" / "app_icon_source.png"
MASTER = REPO / "assets" / "icons" / "app_icon.png"
ICONSET = REPO / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
CONTENTS = ICONSET / "Contents.json"


def pad_to_square(im: Image.Image) -> Image.Image:
    """Pad to square with black so non-square sources render centered."""
    w, h = im.size
    side = max(w, h)
    bg = Image.new("RGBA", (side, side), (0, 0, 0, 255))
    bg.paste(im, ((side - w) // 2, (side - h) // 2), im if im.mode == "RGBA" else None)
    return bg


def _parse_filename(name: str) -> int:
    """Extract the rendered pixel size from filenames like
    'Icon-App-83.5x83.5@2x.png' (= round(83.5 * 2) = 167)."""
    m = re.search(r"-([\d.]+)x[\d.]+@(\d+)x\.png$", name)
    if not m:
        raise ValueError(f"unparseable icon filename: {name}")
    base = float(m.group(1))
    scale = int(m.group(2))
    return round(base * scale)


def main() -> int:
    if not SRC.exists():
        print(f"missing source: {SRC}", file=sys.stderr)
        return 1
    if not CONTENTS.exists():
        print(f"missing Contents.json: {CONTENTS}", file=sys.stderr)
        return 1

    src = Image.open(SRC).convert("RGBA")
    squared = pad_to_square(src)
    # Flatten to RGB (drop the alpha channel). pad_to_square already composited
    # onto opaque black, so this is visually lossless — and Apple rejects any
    # alpha channel on the 1024 marketing icon ("can't be transparent or
    # contain an alpha channel"). Deriving every size from an RGB master keeps
    # the whole icon set alpha-free.
    master = squared.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    master.save(MASTER, "PNG")
    print(f"wrote {MASTER.relative_to(REPO)} (1024x1024)")

    contents = json.loads(CONTENTS.read_text())
    # Collect unique filenames so we don't redo size variants that share a name.
    filenames: set[str] = {entry["filename"] for entry in contents["images"]}
    for name in sorted(filenames):
        px = _parse_filename(name)
        img = master.resize((px, px), Image.LANCZOS)
        img.save(ICONSET / name, "PNG")
        print(f"  {name}  {px}x{px}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
