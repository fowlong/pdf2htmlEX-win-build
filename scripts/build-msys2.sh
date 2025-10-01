#!/usr/bin/env bash
# scripts/build-msys2.sh
set -Eeuo pipefail

log() { printf "\n\033[1;36m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
ROOT="$(pwd)"
BUILD="$ROOT/.build"

# --- toolchain/env -----------------------------------------------------------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR=Ninja
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CXXFLAGS=" -O2 -DNDEBUG -Wno-overloaded-virtual "

# --- base packages (NO poppler pkg) -----------------------------------------
log "Sync + base packages (system poppler intentionally NOT installed)"
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-cairo \
  mingw-w64-x86_64-freetype \
  mingw-w64-x86_64-harfbuzz \
  mingw-w64-x86_64-libpng \
  mingw-w64-x86_64-openjpeg2 \
  mingw-w64-x86_64-libtiff \
  mingw-w64-x86_64-lcms2 \
  mingw-w64-x86_64-fontconfig \
  mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-nss \
  mingw-w64-x86_64-curl \
  mingw-w64-x86_64-fontforge \
  mingw-w64-x86_64-ntldd \
  cmake ninja git zip pkgconf

# remove any pre-installed poppler to avoid header/library confusion
pacman -R --noconfirm mingw-w64-x86_64-poppler mingw-w64-x86_64-poppler-data 2>/dev/null || true

# --- source layout -----------------------------------------------------------
mkdir -p "$BUILD"
PDF2_TOP="$BUILD/pdf2htmlEX-src"
if [[ ! -d "$PDF2_TOP" ]]; then
  log "Cloning pdf2htmlEX"
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_TOP"
fi
PDF2_SRC="$PDF2_TOP/pdf2htmlEX"

# --- build & install Poppler with XPDF headers -------------------------------
POP_VER="25.09.1"
POP_DIR="$BUILD/poppler-$POP_VER"
if [[ ! -d "$POP_DIR" ]]; then
  log "Fetching Poppler $POP_VER"
  curl -fsSL "https://poppler.freedesktop.org/poppler-${POP_VER}.tar.xz" | tar -Jx -C "$BUILD"
fi

log "Configuring Poppler (XPDF headers enabled, glib & cpp on)"
cmake -S "$POP_DIR" -B "$POP_DIR/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DENABLE_XPDF_HEADERS=ON \
  -DENABLE_CPP=ON \
  -DENABLE_GLIB=ON \
  -DENABLE_GOBJECT_INTROSPECTION=OFF \
  -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_UTILS=OFF \
  -DBUILD_GTK_TESTS=OFF

log "Building & installing Poppler"
ninja -C "$POP_DIR/build" install

# --- mirror Poppler headers/libs into vendor paths pdf2htmlEX expects --------
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
VENDOR_HDR_DIR="$PDF2_SRC/../poppler/poppler"

log "Preparing vendor include/lib directories"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB" "$VENDOR_HDR_DIR"

# headers (mirror everything to match includes like ../poppler/poppler/OutputDev.h)
log "Copying Poppler headers to vendor tree"
rsync -a --delete "/mingw64/include/poppler/" "$VENDOR_HDR_DIR/"

# libs: rename .dll.a -> .a so CMake 'static' expectations are satisfied
log "Copying Poppler import libs to vendor tree"
cp -f /mingw64/lib/libpoppler.dll.a         "$VENDOR_POP_ROOT/libpoppler.a"
cp -f /mingw64/lib/libpoppler.dll.a         "$VENDOR_POP_SUB/libpoppler.a"
[[ -f /mingw64/lib/libpoppler-glib.dll.a ]] && cp -f /mingw64/lib/libpoppler-glib.dll.a "$VENDOR_GLIB_SUB/libpoppler-glib.a"
[[ -f /mingw64/lib/libpoppler-cpp.dll.a  ]] && cp -f /mingw64/lib/libpoppler-cpp.dll.a  "$VENDOR_CPP_SUB/libpoppler-cpp.a"

# --- minimal FontForge vendor shim (import lib synthesized from dll) ---------
# pdf2htmlEX doesn't really *use* most FF symbols, but some build graphs expect a .a
synth_from_dll() {
  local base="$1" out="$2"
  local dll=""
  shopt -s nullglob
  for f in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    [[ -f "$f" ]] && { dll="$f"; break; }
  done
  shopt -u nullglob
  if [[ -z "$dll" ]]; then
    log "NOTE: no DLL for ${base}; skipping synth"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  ( set -e
    cd "$tmp"
    gendef "$dll"
    dlltool -d "lib${base}.def" -l "$out"
  )
  rm -rf "$tmp"
}
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"
if [[ -f /mingw64/bin/libfontforge.dll ]]; then
  log "Synthesizing vendor libfontforge.a from DLL"
  synth_from_dll fontforge "$VENDOR_FF_LIB/libfontforge.a"
fi
# standalone library exists in MSYS2; just copy it for convenience
[[ -f /mingw64/lib/libuninameslist.a ]] && cp -f /mingw64/lib/libuninameslist.a "$VENDOR_FF_LIB/"

# --- de-risk / revert previous dangerous edits -------------------------------
log "Removing any local header shims or stray prototypes from prior runs"
rm -f "$PDF2_SRC/src/CharCodeToUnicode.h" || true

HDR="$PDF2_SRC/src/HTMLRenderer/HTMLRenderer.h"
DRAW="$PDF2_SRC/src/HTMLRenderer/draw.cc"
FONT="$PDF2_SRC/src/HTMLRenderer/font.cc"
MAIN="$PDF2_SRC/src/pdf2htmlEX.cc"

# drop any stray array-based declaration injected outside the class previously
sed -i '/beginTransparencyGroup(.*std::array<double, 4>.*bbox.*);/d' "$HDR" || true

# --- safe/poppler-proof header trampoline ------------------------------------
log "Adding in-class std::array bbox override (trampoline) if missing"
grep -q '<array>' "$HDR" || sed -i '1i #include <array>' "$HDR"

if ! grep -q 'beginTransparencyGroup(.*std::array<double, 4>' "$HDR"; then
  # insert inside 'struct HTMLRenderer : OutputDev { ... };' before the closing brace
  sed -i '/struct[[:space:]]\+HTMLRenderer[[:space:]]*:[[:space:]]*OutputDev/,/};/ {
    /};/ i\
    \ \ // Poppler >= 0.83 overload (trampoline to legacy pointer version)\n\
    \ \ void beginTransparencyGroup(\n\
    \ \ \ \ GfxState *state,\n\
    \ \ \ \ const std::array<double, 4>& bbox,\n\
    \ \ \ \ GfxColorSpace *blendingColorSpace,\n\
    \ \ \ \ bool isolated,\n\
    \ \ \ \ bool knockout,\n\
    \ \ \ \ bool forSoftMask) override {\n\
    \ \ \ \ \ double b[4] = {bbox[0], bbox[1], bbox[2], bbox[3]};\n\
    \ \ \ \ \ beginTransparencyGroup(state, b, blendingColorSpace, isolated, knockout, forSoftMask);\n\
    \ \ }\n
  }' "$HDR"
fi

# --- keep the harmless C++20 touch-ups you already used ----------------------
log "Applying small C++20 compatibility touch-ups (idempotent)"
# add <optional> includes where needed
grep -q '^#include <optional>' "$MAIN" || sed -i '1i #include <optional>' "$MAIN"
if [[ -f "$FONT" ]]; then
  grep -q '^#include <optional>' "$FONT" || sed -i '1i #include <optional>' "$FONT"
  # normalize getFont(...) call pattern sometimes seen in forks
  sed -i -E 's/getFont\s*\(\s*std::shared_ptr<\s*GfxFont\s*>\s*\(\s*font\s*\)\s*,/getFont(font,/' "$FONT"
  # modernize unique_ptr initialization form
  sed -i 's/if\s*(\s*std::unique_ptr<FoFiTrueType>\s*fftt\s*=\s*FoFiTrueType::load(/if(std::unique_ptr<FoFiTrueType> fftt(FoFiTrueType::load(/g' "$FONT"
  # guard optional -> string use
  sed -i -E 's/font->getName\(\)\.value_or\(\s*""\s*\)/std::string(font->getName() ? font->getName()->c_str() : "")/g' "$FONT"
fi

# some trees carry older cmake minimums; bump to a sane value quietly
log "Normalizing cmake_minimum_required to 3.5 (no behavior change)"
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# --- configure & build pdf2htmlEX -------------------------------------------
log "Configuring pdf2htmlEX"
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  "-DCMAKE_CXX_FLAGS=$CXXFLAGS"

log "Building pdf2htmlEX"
cmake --build "$PDF2_SRC/build" --parallel

log "DONE. Binaries should be under: $PDF2_SRC/build"
