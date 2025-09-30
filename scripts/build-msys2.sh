#!/usr/bin/env bash
set -euxo pipefail

# ---------- toolchain ----------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe

# Ensure Poppler headers are always reachable; also cure missing <optional>.
export CXXFLAGS="${CXXFLAGS:-} -include optional -I/mingw64/include/poppler"

# ---------- deps (valid MSYS2 package names) ----------
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-poppler \
  mingw-w64-x86_64-cairo \
  mingw-w64-x86_64-freetype \
  mingw-w64-x86_64-harfbuzz \
  mingw-w64-x86_64-libpng \
  mingw-w64-x86_64-fontforge \
  mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils \
  mingw-w64-x86_64-ntldd \
  cmake ninja git zip curl

# ---------- sources ----------
ROOT="$(pwd)"
BUILD="$ROOT/.build"
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# ---------- vendor Poppler libs in expected layout ----------
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

copy_lib_as_a () { # $1=basename (e.g. poppler, poppler-glib, poppler-cpp) $2=destdir
  local base="$1" dest="$2"
  mkdir -p "$dest"
  if [ -f "/mingw64/lib/lib${base}.a" ]; then
    cp -f "/mingw64/lib/lib${base}.a"        "$dest/lib${base}.a"
  elif [ -f "/mingw64/lib/lib${base}.dll.a" ]; then
    # rename import lib to the exact name cmake/ninja expect
    cp -f "/mingw64/lib/lib${base}.dll.a"    "$dest/lib${base}.a"
  else
    echo "ERROR: could not find lib${base}{.a,.dll.a} in /mingw64/lib" >&2
    ls -l /mingw64/lib | sed -n "1,200p" || true
    exit 1
  fi
}

# place libs where pdf2htmlEX looks for them
copy_lib_as_a poppler       "$VENDOR_POP_ROOT"
copy_lib_as_a poppler       "$VENDOR_POP_SUB"
copy_lib_as_a poppler-glib  "$VENDOR_GLIB_SUB"
copy_lib_as_a poppler-cpp   "$VENDOR_CPP_SUB"

# (headers are used from /mingw64/include/poppler via CXXFLAGS)

# ---------- FontForge import libs ----------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

synth_from_dll () { # $1=basename $2=out.a
  local base="$1" out="$2" dll=""
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do
      [ -f "$f" ] && { dll="$f"; break; }
    done
    [ -n "$dll" ] && break
  done
  [ -z "$dll" ] && { echo "NOTE: no DLL for ${base}; skipping synth"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  ( set -e; cd "$tmp"; gendef "$dll"; dlltool -d lib${base}.def -l "$out" )
  rm -rf "$tmp"
}

for L in fontforge gutils gunicode uninameslist; do
  if compgen -G "/mingw64/lib/lib${L}.a" >/dev/null || compgen -G "/mingw64/lib/lib${L}.dll.a" >/dev/null; then
    # prefer existing import libs
    if [ -f "/mingw64/lib/lib${L}.a" ]; then
      cp -f "/mingw64/lib/lib${L}.a" "$VENDOR_FF_LIB/"
    else
      cp -f "/mingw64/lib/lib${L}.dll.a" "$VENDOR_FF_LIB/lib${L}.a"
    fi
  else
    synth_from_dll "$L" "$VENDOR_FF_LIB/lib${L}.a"
  fi
done

# ---------- small source shims ----------
# normalize old cmake mins
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# ensure <optional> is visible in the files that use std::optional
if ! grep -q '^#include <optional>' "$PDF2_SRC/src/pdf2htmlEX.cc"; then
  sed -i '1i #include <optional>' "$PDF2_SRC/src/pdf2htmlEX.cc" || true
fi
if [ -f "$PDF2_SRC/src/HTMLRenderer/font.cc" ] && ! grep -q '^#include <optional>' "$PDF2_SRC/src/HTMLRenderer/font.cc"; then
  sed -i '1i #include <optional>' "$PDF2_SRC/src/HTMLRenderer/font.cc" || true
fi

# adjust to Poppler's pointer signature for CairoFontEngine::getFont(...)
if [ -f "$PDF2_SRC/src/HTMLRenderer/font.cc" ]; then
  sed -i -E 's/getFont\s*\(\s*std::shared_ptr<\s*GfxFont\s*>\s*\(\s*font\s*\)\s*,/getFont(font,/' \
     "$PDF2_SRC/src/HTMLRenderer/font.cc" || true
fi

# create minimal test stub if repo doesn’t ship it
[ -f "$PDF2_SRC/test/test.py.in" ] || { mkdir -p "$PDF2_SRC/test"; printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"; }

# ---------- configure & build ----------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"

# sanity: show the libs we vendored so ninja won't complain about "no rule to make it"
echo "== vendored poppler libs =="
ls -l "$VENDOR_POP_ROOT" || true
ls -l "$VENDOR_GLIB_SUB" || true
ls -l "$VENDOR_CPP_SUB"  || true
echo "== vendored fontforge libs =="
ls -l "$VENDOR_FF_LIB"  || true

cmake --build "$PDF2_SRC/build" --parallel
