#!/usr/bin/env bash
# Export OpenFactory for the browser (HTML5 / WebAssembly).
#
#   tools/build_web.sh                 # normal export
#   tools/build_web.sh --png8          # palette PNG compression (web-safe)
#   tools/build_web.sh --clean         # discard staged data and rebuild it
#   tools/build_web.sh --jobs 8        # parallel PNG8 workers
#   tools/build_web.sh --serve 8080    # build, then serve for testing
#
# Produces a self-contained folder under build/web that can be served by any
# static HTTP server:
#
#   tools/build_web.sh
#   tools/build_web.sh --serve 8080
#
# A static server is required: opening index.html with file:// cannot load the
# .wasm/.pck files.  The export uses Godot's single-threaded web template, so
# no COOP/COEP headers are needed.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="$(pwd)"
GODOT="${GODOT:-godot}"
STAGE="$PROJECT/.export_stage_web"
OUT="$PROJECT/build/web"
SERVE_PORT=""
COMPRESS_ARGS=()
PREP_MODE=(--resume)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --serve)
            if [ "$#" -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                SERVE_PORT="$2"
                shift 2
            else
                SERVE_PORT="8080"
                shift
            fi
            ;;
        --serve=*)
            SERVE_PORT="${1#--serve=}"
            shift
            ;;
        --png8)
            COMPRESS_ARGS+=(--png8)
            shift
            ;;
        --png8-colors)
            if [ "$#" -lt 2 ]; then
                echo "error: --png8-colors needs a number" >&2
                exit 2
            fi
            COMPRESS_ARGS+=(--png8 --png8-colors "$2")
            shift 2
            ;;
        --webp)
            # Godot's Web template does not ship the WebP decoder.  Keep the
            # old flag working, but use palette PNG instead of producing a
            # build whose textures all fail to load.
            echo "warning: WebP is not decoded by Godot Web templates; using PNG8" >&2
            COMPRESS_ARGS+=(--png8)
            shift
            ;;
        --clean)
            PREP_MODE=(--force)
            shift
            ;;
        --webp-quality)
            # Compatibility alias for old commands; WebP is not usable in a
            # Godot Web build, so use the web-safe palette PNG path.
            echo "warning: --webp-quality is ignored on Web; using PNG8" >&2
            COMPRESS_ARGS+=(--png8)
            shift 2
            ;;
        --jobs)
            if [ "$#" -lt 2 ]; then
                echo "error: --jobs needs a number" >&2
                exit 2
            fi
            COMPRESS_ARGS+=(--jobs "$2")
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v "$GODOT" >/dev/null 2>&1; then
    echo "error: '$GODOT' not found; set GODOT=/path/to/godot" >&2
    exit 2
fi

cleanup() {
    rm -rf "$STAGE"
}
trap cleanup EXIT

BUILD_STARTED=$(date +%s)
stage() {
    echo
    echo "==> [$1/4] $2  ($(date +%H:%M:%S))"
}

stage 1 "staging Factorio data (resume: converted files are skipped)"
python3 tools/prepare_export_data.py "${PREP_MODE[@]}" "${COMPRESS_ARGS[@]}"

stage 2 "copying project files"
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
# Imported metadata is generated; use it when the editor has populated it,
# but never require it for a fresh checkout.
copy_optional .godot
copy_tree icon.svg
copy_optional icon.svg.import

# The MCP helper is an editor/debug tool and must not be shipped.
sed -i '/^_mcp_game_helper=/d; /^\[editor_plugins\]/,/^$/d' \
    "$STAGE/project.godot"

# Web has to use the Compatibility renderer.  The feature override is active
# only for the web platform, so desktop builds keep their normal renderer.
python3 - "$STAGE/project.godot" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "rendering/renderer/rendering_method.web" not in text:
    text = text.replace(
        "[rendering]\n",
        '[rendering]\n\nrendering/renderer/rendering_method.web="gl_compatibility"\n',
        1,
    )
path.write_text(text, encoding="utf-8")
PY

# A filtered preset written inside the clean stage keeps tools/, tmp_preview/
# and the staging folder itself out of the PCK.  Web runs without threads by
# default; that keeps it servable from plain static hosting.
cat > "$STAGE/export_presets.cfg" <<'CFG'
[runnable_presets]

Web="Web"

[preset.0]

name="Web"
platform="Web"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="factorio_data/*,assets/data/*"
exclude_filter="tmp_preview/*,tools/*,build/*,.export_stage*/*"
export_path="build/web/index.html"
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
variant/extensions_support=false
variant/thread_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=false
html/export_icon=true
html/custom_html_shell=""
html/head_include=""
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
progressive_web_app/ensure_cross_origin_isolation_headers=false
progressive_web_app/offline_page=""
progressive_web_app/display=1
progressive_web_app/orientation=0
progressive_web_app/icon_144x144=""
progressive_web_app/icon_180x180=""
progressive_web_app/icon_512x512=""
progressive_web_app/background_color=Color(0, 0, 0, 1)
threads/emscripten_pool_size=8
threads/godot_pool_size=4
CFG

rm -rf "$OUT"
mkdir -p "$OUT"

stage 3 "exporting Web build (Godot writes its own progress below)"
"$GODOT" --headless --path "$STAGE" --export-release "Web" \
    "$OUT/index.html"

for required in index.html index.js index.wasm index.pck; do
    if [ ! -s "$OUT/$required" ]; then
        echo "error: export did not produce $OUT/$required" >&2
        exit 1
    fi
done

stage 4 "checking output"
echo
echo "==> build ready: $OUT (took $(( $(date +%s) - BUILD_STARTED ))s)"
du -sh "$OUT"
ls -lh "$OUT" | sed -n '1,20p'
echo
echo "Serve it over HTTP, for example:"
echo "  (cd build/web && python3 -m http.server ${SERVE_PORT:-8080})"
echo "Then open http://localhost:${SERVE_PORT:-8080}/"

if [ -n "$SERVE_PORT" ]; then
    cd "$OUT"
    exec python3 -m http.server "$SERVE_PORT"
fi
