#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="$(pwd)"
STAGE="$PROJECT/.export_stage"

cleanup() {
    rm -rf "$STAGE"
}
trap cleanup EXIT

python3 tools/prepare_export_data.py --force
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
copy_optional .godot
copy_tree icon.svg
copy_optional icon.svg.import
copy_tree export_presets.cfg

# MCP is an editor-only development helper; Android does not need it.
sed -i '/^_mcp_game_helper=/d; /^\[editor_plugins\]/,/^$/d' \
    "$STAGE/project.godot"
rm -f "$STAGE/export_presets.cfg"
cat > "$STAGE/export_presets.cfg" <<'CFG'
[runnable_presets]

Android="Android"

[preset.0]

name="Android"
platform="Android"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="factorio_data/*,assets/data/*"
exclude_filter="tmp_preview/*,tools/*,build/*,.export_stage/*"
export_path="build/OpenFactory-debug.apk"
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
gradle_build/use_gradle_build=false
gradle_build/gradle_build_directory=""
gradle_build/android_source_template=""
gradle_build/compress_native_libraries=false
gradle_build/export_format=0
gradle_build/min_sdk=""
gradle_build/target_sdk=""
gradle_build/custom_theme_attributes={}
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="1.0.0"
package/unique_name="com.example.openfactory"
package/name="OpenFactory"
permissions/internet=true
permissions/access_network_state=true
package/signed=true
package/app_category=2
package/retain_data_on_uninstall=false
package/exclude_from_recents=false
package/show_in_android_tv=false
package/show_in_app_library=true
package/show_as_launcher_app=false
launcher_icons/main_192x192=""
launcher_icons/adaptive_foreground_432x432=""
launcher_icons/adaptive_background_432x432=""
launcher_icons/adaptive_monochrome_432x432=""
graphics/opengl_debug=false
shader_baker/enabled=false
xr_features/xr_mode=0
gesture/swipe_to_dismiss=false
screen/immersive_mode=true
screen/edge_to_edge=false
screen/support_small=true
screen/support_normal=true
screen/support_large=true
screen/support_xlarge=true
screen/background_color=Color(0, 0, 0, 1)
splash_screen/disable_godot_boot_splash=false
splash_screen/icon=""
CFG

mkdir -p "$PROJECT/build"
rm -f "$PROJECT/build/OpenFactory-debug.apk"
godot --headless --path "$STAGE" --export-debug "Android" \
    "$PROJECT/build/OpenFactory-debug.apk"
ls -lh "$PROJECT/build/OpenFactory-debug.apk"
