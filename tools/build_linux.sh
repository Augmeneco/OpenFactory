#!/usr/bin/env bash
# Build the Linux executable.  WebP textures are optional and cut the PCK:
#
#   tools/build_linux.sh
#   tools/build_linux.sh --webp
#   tools/build_linux.sh --webp --webp-quality 70 --jobs 8
#   tools/build_linux.sh --webp --clean     # throw away staging first
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="$(pwd)"
STAGE="$PROJECT/.export_stage"
WEBP_ARGS=()
PREP_MODE=(--resume)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --webp)
            WEBP_ARGS+=(--webp)
            shift
            ;;
        --clean)
            PREP_MODE=(--force)
            shift
            ;;
        --webp-quality)
            if [ "$#" -lt 2 ]; then
                echo "error: --webp-quality needs a number" >&2
                exit 2
            fi
            WEBP_ARGS+=(--webp --webp-quality "$2")
            shift 2
            ;;
        --jobs)
            if [ "$#" -lt 2 ]; then
                echo "error: --jobs needs a number" >&2
                exit 2
            fi
            WEBP_ARGS+=(--jobs "$2")
            shift 2
            ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

cleanup() {
    rm -rf "$STAGE"
}
trap cleanup EXIT

# Stage only files that belong in the shipped game.  Exporting directly from
# the repository would also pick up tmp_preview/, tools/ and build/ on this
# Godot version's Linux exporter.
python3 tools/prepare_export_data.py "${PREP_MODE[@]}" "${WEBP_ARGS[@]}"
rm -rf "$STAGE"
mkdir -p "$STAGE"

copy_tree() {
    local src="$1"
    cp -al "$src" "$STAGE/" 2>/dev/null || cp -a "$src" "$STAGE/"
}
copy_optional() {
    if [ -e "$1" ]; then
        copy_tree "$1"
    fi
}
copy_tree project.godot
copy_tree scenes
copy_tree src
copy_tree assets
copy_tree factorio_data
# .godot and *.import are git-ignored generated metadata.  Use them when a
# local editor cache exists, but a fresh clone must build without them.
copy_optional .godot
copy_tree icon.svg
copy_optional icon.svg.import
copy_tree export_presets.cfg

# The MCP helper is an editor/debug tool, not part of a release binary.
sed -i '/^_mcp_game_helper=/d; /^\[editor_plugins\]/,/^$/d' \
    "$STAGE/project.godot"

# Never trust a stale editor-normalized preset for the filtered pack: write
# the release preset inside the clean stage itself.  The copied file is a
# hard-link, so remove it first or this write would modify the repository copy.
rm -f "$STAGE/export_presets.cfg"
cat > "$STAGE/export_presets.cfg" <<'CFG'
[runnable_presets]

Linux="Linux"

[preset.0]

name="Linux"
platform="Linux"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="factorio_data/*,assets/data/*"
exclude_filter="tmp_preview/*,tools/*,build/*,.export_stage/*"
export_path="build/OpenFactory.x86_64"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=true
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
binary_format/architecture="x86_64"
CFG

mkdir -p "$PROJECT/build"
rm -f "$PROJECT/build/OpenFactory.x86_64"
godot --headless --path "$STAGE" --export-release "Linux" \
    "$PROJECT/build/OpenFactory.x86_64"
chmod +x "$PROJECT/build/OpenFactory.x86_64"

ls -lh "$PROJECT/build/OpenFactory.x86_64"
