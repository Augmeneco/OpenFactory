#!/usr/bin/env python3
"""Composite an OpenFactory draw dump into a PNG.

The game can emit the exact list of textured rectangles its renderer would
blit (see ``--dump-draw``).  This tool turns that list into an image, which
lets the visuals be verified on machines without a GPU:

    godot --headless --path . -- --dump-draw res://tmp_preview/draw.json --seed 12345
    python3 tools/preview_draw.py tmp_preview/draw.json tmp_preview/world.png
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw

FACTORIO_ROOT = Path(
    os.environ.get(
        "FACTORIO_ROOT",
        "/home/cha14ka/.steam/steam/steamapps/common/Factorio",
    )
)
DATA_ROOT = FACTORIO_ROOT / "data"
PROJECT_ROOT = Path(__file__).resolve().parent.parent

_image_cache: dict[str, Image.Image] = {}


def resolve(reference: str) -> Path:
    """``__base__/graphics/x.png`` -> absolute path in the Factorio install.

    ``res://`` references are composed textures the game wrote out itself.
    """
    if reference.startswith("res://"):
        return PROJECT_ROOT / reference[len("res://"):]
    mod, _, rest = reference.partition("/")
    return DATA_ROOT / mod.strip("_") / rest


def load(reference: str) -> Image.Image | None:
    path = resolve(reference)
    key = str(path)
    if key in _image_cache:
        return _image_cache[key]
    try:
        image = Image.open(path).convert("RGBA")
    except Exception:
        image = None
    _image_cache[key] = image
    return image


def clamp_rect(values: list[float], width: int, height: int) -> tuple[int, int, int, int]:
    x, y, w, h = (int(round(v)) for v in values)
    x = max(0, min(x, width - 1))
    y = max(0, min(y, height - 1))
    w = max(1, min(w, width - x))
    h = max(1, min(h, height - y))
    return x, y, w, h


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    dump_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    payload = json.loads(dump_path.read_text())
    view = payload["view"]
    zoom = float(payload["zoom"])
    canvas_w = max(1, int(round(view[2])))
    canvas_h = max(1, int(round(view[3])))
    origin_x, origin_y = view[0], view[1]

    canvas = Image.new("RGBA", (canvas_w, canvas_h), (12, 12, 14, 255))
    drawn = 0
    missing: dict[str, int] = {}

    for item in payload["items"]:
        # A wire is a line rather than a sprite.
        if item.get("line"):
            x0, y0, x1, y1, r, g, b = item["line"]
            draw = ImageDraw.Draw(canvas)
            draw.line(
                [(x0 - origin_x, y0 - origin_y), (x1 - origin_x, y1 - origin_y)],
                fill=(int(r * 255), int(g * 255), int(b * 255), 230), width=2)
            drawn += 1
            continue
        source = load(item["path"])
        if source is None:
            missing[item["path"]] = missing.get(item["path"], 0) + 1
            continue
        sx, sy, sw, sh = clamp_rect(item["src"], source.width, source.height)
        patch = source.crop((sx, sy, sx + sw, sy + sh))

        dx, dy, dw, dh = (int(round(v)) for v in item["dest"])
        dw = max(1, dw)
        dh = max(1, dh)
        if (dw, dh) != (sw, sh):
            patch = patch.resize((dw, dh), Image.NEAREST if zoom >= 1 else Image.BILINEAR)
        # (rotation is applied after the resize, above)

        rotation = float(item.get("rotation", 0.0))
        if abs(rotation) > 0.0001:
            # A rotated sprite is turned about its centre, the same way the
            # game does it, and re-fitted into a square big enough to hold it.
            patch = patch.rotate(-math.degrees(rotation), expand=True,
                                 resample=Image.NEAREST)

        r, g, b, a = item["modulate"]
        if (r, g, b, a) != (1.0, 1.0, 1.0, 1.0) and (r, g, b) != (1.0, 1.0, 1.0):
            channels = list(patch.split())
            for index, factor in enumerate((r, g, b, a)):
                if factor == 1.0:
                    continue
                table = [min(255, int(round(v * factor))) for v in range(256)]
                channels[index] = channels[index].point(table)
            patch = Image.merge("RGBA", channels)

        pos = (dx - int(round(origin_x)), dy - int(round(origin_y)))
        canvas.alpha_composite(patch, pos)
        drawn += 1

    # The time of day is an overlay in the game, so it is laid on here too.
    night = payload.get("night", [1, 1, 1, 0])
    if len(night) >= 4 and night[3] > 0:
        wash = Image.new("RGBA", canvas.size,
                         (int(night[0] * 255), int(night[1] * 255),
                          int(night[2] * 255), int(night[3] * 255)))
        canvas.alpha_composite(wash)
        print(f"night overlay at {night[3]:.2f} alpha")

    canvas.convert("RGB").save(out_path)
    print(f"composited {drawn}/{len(payload['items'])} items -> {out_path}")
    if missing:
        print(f"missing {len(missing)} distinct files, e.g. {list(missing)[:3]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
