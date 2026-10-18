#!/usr/bin/env python3
"""Convert the Factorio prototype dump into game-ready data for OpenFactory.

Inputs (produced by ``extract.sh``):
  dump/data-raw-dump.json   -- full ``data.raw`` prototype database
  ../factorio/doc-html/runtime-api.json -- API docs, source of the ``defines`` enums

Outputs (under ``<project>/assets/data``):
  manifest.json             -- prototype index + provenance
  defines.json              -- ``defines.*`` enum values
  prototypes/<type>.json    -- one file per prototype type
  locale/<lang>.json        -- merged locale dictionaries
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent.parent
DUMP = HERE / "dump"
FACTORIO_ROOT = Path(
    "/home/cha14ka/.steam/steam/steamapps/common/Factorio"
)
OUT = PROJECT / "assets" / "data"

LANGS = ("en", "ru")

# Prototype types that only exist to accelerate Factorio's own renderer or
# tutorial UI.  They carry no simulation data and cost ~2.7 MB, so they are
# dropped.  Noise data IS kept: it drives authentic map generation.
SKIP_TYPES = {
    "optimized-particle",
    "optimized-decorative",
    "ambient-sound",
    "tips-and-tricks-item",
    "tips-and-tricks-item-category",
}


# --------------------------------------------------------------------------
# locale .cfg parsing
# --------------------------------------------------------------------------

# Factorio locale files are INI-ish: ``[section]`` headers, ``key=value``
# lines, ``#``/``;`` comments.  Values keep their literal ``\n`` escapes.
_SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")


def parse_locale_file(path: Path, into: dict[str, str]) -> None:
    section = None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        m = _SECTION_RE.match(line)
        if m:
            section = m.group(1)
            continue
        if section is None or "=" not in line:
            continue
        key, _, value = line.partition("=")
        into[f"{section}.{key.strip()}"] = value


def parse_locale(lang: str) -> dict[str, str]:
    table: dict[str, str] = {}
    for mod_dir in sorted(FACTORIO_ROOT.joinpath("data").iterdir()):
        if not mod_dir.is_dir():
            continue
        loc = mod_dir / "locale" / lang
        if not loc.is_dir():
            continue
        for cfg in sorted(loc.glob("*.cfg")):
            parse_locale_file(cfg, table)
    return table


# --------------------------------------------------------------------------
# defines extraction
# --------------------------------------------------------------------------


def build_defines() -> dict[str, dict[str, int]]:
    api = json.loads((FACTORIO_ROOT / "doc-html" / "runtime-api.json").read_text())
    out: dict[str, dict[str, int]] = {}
    for enum in api["defines"]:
        values = {}
        for value in enum.get("values", []):
            order = value.get("order")
            if order is not None:
                values[value["name"]] = order
        if values:
            out[enum["name"]] = values
    return out


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    raw = json.loads((DUMP / "data-raw-dump.json").read_text())

    proto_dir = OUT / "prototypes"
    proto_dir.mkdir(parents=True, exist_ok=True)

    index: dict[str, dict] = {}
    skipped: list[str] = []
    written: list[Path] = []

    for ptype, entries in sorted(raw.items()):
        if ptype in SKIP_TYPES:
            skipped.append(ptype)
            continue
        if not isinstance(entries, dict):
            skipped.append(ptype)
            continue
        # Compact JSON: these files are machine-read only.
        payload = json.dumps(entries, ensure_ascii=False, separators=(",", ":"))
        path = proto_dir / f"{ptype}.json"
        path.write_text(payload, encoding="utf-8")
        written.append(path)
        index[ptype] = {"count": len(entries), "bytes": len(payload)}

    # Drop stale files from previous runs so the directory always mirrors the dump.
    for stale in proto_dir.glob("*.json"):
        if stale.stem not in index:
            stale.unlink()

    OUT.joinpath("defines.json").write_text(
        json.dumps(build_defines(), ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    loc_dir = OUT / "locale"
    loc_dir.mkdir(parents=True, exist_ok=True)
    locale_counts = {}
    for lang in LANGS:
        table = parse_locale(lang)
        loc_dir.joinpath(f"{lang}.json").write_text(
            json.dumps(table, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        locale_counts[lang] = len(table)

    mods = {}
    for mod_dir in sorted(FACTORIO_ROOT.joinpath("data").iterdir()):
        info = mod_dir / "info.json"
        if info.is_file():
            data = json.loads(info.read_text())
            mods[data.get("name", mod_dir.name)] = data.get("version", "")

    manifest = {
        "generated_at": int(time.time()),
        "factorio_root": str(FACTORIO_ROOT),
        "mods": mods,
        "proto_types": len(index),
        "proto_count": sum(v["count"] for v in index.values()),
        "types": index,
        "skipped_types": sorted(skipped),
        "locale_entries": locale_counts,
    }
    OUT.joinpath("manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
    )

    total_bytes = sum(p.stat().st_size for p in written)
    print(f"prototype types : {len(index)}")
    print(f"prototypes      : {manifest['proto_count']}")
    print(f"prototype bytes : {total_bytes / 1024 / 1024:.1f} MB")
    print(f"skipped types   : {', '.join(sorted(skipped)) or '-'}")
    print(f"locale entries  : {locale_counts}")
    print(f"output          : {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
