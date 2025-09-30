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
# Ensure MSYS2 deps that we vendor or use to synthesize import libs
# -------------------------------------------------------------------
pacman -Sy --noconfirm
pacman -S  --noconfirm --needed \
  mingw-w64-x86_64-fontforge \
  mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils \        # dlltool
  mingw-w64-x86_64-tools \           # gendef
  mingw-w64-x86_64-ntldd || true

# quick visibility (ignore errors if absent)
ls -1 /mingw64/lib/libfontforge* 2>/dev/null || true
ls -1 /mingw64/lib/libgutils*     2>/dev/null || true
ls -1 /mingw64/lib/libgunicode*   2>/dev/null || true
ls -1 /mingw64/lib/libuninameslist* 2>/dev/null || true

# -------------------------------------------------------------------
# 1) Poppler 21.06.1
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
# helper: locate a lib (supports versioned names and several roots)
# prints first hit
# -------------------------------------------------------------------
find_lib_glob() {
  # $1 = build-subdir (may be empty), $2 = base (e.g. poppler-glib | fontforge)
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

  # fallback: scan the package file list (useful when paths shift)
  if pacman -Qi mingw-w64-x86_64-fontforge >/dev/null 2>&1; then
    while IFS= read -r p; do
      case "$p" in
        */lib/lib${base}.a|*/lib/lib${base}.dll.a|*/lib/lib${base}-*.a|*/lib/lib${base}-*.dll.a)
          [ -f "$p" ] && { echo "$p"; return 0; }
          ;;
      esac
    done < <(pacman -Qlq mingw-w64-x86_64-fontforge 2>/dev/null || true)
  fi
  return 1
}

# Synthesize an import lib from a DLL if needed
synth_import_from_dll() {
  # $1 base (fontforge|gutils|gunicode|uninameslist)
  # $2 output full path to .a
  local base="$1" out="$2"
  local dll=""
  # try common dll names
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do
      [ -f "$f" ] && { dll="$f"; break; }
    done
    [ -n "${dll}" ] && break
  done
  [ -z "${dll}" ] && { echo "ERROR: No DLL found for ${base}" >&2; return 1; }

  local tmp; tmp="$(mktemp -d)"
  (
    set -e
    cd "$tmp"
    echo "Synthesizing import lib for ${base} from $(basename "$dll")"
    gendef "$dll"                     # produces *.def
    local def=( *.def )
    dlltool -d "${def[0]}" -l "$out" # create .a
  )
  rm -rf "$tmp"
}

# -------------------------------------------------------------------
# 2) pdf2htmlEX + vendor poppler & fontforge
# -------------------------------------------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# ---- Vendor Poppler layout
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

CORE_SRC="$(find_lib_glob poppler poppler)"
GLIB_SRC="$(find_lib_glob glib poppler-glib)"
CPP_SRC="$(find_lib_glob cpp poppler-cpp || true)"

cp -f "$CORE_SRC" "$VENDOR_POP_SUB/libpoppler.a"
cp -f "$CORE_SRC" "$VENDOR_POP_ROOT/libpoppler.a"
cp -f "$GLIB_SRC" "$VENDOR_GLIB_SUB/libpoppler-glib.a"
cp -f "$GLIB_SRC" "$VENDOR_POP_ROOT/libpoppler-glib.a"
[ -n "${CPP_SRC:-}" ] && { cp -f "$CPP_SRC" "$VENDOR_CPP_SUB/libpoppler-cpp.a"; cp -f "$CPP_SRC" "$VENDOR_POP_ROOT/libpoppler-cpp.a"; }

# ---- Vendor FontForge layout expected by pdf2htmlEX
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

ensure_ff_import() {
  local base="$1" out="$2"
  if src="$(find_lib_glob "" "$base")"; then
    echo "Using existing import lib: $src -> $out"
    cp -f "$src" "$out"
  else
    # Make one from the shipped DLL
    synth_import_from_dll "$base" "$out"
  fi
}

ensure_ff_import fontforge    "$VENDOR_FF_LIB/libfontforge.a"
ensure_ff_import gutils       "$VENDOR_FF_LIB/libgutils.a"
ensure_ff_import gunicode     "$VENDOR_FF_LIB/libgunicode.a"
# Usually present; synthesize if missing:
if src="$(find_lib_glob "" "uninameslist")"; then
  cp -f "$src" "$VENDOR_FF_LIB/libuninameslist.a"
else
  synth_import_from_dll "uninameslist" "$VENDOR_FF_LIB/libuninameslist.a" || true
fi

# ---- CMake normalize + tests stub --------------------------------------------
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
# 4) Package portable zip
# -------------------------------------------------------------------
cp -f "$PDF2_SRC/build/pdf2htmlEX.exe" "$STAGE/"
ntldd -R "$STAGE/pdf2htmlEX.exe" | awk '/=>/ {print $3}' | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
