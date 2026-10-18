#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# 1. Put Factorio's base/core data into factorio_data/ as opaque *.bin files.
#    Hard-links are used when the filesystem allows it, so staging is cheap.
python3 tools/prepare_export_data.py --force

# 2. Export one self-contained Windows executable.  The preset embeds the PCK.
mkdir -p build
godot --headless --path . --export-release "Windows Desktop" build/OpenFactory.exe

ls -lh build/OpenFactory.exe
