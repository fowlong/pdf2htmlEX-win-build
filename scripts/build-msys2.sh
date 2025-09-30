#!/usr/bin/env bash
set -euxo pipefail

# toolchain
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export PKG_CONFIG=/mingw64/bin/pkg-config
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CMAKE_BUILD_PARALLEL_LEVEL=4

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

# ---------------- 1) Poppler 21.06.1 (GLib ON, Boost/NSS OFF) ------------------
POPLER_VER="21.06.1"
POPLER_TBZ="poppler-${POPLER_VER}.tar.xz"
POPLER_URL="https://poppler.freedesktop.org/${POPLER_TBZ}"

cd "$BUILD"
[ -d "poppler-${POPLER_VER}" ] || { curl -L "$POPLER_URL" -o "$POPLER_TBZ"; tar -xf "$POPLER_TBZ"; }

cmake -S "poppler-${POPLER_VER}" -B "poppler-${POPLER_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF \
  -DENABLE_GLIB=ON \
  -DENABLE_CPP=ON \
  -DENABLE_QT5=OFF -DENABLE_QT6=OFF \
  -DENABLE_BOOST=OFF \
  -DENABLE_NSS3=OFF

cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# Build tree root for convenience
POP_BUILD="poppler-${POPLER_VER}/build"

# Helper: find a poppler lib (prefers static .a, falls back to .dll.a) and echo path
find_poppler_lib() {
  # $1 = subdir in build tree (poppler|glib|cpp), $2 = base name (poppler|poppler-glib|poppler-cpp)
  local sub="$1" base="$2"
  local candidates=(
    "$BUILD/$POP_BUILD/$sub/lib${base}.a"
    "$BUILD/$POP_BUILD/$sub/lib${base}.dll.a"
    "/mingw64/lib/lib${base}.a"
    "/mingw64/lib/lib${base}.dll.a"
  )
  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# ---------------- 2) pdf2htmlEX sources ---------------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
if [ ! -d "$PDF2_DIR" ]; then
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"
fi
PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# Vendor layout expected by historical CMake in pdf2htmlEX:
VENDOR_POP="$PDF2_SRC/../poppler/build"
mkdir -p "$VENDOR_POP/poppler" "$VENDOR_POP/glib" "$VENDOR_POP/cpp"

# Discover + copy/rename libs so paths match what pdf2htmlEX looks for
POP_CORE_SRC="$(find_poppler_lib poppler poppler)"
POP_GLIB_SRC="$(find_poppler_lib glib    poppler-glib)"
# cpp is optional; only copy if present
POP_CPP_SRC="$(find_poppler_lib cpp     poppler-cpp || true)"

cp -f "$POP_CORE_SRC" "$VENDOR_POP/poppler/libpoppler.a"
cp -f "$POP_GLIB_SRC" "$VENDOR_POP/glib/libpoppler-glib.a"
[ -n "${POP_CPP_SRC:-}" ] && cp -f "$POP_CPP_SRC" "$VENDOR_POP/cpp/libpoppler-cpp.a"

# Minimal test stub & CMake minimum normalization
if [ ! -f "$PDF2_SRC/test/test.py.in" ]; then
  mkdir -p "$PDF2_SRC/test"
  printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"
fi
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# ---------------- 3) Build pdf2htmlEX -----------------------------------------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 -DCMAKE_INSTALL_PREFIX=/mingw64

cmake --build "$PDF2_SRC/build" --parallel

# ---------------- 4) Package portable zip -------------------------------------
cp -f "$PDF2_SRC/build/pdf2htmlEX.exe" "$STAGE/"

# Bring DLLs next to exe
ntldd -R "$STAGE/pdf2htmlEX.exe" | awk '/=>/ {print $3}' | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
