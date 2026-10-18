#!/usr/bin/env python3
"""Stage the Factorio data/ tree for a self-contained OpenFactory export.

The game normally reads sprites and sounds from the installed Factorio copy.
A distributable Windows build cannot rely on that path, so this script copies
(or hard-links, when possible) Factorio's base/ and core/ data into
``factorio_data/data``.  The exporter then packs those raw files into the exe.

Usage:
    python3 tools/prepare_export_data.py
    python3 tools/prepare_export_data.py --factorio-root /path/to/Factorio
    python3 tools/prepare_export_data.py --force

The destination is deliberately ignored by the editor through .gdignore:
Godot must not import ~1.5 GB of PNGs as .ctex resources; they are decoded
from the packed PCK at runtime instead.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
DEST = PROJECT / "factorio_data"
DEFAULT_ROOT = Path("/home/cha14ka/.steam/steam/steamapps/common/Factorio")


def configured_root() -> Path:
    project_file = PROJECT / "project.godot"
    try:
        text = project_file.read_text(encoding="utf-8")
    except OSError:
        return DEFAULT_ROOT
    for line in text.splitlines():
        if line.strip().startswith("factorio_root="):
            value = line.split("=", 1)[1].strip().strip('"')
            if value:
                return Path(value)
    return DEFAULT_ROOT


# Only files the renderer/audio UI actually loads are staged.  Factorio's
# data tree also contains Lua sources, shaders, docs, zip sound banks and many
# unused CJK fonts; none of those belong in the game executable.
PAYLOAD_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga",
    ".ogg", ".wav", ".mp3",
}
USED_FONTS = {"Lato-Regular.ttf", "Lato-Semibold.ttf", "Lato-Bold.ttf"}


def link_or_copy(src: Path, dst: Path) -> None:
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio-root", type=Path, default=None)
    parser.add_argument("--force", action="store_true",
                        help="replace an existing factorio_data directory")
    args = parser.parse_args()

    root = args.factorio_root or configured_root()
    source = root / "data"
    if not (source / "base").is_dir() or not (source / "core").is_dir():
        print(f"error: Factorio base/core not found under {source}", file=sys.stderr)
        return 2

    if DEST.exists():
        if not args.force:
            print(f"error: {DEST} already exists; pass --force to replace it",
                  file=sys.stderr)
            return 2
        shutil.rmtree(DEST)

    (DEST / "data").mkdir(parents=True)
    # base/core are required; elevated-rails and quality are referenced by some
    # base prototypes/icons but are small compared with space-age, which this
    # project deliberately filters out.
    for mod in ("base", "core", "elevated-rails", "quality"):
        src_mod = source / mod
        dst_mod = DEST / "data" / mod
        dst_mod.mkdir()
        files = 0
        for src in src_mod.rglob("*"):
            if not src.is_file():
                continue
            suffix = src.suffix.lower()
            is_font = suffix in (".ttf", ".otf")
            if suffix not in PAYLOAD_SUFFIXES and not is_font:
                continue
            if is_font and (src.parent.name != "fonts"
                    or src.name not in USED_FONTS):
                continue
            dst = dst_mod / src.relative_to(src_mod)
            dst = dst.with_name(dst.name + ".bin")
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists():
                continue
            link_or_copy(src, dst)
            files += 1
        print(f"staged data/{mod}: {files} files")

    # Sentinel checked by Prototypes: the bundled tree is authoritative even
    # inside a PCK where directory probing can be unreliable.
    (DEST / "packed_data.marker").write_text("openfactory packed factorio data\n",
                                       encoding="utf-8")
    print(f"ready: {DEST} ({sum(1 for _ in DEST.rglob('*') if _.is_file())} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
