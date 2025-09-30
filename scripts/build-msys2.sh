#!/usr/bin/env bash
set -euxo pipefail
shopt -s nullglob

# -------------------------------------------------------------------
# Toolchain / env
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# Ensure tools/libs (NO trailing comments on continued lines)
# -------------------------------------------------------------------
pacman -Sy --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-fontforge \
  mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils \
  mingw-w64-x86_64-ntldd \
  mingw-w64-tools || true

# -------------------------------------------------------------------
# 1) Poppler 21.06.1 (static libs)
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# helpers
# -------------------------------------------------------------------
find_lib_glob() {
  # $1=subdir in poppler build (may be empty), $2=base name (e.g. poppler-glib | fontforge)
  local sub="$1" base="$2"
  local root="$BUILD/$POP_BUILD"
  local hits=()
  for f in \
    "$root/$sub/lib${base}.a" \
    "$root/$sub/lib${base}.dll.a" \
    "$root/$sub"/lib${base}-*.a \
    "$root/$sub"/lib${base}-*.dll.a \
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
  local base="$1" out="$2"
  local dll=""
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do [ -f "$f" ] && { dll="$f"; break; }; done
    [ -n "$dll" ] && break
  done
  if [ -z "$dll" ]; then
    echo "NOTE: No DLL found for ${base}; skipping synth." >&2
    return 1
  fi
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
  # must produce an import lib at $2 or exit
  local base="$1" out="$2"
  if src="$(find_lib_glob "" "$base")"; then
    cp -f "$src" "$out"; return 0
  fi
  if synth_import_from_dll "$base" "$out"; then
    return 0
  fi
  echo "ERROR: required FontForge import lib for '$base' not found/created" >&2
  exit 1
}

ensure_ff_optional() {
  # try to produce an import lib at $2, but don't fail if unavailable
  local base="$1" out="$2"
  if src="$(find_lib_glob "" "$base")"; then
    cp -f "$src" "$out"; return 0
  fi
  synth_import_from_dll "$base" "$out" || true
}

# -------------------------------------------------------------------
# 2) pdf2htmlEX sources + vendor libs
# -------------------------------------------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# Vendor Poppler layout expected by the project
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

# Copy poppler libs
CORE_SRC="$(find_lib_glob poppler poppler)"
GLIB_SRC="$(find_lib_glob glib poppler-glib)"
CPP_SRC="$(find_lib_glob cpp poppler-cpp || true)"

cp -f "$CORE_SRC" "$VENDOR_POP_SUB/libpoppler.a"
cp -f "$CORE_SRC" "$VENDOR_POP_ROOT/libpoppler.a"
cp -f "$GLIB_SRC" "$VENDOR_GLIB_SUB/libpoppler-glib.a"
cp -f "$GLIB_SRC" "$VENDOR_POP_ROOT/libpoppler-glib.a"
[ -n "${CPP_SRC:-}" ] && { cp -f "$CPP_SRC" "$VENDOR_CPP_SUB/libpoppler-cpp.a"; cp -f "$CPP_SRC" "$VENDOR_POP_ROOT/libpoppler-cpp.a"; }

# Vendor FontForge layout expected by pdf2htmlEX
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

# REQUIRED: libfontforge import lib
ensure_ff_required   fontforge   "$VENDOR_FF_LIB/libfontforge.a"

# OPTIONAL: libuninameslist (present in MSYS2; keep it)
ensure_ff_optional   uninameslist "$VENDOR_FF_LIB/libuninameslist.a"

# DO NOT require gutils/gunicode on modern MSYS2 (libfontforge depends on them internally)
# If they exist, we'll copy them; otherwise we continue.
ensure_ff_optional   gutils      "$VENDOR_FF_LIB/libgutils.a"
ensure_ff_optional   gunicode    "$VENDOR_FF_LIB/libgunicode.a"

# tests stub + normalize ancient cmake mins
if [ ! -f "$PDF2_SRC/test/test.py.in" ]; then
  mkdir -p "$PDF2_SRC/test"
  printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"
fi
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# -------------------------------------------------------------------
# 3) Build pdf2htmlEX
# -------------------------------------------------------------------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 -DCMAKE_INSTALL_PREFIX=/mingw64

cmake --build "$PDF2_SRC/build" --parallel

# -------------------------------------------------------------------
# 4) Package
# -------------------------------------------------------------------
cp -f "$PDF2_SRC/build/pdf2htmlEX.exe" "$STAGE/"

# bring along runtime DLLs
ntldd -R "$STAGE/pdf2htmlEX.exe" | awk '/=>/ {print $3}' | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
