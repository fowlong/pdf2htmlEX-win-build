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
shopt -s nullglob

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

POP_BUILD="poppler-${POPLER_VER}/build"

# -------- helper: find a lib with glob fallbacks (versioned names OK) ----------
find_lib_glob() {
  # $1 = build-subdir (may be empty), $2 = base (e.g. poppler-glib | fontforge)
  local sub="$1" base="$2"
  local root="$BUILD/$POP_BUILD"
  local candidates=(
    "$root/$sub/lib${base}.a"
    "$root/$sub/lib${base}.dll.a"
    "$root/$sub"/lib${base}-*.a
    "$root/$sub"/lib${base}-*.dll.a
    "/mingw64/lib/lib${base}.a"
    "/mingw64/lib/lib${base}.dll.a"
    "/mingw64/lib"/lib${base}-*.a
    "/mingw64/lib"/lib${base}-*.dll.a
  )
  for f in "${candidates[@]}"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# ---------------- 2) pdf2htmlEX sources ---------------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# ---- Vendor Poppler layout(s): root and subdirs ----
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

# Poppler libs (copy to root AND subdirs; rename to expected plain names)
CORE_SRC="$(find_lib_glob poppler poppler)"
GLIB_SRC="$(find_lib_glob glib poppler-glib)"
CPP_SRC="$(find_lib_glob cpp poppler-cpp || true)"

cp -f "$CORE_SRC" "$VENDOR_POP_SUB/libpoppler.a"
cp -f "$CORE_SRC" "$VENDOR_POP_ROOT/libpoppler.a"
cp -f "$GLIB_SRC" "$VENDOR_GLIB_SUB/libpoppler-glib.a"
cp -f "$GLIB_SRC" "$VENDOR_POP_ROOT/libpoppler-glib.a"
[ -n "${CPP_SRC:-}" ] && { cp -f "$CPP_SRC" "$VENDOR_CPP_SUB/libpoppler-cpp.a"; cp -f "$CPP_SRC" "$VENDOR_POP_ROOT/libpoppler-cpp.a"; }

# ================== FontForge install block (added) ============================
# Ensure FontForge import libs exist in /mingw64/lib so the vendor copy below works
if ! pacman -Qi mingw-w64-x86_64-fontforge >/dev/null 2>&1; then
  pacman -Sy --noconfirm
  pacman -S  --noconfirm --needed mingw-w64-x86_64-fontforge
fi
# (Optional) quick listing for debugging
ls -1 /mingw64/lib/libfontforge* /mingw64/lib/libgutils* /mingw64/lib/libgunicode* /mingw64/lib/libuninameslist* 2>/dev/null || true
# ==============================================================================

# ---- Vendor FontForge layout: ../fontforge/build/lib/*.a ----------------------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

copy_ff() {
  # $1 = base name to glob in /mingw64/lib (fontforge|gutils|gunicode|uninameslist)
  # $2 = target filename in vendor dir
  local base="$1" out="$2"
  local src
  src="$(find_lib_glob "" "$base")" || { echo "WARN: $base import lib not found; continuing"; return 0; }
  cp -f "$src" "$VENDOR_FF_LIB/$out"
}

# MSYS2 names may be versioned (e.g. libfontforge-2.dll.a); globbing handles it
copy_ff fontforge     libfontforge.a
copy_ff gutils        libgutils.a
copy_ff gunicode      libgunicode.a
copy_ff uninameslist  libuninameslist.a

# ---- CMake normalize + tests stub --------------------------------------------
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

# Add dependent DLLs next to the EXE
ntldd -R "$STAGE/pdf2htmlEX.exe" | awk '/=>/ {print $3}' | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
