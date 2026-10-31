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
    python3 tools/prepare_export_data.py --resume --png8  # continue a Web build

The destination is deliberately ignored by the editor through .gdignore:
Godot must not import ~1.5 GB of PNGs as .ctex resources; they are decoded
from the packed PCK at runtime instead.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
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


def is_webp(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            head = handle.read(12)
    except OSError:
        return False
    return head[:4] == b"RIFF" and head[8:12] == b"WEBP"


def is_png8(path: Path) -> bool:
    """True for a palette (indexed) PNG, the web-safe compressed form."""
    try:
        with path.open("rb") as handle:
            head = handle.read(33)
    except OSError:
        return False
    # PNG signature + IHDR chunk: colour type is byte 25, 3 = indexed.
    return head[:8] == b"\x89PNG\r\n\x1a\n" and len(head) >= 26 \
        and head[25] == 3


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio-root", type=Path, default=None)
    parser.add_argument("--force", action="store_true",
                        help="delete factorio_data first and rebuild from scratch")
    parser.add_argument("--resume", action="store_true",
                        help="keep factorio_data and skip files already staged/converted")
    parser.add_argument("--clean", action="store_true",
                        help="alias for --force")
    parser.add_argument("--webp", action="store_true",
                        help="re-encode PNGs as lossy WebP (desktop; Godot Web templates may not decode WebP)")
    parser.add_argument("--webp-quality", type=int, default=80,
                        help="WebP quality, 0-100 (default 80)")
    parser.add_argument("--png8", action="store_true",
                        help="quantize PNGs to palette PNG (web-safe, same dimensions)")
    parser.add_argument("--png8-colors", type=int, default=256,
                        help="palette size for --png8 (default 256)")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1),
                        help="parallel compression workers (default: up to 8)")
    args = parser.parse_args()

    root = args.factorio_root or configured_root()
    source = root / "data"
    if not (source / "base").is_dir() or not (source / "core").is_dir():
        print(f"error: Factorio base/core not found under {source}", file=sys.stderr)
        return 2

    if args.webp and args.png8:
        print("error: choose either --webp or --png8", file=sys.stderr)
        return 2
    if args.webp or args.png8:
        try:
            from PIL import Image
        except ImportError:
            print("error: texture compression needs Pillow (pip install pillow)",
                  file=sys.stderr)
            return 2

    if DEST.exists():
        if args.force or args.clean:
            shutil.rmtree(DEST)
        elif not args.resume:
            print(f"error: {DEST} already exists; pass --resume to continue "
                  "or --force to rebuild", file=sys.stderr)
            return 2
    (DEST / "data").mkdir(parents=True, exist_ok=True)

    mods = ("base", "core", "elevated-rails", "quality")
    # Count first so the progress line can show a real percentage; scanning
    # metadata is cheap compared with decoding thousands of PNGs.
    total = 0
    for mod in mods:
        src_mod = source / mod
        if not src_mod.is_dir():
            continue
        for src in src_mod.rglob("*"):
            if not src.is_file():
                continue
            suffix = src.suffix.lower()
            if suffix not in PAYLOAD_SUFFIXES and suffix not in (".ttf", ".otf"):
                continue
            if suffix in (".ttf", ".otf") and (src.parent.name != "fonts"
                    or src.name not in USED_FONTS):
                continue
            total += 1
    print(f"staging {total} files from {source} "
          f"({'WebP' if args.webp else ('PNG8' if args.png8 else 'original')})", flush=True)
    processed = 0
    skipped = 0
    webp_files = 0
    copied = 0
    started = time.monotonic()
    last_line = 0.0

    def progress(label: str, force: bool = False) -> None:
        nonlocal last_line
        now = time.monotonic()
        if not force and now - last_line < 0.2:
            return
        last_line = now
        percent = 100.0 * processed / max(1, total)
        elapsed = now - started
        rate = processed / elapsed if elapsed > 0.0 else 0.0
        remaining = (total - processed) / rate if rate > 0.1 else 0.0
        eta = f"ETA {remaining / 60:4.1f}m" if remaining > 0.0 else "ETA   -  "
        print(f"\r[{processed}/{total}] {percent:5.1f}%  "
              f"{rate:5.1f} files/s  {eta}  compressed={webp_files} "
              f"copied={copied} skipped={skipped}  {label:<44}",
              end="", flush=True)

    def convert_webp(src: Path, dst: Path, rel: str) -> tuple[str, str, str]:
        tmp = dst.with_name(dst.name + ".tmp")
        try:
            with Image.open(src) as image:
                rgba = image.convert("RGBA")
                if args.png8:
                    rgba.quantize(colors=args.png8_colors,
                                  method=Image.Quantize.FASTOCTREE).save(
                                      tmp, "PNG", optimize=True)
                else:
                    rgba.save(tmp, "WEBP", quality=args.webp_quality,
                              method=4)
            # Atomic on the same filesystem: an interrupted build never leaves
            # a half-written file that a later --resume would skip.
            os.replace(tmp, dst)
        except Exception as exc:
            try:
                tmp.unlink()
            except OSError:
                pass
            return rel, "error", str(exc)
        return rel, "compressed", ""

    executor = ThreadPoolExecutor(max_workers=max(1, args.jobs)) \
        if (args.webp or args.png8) else None
    futures: dict = {}
    try:
        for mod in mods:
            src_mod = source / mod
            if not src_mod.is_dir():
                print(f"warning: missing data/{mod}", file=sys.stderr)
                continue
            dst_mod = DEST / "data" / mod
            dst_mod.mkdir(parents=True, exist_ok=True)
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
                rel = f"{mod}/{src.relative_to(src_mod)}"
                if dst.exists():
                    # Resume: a previous run (or an interrupted WebP pass)
                    # already produced this file.  Do not decode it again,
                    # unless it is an old original PNG and WebP was requested.
                    if args.webp and suffix == ".png" and not is_webp(dst):
                        dst.unlink()
                    elif args.png8 and suffix == ".png" and not is_png8(dst):
                        dst.unlink()
                    else:
                        skipped += 1
                        processed += 1
                        progress(rel)
                        continue
                if (args.webp or args.png8) and suffix == ".png":
                    future = executor.submit(convert_webp, src, dst, rel)
                    futures[future] = (src, dst, rel)
                else:
                    link_or_copy(src, dst)
                    copied += 1
                    processed += 1
                    progress(rel)

        for future in as_completed(futures):
            rel, status, error = future.result()
            processed += 1
            if status == "compressed":
                webp_files += 1
            else:
                src, dst, _ = futures[future]
                print(f"\nwarning: webp failed for {rel}: {error}",
                      file=sys.stderr, flush=True)
                if dst.exists():
                    dst.unlink()
                link_or_copy(src, dst)
                copied += 1
            progress(rel)
    finally:
        if executor is not None:
            executor.shutdown(wait=True)

    progress("done", force=True)
    print(flush=True)
    print(f"staging finished in {time.monotonic() - started:.1f}s: "
          f"{copied} copied, {webp_files} compressed, {skipped} skipped",
          flush=True)

    # Sentinel checked by Prototypes: the bundled tree is authoritative even
    # inside a PCK where directory probing can be unreliable.
    (DEST / "packed_data.marker").write_text("openfactory packed factorio data\n",
                                       encoding="utf-8")
    print(f"ready: {DEST} ({sum(1 for _ in DEST.rglob('*') if _.is_file())} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
