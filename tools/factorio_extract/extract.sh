#!/usr/bin/env bash
# Refresh the Factorio prototype/locale dump used by OpenFactory.
#
# Runs the installed Factorio headless in an isolated config so nothing
# touches the player's real ~/.factorio profile, then copies the artifacts
# into tools/factorio_extract/dump/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORIO_ROOT="${FACTORIO_ROOT:-/home/cha14ka/.steam/steam/steamapps/common/Factorio}"
BIN="$FACTORIO_ROOT/bin/x64/factorio"

if [[ ! -x "$BIN" ]]; then
  echo "factorio binary not found at $BIN" >&2
  exit 1
fi

USER_DIR="$HERE/factorio-user"
mkdir -p "$USER_DIR"
cat > "$USER_DIR/config.ini" <<EOF
[path]
read-data=__PATH__executable__/../../data
write-data=$USER_DIR
EOF

echo "==> dumping data.raw"
"$BIN" --config "$USER_DIR/config.ini" --dump-data | tail -2

echo "==> dumping prototype locale"
"$BIN" --config "$USER_DIR/config.ini" --dump-prototype-locale | tail -2

mkdir -p "$HERE/dump/locale"
cp -f "$USER_DIR/script-output/data-raw-dump.json" "$HERE/dump/"
mv -f "$USER_DIR"/script-output/*-locale.json "$HERE/dump/locale/" 2>/dev/null || true

echo "==> done"
du -sh "$HERE/dump"
