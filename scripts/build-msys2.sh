#!/usr/bin/env bash
set -euxo pipefail
shopt -s nullglob

# --------------------------------------------
# Toolchain / env
# --------------------------------------------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export PKG_CONFIG=/mingw64/bin/pkg-config
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
# Force-include <optional> for TU that forgot it
export CXXFLAGS="${CXXFLAGS:-} -include optional"

ROOT="$(pwd)"
BUILD="$ROOT/.build"
STAGE="$ROOT/stage"
DIST="$ROOT/dist"
mkdir -p "$BUILD" "$STAGE" "$DIST"

echo "=== versions ==="
cmake --version
ninja --version
$CC --version | head -1
pkg-config --version

# --------------------------------------------
# System deps (use latest Poppler from MSYS2)
# --------------------------------------------
pacman -Sy --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-poppler \
  mingw-w64-x86_64-poppler-glib \
  mingw-w64-x86_64-poppler-cpp \
  mingw-w64-x86_64-cairo \
  mingw-w64-x86_64-freetype \
  mingw-w64-x86_64-harfbuzz \
  mingw-w64-x86_64-libpng \
  mingw-w64-x86_64-fontforge \
  mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils \
  mingw-w64-x86_64-ntldd \
  git curl zip

# --------------------------------------------
# Helpers
# --------------------------------------------
find_lib_glob() {
  # $1=subdir (ignored), $2=base lib name
  local base="$2" hits=()
  for f in \
      "/mingw64/lib/lib${base}.a" \
      "/mingw64/lib/lib${base}.dll.a" \
      "/mingw64/lib"/lib${base}-*.a \
      "/mingw64/lib"/lib${base}-*.dll.a
  do
    [ -f "$f" ] && hits+=("$f")
  done
  ((${#hits[@]})) && { printf '%s\n' "${hits[0]}"; return 0; }
  return 1
}

synth_import_from_dll() {
  # $1=base (e.g. fontforge), $2=output .a path
  local base="$1" out="$2" dll=""
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do [ -f "$f" ] && { dll="$f"; break; }; done
    [ -n "$dll" ] && break
  done
  [ -z "$dll" ] && { echo "NOTE: No DLL for $base; skipping synth."; return 1; }
  local tmp; tmp="$(mktemp -d)"
  (
    set -e
    cd "$tmp"
    gendef "$dll"
    dlltool -d *.def -l "$out"
  )
  rm -rf "$tmp"
}

ensure_ff_required() {
  local base="$1" out="$2"
  if src="$(find_lib_glob "" "$base")"; then cp -f "$src" "$out"; return 0; fi
  synth_import_from_dll "$base" "$out" && return 0
  echo "ERROR: required FontForge import lib for '$base' not found/created" >&2
  exit 1
}

ensure_ff_optional() {
  local base="$1" out="$2"
  if src="$(find_lib_glob "" "$base")"; then cp -f "$src" "$out"; return 0; fi
  synth_import_from_dll "$base" "$out" || true
}

# --------------------------------------------
# pdf2htmlEX source + vendor layout
# --------------------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# Vendor dirs that the project expects
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

# Poppler libs from MSYS2 (import libs are fine)
CORE_SRC="$(find_lib_glob poppler poppler)"
GLIB_SRC="$(find_lib_glob glib poppler-glib)"
CPP_SRC="$(find_lib_glob cpp poppler-cpp || true)"

cp -f "$CORE_SRC" "$VENDOR_POP_SUB/libpoppler.a"
cp -f "$CORE_SRC" "$VENDOR_POP_ROOT/libpoppler.a"
cp -f "$GLIB_SRC" "$VENDOR_GLIB_SUB/libpoppler-glib.a"
cp -f "$GLIB_SRC" "$VENDOR_POP_ROOT/libpoppler-glib.a"
[ -n "${CPP_SRC:-}" ] && { cp -f "$CPP_SRC" "$VENDOR_CPP_SUB/libpoppler-cpp.a"; cp -f "$CPP_SRC" "$VENDOR_POP_ROOT/libpoppler-cpp.a"; }

# **Headers**: copy the *current* Poppler headers that match the MSYS2 libs
VENDOR_POP_HEADERS="$PDF2_SRC/../poppler/poppler"
mkdir -p "$VENDOR_POP_HEADERS"
cp -r /mingw64/include/poppler/* "$VENDOR_POP_HEADERS/"

# FontForge import libs (synthesize if only DLL exists)
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"
ensure_ff_required   fontforge     "$VENDOR_FF_LIB/libfontforge.a"
ensure_ff_optional   uninameslist  "$VENDOR_FF_LIB/libuninameslist.a"
ensure_ff_optional   gutils        "$VENDOR_FF_LIB/libgutils.a"
ensure_ff_optional   gunicode      "$VENDOR_FF_LIB/libgunicode.a"

# tests stub + normalize ancient cmake mins
if [ ! -f "$PDF2_SRC/test/test.py.in" ]; then
  mkdir -p "$PDF2_SRC/test"
  printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"
fi
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# --------------------------------------------
# Configure & build (force include <optional>)
# --------------------------------------------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"

cmake --build "$PDF2_SRC/build" --parallel

# --------------------------------------------
# Package portable zip
# --------------------------------------------
cp -f "$PDF2_SRC/build/pdf2htmlEX.exe" "$STAGE/"

# Copy runtime DLLs
ntldd -R "$STAGE/pdf2htmlEX.exe" | awk '/=>/ {print $3}' | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
