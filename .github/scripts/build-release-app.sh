#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="${APP_NAME:-MineScene}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-minescene}"
RELEASE_VERSION="${RELEASE_VERSION:-dev}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-macos-$RELEASE_VERSION.zip"

sanitize_bundle_id() {
  printf '%s' "${1}" | tr '[:upper:]/_' '[:lower:]..' | tr -cd 'a-z0-9.-'
}

compile_shaders() {
  local shader_compiler
  shader_compiler="$(command -v glslangValidator || true)"
  local shader_dir="$ROOT_DIR/Shaders"
  local spirv_dir="$shader_dir/SPIRV"

  mkdir -p "$spirv_dir"

  if [[ -z "$shader_compiler" ]]; then
    local required_outputs=(
      "$spirv_dir/colour2D.vert.spv"
      "$spirv_dir/colour2D.frag.spv"
      "$spirv_dir/colour3D.vert.spv"
      "$spirv_dir/colour3D.frag.spv"
    )
    local output
    for output in "${required_outputs[@]}"; do
      if [[ ! -f "$output" ]]; then
        echo "Missing $output and glslangValidator is not available." >&2
        exit 1
      fi
    done
    return
  fi

  "$shader_compiler" -V -D -S vert -e mainVS -o "$spirv_dir/colour2D.vert.spv" "$shader_dir/colour2D.slang"
  "$shader_compiler" -V -D -S frag -e mainPS -o "$spirv_dir/colour2D.frag.spv" "$shader_dir/colour2D.slang"
  "$shader_compiler" -V -D -S vert -e mainVS -o "$spirv_dir/colour3D.vert.spv" "$shader_dir/colour3D.slang"
  "$shader_compiler" -V -D -S frag -e mainPS -o "$spirv_dir/colour3D.frag.spv" "$shader_dir/colour3D.slang"
}

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

find_brew_prefix() {
  local formula="$1"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2"
    return
  fi

  local brew_bin
  brew_bin="$(command -v brew || true)"
  if [[ -z "$brew_bin" ]]; then
    echo "Homebrew is required to locate $formula." >&2
    exit 1
  fi

  "$brew_bin" --prefix "$formula"
}

find_first_existing() {
  local candidate
  for candidate in "$@"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

compile_shaders

swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"

APP_CONTENTS="$APP_PATH/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_VULKAN_DIR="$APP_RESOURCES/vulkan/icd.d"
APP_EXECUTABLE="$APP_MACOS/$EXECUTABLE_NAME"

rm -rf "$APP_PATH"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES" "$APP_VULKAN_DIR"
mkdir -p "$APP_RESOURCES/Shaders"

cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_EXECUTABLE"
cp -R "$BIN_DIR/SDL3.framework" "$APP_FRAMEWORKS/"
cp -R "$ROOT_DIR/Shaders/SPIRV" "$APP_RESOURCES/Shaders/"

VULKAN_LOADER_PREFIX="$(find_brew_prefix vulkan-loader "${VULKAN_LOADER_PREFIX:-}")"
MOLTENVK_PREFIX="$(find_brew_prefix molten-vk "${MOLTENVK_PREFIX:-}")"
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix)}"

VULKAN_LOADER_SOURCE="$(
  find_first_existing \
    "$VULKAN_LOADER_PREFIX/lib/libvulkan.1.dylib" \
    "$HOMEBREW_PREFIX/lib/libvulkan.1.dylib" \
    "$(find "$HOMEBREW_PREFIX/Cellar" \( -path '*/lib/libvulkan.1.dylib' -o -path '*/lib/libvulkan*.dylib' \) 2>/dev/null | head -n 1)"
)"
MOLTENVK_SOURCE="$(
  find_first_existing \
    "$MOLTENVK_PREFIX/lib/libMoltenVK.dylib" \
    "$HOMEBREW_PREFIX/lib/libMoltenVK.dylib" \
    "$(find "$HOMEBREW_PREFIX/Cellar" -path '*/lib/libMoltenVK.dylib' 2>/dev/null | head -n 1)"
)"
MOLTENVK_ICD_SOURCE="$(
  find_first_existing \
    "$MOLTENVK_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json" \
    "$MOLTENVK_PREFIX/etc/vulkan/icd.d/MoltenVK_icd.json" \
    "$HOMEBREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json" \
    "$HOMEBREW_PREFIX/etc/vulkan/icd.d/MoltenVK_icd.json" \
    "$(find "$HOMEBREW_PREFIX/Cellar" -path '*/vulkan/icd.d/MoltenVK_icd.json' 2>/dev/null | head -n 1)"
)"

require_file "$VULKAN_LOADER_SOURCE"
require_file "$MOLTENVK_SOURCE"
require_file "$MOLTENVK_ICD_SOURCE"

cp -fL "$VULKAN_LOADER_SOURCE" "$APP_FRAMEWORKS/libvulkan.1.dylib"
cp -fL "$MOLTENVK_SOURCE" "$APP_FRAMEWORKS/libMoltenVK.dylib"
cp "$MOLTENVK_ICD_SOURCE" "$APP_VULKAN_DIR/MoltenVK_icd.json"

install_name_tool -id "@rpath/libvulkan.1.dylib" "$APP_FRAMEWORKS/libvulkan.1.dylib"
install_name_tool -id "@rpath/libMoltenVK.dylib" "$APP_FRAMEWORKS/libMoltenVK.dylib"

if otool -L "$APP_EXECUTABLE" | grep -Fq "$VULKAN_LOADER_SOURCE"; then
  install_name_tool -change "$VULKAN_LOADER_SOURCE" "@rpath/libvulkan.1.dylib" "$APP_EXECUTABLE"
fi

if otool -L "$APP_EXECUTABLE" | grep -Fq "$MOLTENVK_SOURCE"; then
  install_name_tool -change "$MOLTENVK_SOURCE" "@rpath/libMoltenVK.dylib" "$APP_EXECUTABLE"
fi

python3 -c 'import json, pathlib, sys; path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data["ICD"]["library_path"] = "../../../Frameworks/libMoltenVK.dylib"; path.write_text(json.dumps(data, indent=4) + "\n")' \
  "$APP_VULKAN_DIR/MoltenVK_icd.json"

if ! otool -l "$APP_EXECUTABLE" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_EXECUTABLE"
fi

SANITIZED_REPOSITORY="$(sanitize_bundle_id "${GITHUB_REPOSITORY:-minescene/minescene}")"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.github.$SANITIZED_REPOSITORY}"

cat > "$APP_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$RELEASE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$RELEASE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_PATH"

rm -f "$ZIP_PATH"
mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Created $APP_PATH"
echo "Created $ZIP_PATH"
