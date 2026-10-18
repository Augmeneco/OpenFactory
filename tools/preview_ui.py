#!/usr/bin/env python3
"""Render an OpenFactory UI dump into a PNG.

The game can lay out one of its windows and write every control it contains
to JSON (see ``--dump-ui``).  This tool draws that list — 9-slice frames,
slot icons, labels with Factorio's own Lato font and progress bars — so the
interface can be reviewed on a machine without a GPU:

    godot --headless --path . -- --dump-ui res://tmp_preview/ui.json --ui-screen inventory
    python3 tools/preview_ui.py tmp_preview/ui.json tmp_preview/ui.png
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FACTORIO_ROOT = Path(
    os.environ.get(
        "FACTORIO_ROOT",
        "/home/cha14ka/.steam/steam/steamapps/common/Factorio",
    )
)
DATA_ROOT = FACTORIO_ROOT / "data"
PROJECT_ROOT = Path(__file__).resolve().parent.parent

_sheet_cache: dict[str, Image.Image | None] = {}
_font_cache: dict[int, ImageFont.FreeTypeFont] = {}


def load_sheet(reference: str, scale: float) -> Image.Image | None:
    key = f"{reference}@{scale}"
    if key in _sheet_cache:
        return _sheet_cache[key]
    if reference.startswith("res://"):
        path = PROJECT_ROOT / reference[len("res://"):]
    else:
        mod, _, rest = reference.partition("/")
        path = DATA_ROOT / mod.strip("_") / rest
    try:
        image = Image.open(path).convert("RGBA")
    except Exception:
        image = None
    if image is not None and scale != 1.0:
        image = image.resize(
            (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
            Image.LANCZOS,
        )
    _sheet_cache[key] = image
    return image


def load_font(size: int) -> ImageFont.FreeTypeFont:
    if size in _font_cache:
        return _font_cache[size]
    path = FACTORIO_ROOT / "data" / "core" / "fonts" / "Lato-Regular.ttf"
    try:
        font = ImageFont.truetype(str(path), size)
    except Exception:
        font = ImageFont.load_default()
    _font_cache[size] = font
    return font


def nine_slice(sheet: Image.Image, region, margins, size) -> Image.Image:
    """Cut a 9-slice out of a sheet and stretch it to ``size``."""
    x, y, w, h = (int(round(v)) for v in region)
    x = max(0, min(x, sheet.width - 1))
    y = max(0, min(y, sheet.height - 1))
    w = max(1, min(w, sheet.width - x))
    h = max(1, min(h, sheet.height - y))
    patch = sheet.crop((x, y, x + w, y + h))

    ml, mt, mr, mb = (int(round(v)) for v in margins)
    ml = max(0, min(ml, w - 1))
    mt = max(0, min(mt, h - 1))
    mr = max(0, min(mr, w - ml - 1))
    mb = max(0, min(mb, h - mt - 1))

    out_w = max(1, int(round(size[0])))
    out_h = max(1, int(round(size[1])))
    result = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))

    # Source columns/rows of the 9-slice.
    cols = [(0, ml), (ml, w - mr), (w - mr, w)]
    rows = [(0, mt), (mt, h - mb), (h - mb, h)]
    dest_cols = [(0, ml), (ml, out_w - mr), (out_w - mr, out_w)]
    dest_rows = [(0, mt), (mt, out_h - mb), (out_h - mb, out_h)]

    for row in range(3):
        for col in range(3):
            sx0, sx1 = cols[col]
            sy0, sy1 = rows[row]
            dx0, dx1 = dest_cols[col]
            dy0, dy1 = dest_rows[row]
            if sx1 <= sx0 or sy1 <= sy0 or dx1 <= dx0 or dy1 <= dy0:
                continue
            piece = patch.crop((sx0, sy0, sx1, sy1))
            if piece.size != (dx1 - dx0, dy1 - dy0):
                piece = piece.resize((dx1 - dx0, dy1 - dy0), Image.NEAREST)
            result.alpha_composite(piece, (dx0, dy0))
    return result


def apply_modulate(patch: Image.Image, modulate) -> Image.Image:
    r, g, b, a = modulate
    if (r, g, b, a) == (1.0, 1.0, 1.0, 1.0):
        return patch
    channels = list(patch.split())
    for index, factor in enumerate((r, g, b, a)):
        if factor == 1.0:
            continue
        table = [min(255, max(0, int(round(v * factor)))) for v in range(256)]
        channels[index] = channels[index].point(table)
    return Image.merge("RGBA", channels)


def draw_control(canvas: Image.Image, entry: dict) -> None:
    """Draw one control into its own layer so it can be clipped."""
    rect = entry["rect"]
    ox, oy = int(round(rect[0])), int(round(rect[1]))
    width, height = int(round(rect[2])), int(round(rect[3]))
    if width < 1 or height < 1:
        return

    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    texture = entry.get("texture", "")
    kind = entry.get("texture_kind", "sheet")

    # Controls that draw themselves (the technology tree's connectors) hand
    # their geometry over in the dump, since a picture of a _draw call cannot
    # be taken from the control list alone.
    for line in entry.get("overlay", []):
        points = [(float(p[0]) - ox, float(p[1]) - oy) for p in line.get("points", [])]
        if len(points) < 2:
            continue
        colour = line.get("color", [1, 1, 1, 1])
        rgba = tuple(int(round(c * 255)) for c in colour[:4])
        draw = ImageDraw.Draw(layer)
        draw.line(points, fill=rgba,
                  width=max(1, int(round(float(line.get("width", 2.0))))),
                  joint="curve")
        for point in (points[0], points[-1]):
            size = max(1, int(round(float(line.get("width", 2.0)))))
            draw.rectangle([point[0] - size, point[1] - size,
                            point[0] + size, point[1] + size], fill=rgba)

    if texture and entry.get("region"):
        sheet = load_sheet(texture, float(entry.get("sheet_scale", 1.0)))
        if sheet is not None:
            patch = nine_slice(sheet, entry["region"],
                               entry.get("margins", [0, 0, 0, 0]), (width, height))
            layer.alpha_composite(apply_modulate(patch, entry.get("modulate", [1, 1, 1, 1])))
    elif texture and kind == "picture":
        # A picture fills its control rather than sitting in the middle of it.
        path = (PROJECT_ROOT / texture[len("res://"):]) if texture.startswith("res://") \
            else Path(texture)
        try:
            picture = Image.open(path).convert("RGBA")
        except Exception:
            picture = None
        if picture is not None:
            if picture.size != (width, height):
                picture = picture.resize((width, height), Image.NEAREST)
            layer.alpha_composite(apply_modulate(picture, entry.get("modulate", [1, 1, 1, 1])), (0, 0))

    elif texture and kind == "icon":
        path = (PROJECT_ROOT / texture[len("res://"):]) if texture.startswith("res://") \
            else Path(texture)
        try:
            icon = Image.open(path).convert("RGBA")
        except Exception:
            icon = None
        if icon is not None:
            target = max(1, min(width, height))
            scale = target / max(icon.width, icon.height)
            icon = icon.resize((max(1, int(icon.width * scale)),
                                max(1, int(icon.height * scale))), Image.LANCZOS)
            layer.alpha_composite(apply_modulate(icon, entry.get("modulate", [1, 1, 1, 1])),
                                  ((width - icon.width) // 2, (height - icon.height) // 2))

    if entry.get("type") == "ProgressBar" and float(entry.get("value", 0.0)) > 0.0:
        draw = ImageDraw.Draw(layer)
        draw.rectangle([0, 0, int(width * float(entry["value"])), height],
                       fill=(90, 217, 90, 240))

    text = entry.get("text", "")
    if text:
        colour = tuple(int(round(c * 255)) for c in entry.get("color", [1, 1, 1, 1]))
        font = load_font(max(8, int(entry.get("font_size", 14))))
        draw = ImageDraw.Draw(layer)
        lines = text.split("\n")
        line_height = font.size + 2
        total = line_height * len(lines)
        start_y = (height - total) // 2
        if entry.get("valign") == "bottom":
            start_y = height - total
        elif entry.get("valign") == "top":
            start_y = 0
        for index, line in enumerate(lines):
            line_width = draw.textlength(line, font=font)
            x = 0
            if entry.get("align") == "center":
                x = (width - line_width) / 2
            elif entry.get("align") == "right":
                x = width - line_width
            draw.text((x, start_y + index * line_height), line, font=font, fill=colour)

    clip = entry.get("clip") or []
    if len(clip) == 4:
        cx0 = max(ox, int(round(clip[0])))
        cy0 = max(oy, int(round(clip[1])))
        cx1 = min(ox + width, int(round(clip[0] + clip[2])))
        cy1 = min(oy + height, int(round(clip[1] + clip[3])))
        if cx1 <= cx0 or cy1 <= cy0:
            return
        layer = layer.crop((cx0 - ox, cy0 - oy, cx1 - ox, cy1 - oy))
        canvas.alpha_composite(layer, (cx0, cy0))
        return
    canvas.alpha_composite(layer, (ox, oy))


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    dump = json.loads(Path(sys.argv[1]).read_text())
    out_path = Path(sys.argv[2])
    width, height = (int(round(v)) for v in dump["viewport"])

    canvas = Image.new("RGBA", (width, height), (26, 26, 28, 255))
    for entry in dump["controls"]:
        draw_control(canvas, entry)
    canvas.convert("RGB").save(out_path)
    print(f"rendered {len(dump['controls'])} controls -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
