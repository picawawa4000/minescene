#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="${APP_NAME:-MineScene}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-minescene}"
RELEASE_VERSION="${RELEASE_VERSION:-dev}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
PACKAGE_DIR="$DIST_DIR/$APP_NAME-linux-x86_64-$RELEASE_VERSION"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME-linux-x86_64-$RELEASE_VERSION.tar.gz"

compile_shaders() {
  local shader_compiler
  shader_compiler="$(command -v glslangValidator || true)"
  local shader_dir="$ROOT_DIR/Shaders"
  local spirv_dir="$shader_dir/SPIRV"

  mkdir -p "$spirv_dir"

  if [[ -z "$shader_compiler" ]]; then
    echo "glslangValidator is required to build Linux release shaders." >&2
    exit 1
  fi

  "$shader_compiler" -V -D -S vert -e mainVS -o "$spirv_dir/colour2D.vert.spv" "$shader_dir/colour2D.slang"
  "$shader_compiler" -V -D -S frag -e mainPS -o "$spirv_dir/colour2D.frag.spv" "$shader_dir/colour2D.slang"
  "$shader_compiler" -V -D -S vert -e mainVS -o "$spirv_dir/colour3D.vert.spv" "$shader_dir/colour3D.slang"
  "$shader_compiler" -V -D -S frag -e mainPS -o "$spirv_dir/colour3D.frag.spv" "$shader_dir/colour3D.slang"
  "$shader_compiler" -V -D -S vert -e mainVS -o "$spirv_dir/textured3D.vert.spv" "$shader_dir/textured3D.slang"
  "$shader_compiler" -V -D -S frag -e mainPS -o "$spirv_dir/textured3D.frag.spv" "$shader_dir/textured3D.slang"
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

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/Shaders" "$PACKAGE_DIR/lib"

cp "$BIN_DIR/$EXECUTABLE_NAME" "$PACKAGE_DIR/${EXECUTABLE_NAME}-bin"
cp -R "$ROOT_DIR/Shaders/SPIRV" "$PACKAGE_DIR/Shaders/"

if [[ -n "${SDL3_PREFIX:-}" ]]; then
  SDL3_LIB_DIR="$(
    find_first_existing \
      "$SDL3_PREFIX/lib" \
      "$SDL3_PREFIX/lib64" \
      "$SDL3_PREFIX/lib/x86_64-linux-gnu"
  )"

  if [[ -n "$SDL3_LIB_DIR" ]]; then
    while IFS= read -r -d '' library_path; do
      cp -a "$library_path" "$PACKAGE_DIR/lib/"
    done < <(find "$SDL3_LIB_DIR" -maxdepth 1 \( -name 'libSDL3.so' -o -name 'libSDL3.so.*' \) -print0)
  fi
fi

cat > "$PACKAGE_DIR/$EXECUTABLE_NAME" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$SCRIPT_DIR/minescene-bin" "$@"
EOF
chmod +x "$PACKAGE_DIR/$EXECUTABLE_NAME"

if command -v patchelf >/dev/null 2>&1; then
  current_rpath="$(patchelf --print-rpath "$PACKAGE_DIR/${EXECUTABLE_NAME}-bin" || true)"
  if [[ -n "$current_rpath" ]]; then
    patchelf --set-rpath "\$ORIGIN/lib:$current_rpath" "$PACKAGE_DIR/${EXECUTABLE_NAME}-bin"
  else
    patchelf --set-rpath "\$ORIGIN/lib" "$PACKAGE_DIR/${EXECUTABLE_NAME}-bin"
  fi
fi

{
  echo "swift:"
  swift --version
  echo
  echo "ldd:"
  ldd "$PACKAGE_DIR/${EXECUTABLE_NAME}-bin" || true
} > "$PACKAGE_DIR/BUILD-INFO.txt"

rm -f "$ARCHIVE_PATH"
tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$(basename "$PACKAGE_DIR")"

echo "Created $ARCHIVE_PATH"
