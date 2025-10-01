#!/usr/bin/env bash
set -euo pipefail

# ---------- toolchain ----------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR=Ninja
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CXXFLAGS=" -O2 -DNDEBUG -Wno-overloaded-virtual"

# ---------- deps ----------
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-poppler mingw-w64-x86_64-poppler-data \
  mingw-w64-x86_64-cairo mingw-w64-x86_64-freetype mingw-w64-x86_64-harfbuzz \
  mingw-w64-x86_64-libpng mingw-w64-x86_64-fontforge mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils mingw-w64-x86_64-ntldd \
  cmake ninja git zip curl pkgconf

ROOT="$(pwd)"
BUILD="$ROOT/.build"
PDF2_DIR="$BUILD/pdf2htmlEX-src"
mkdir -p "$BUILD"

# ---------- sources ----------
if [[ ! -d "$PDF2_DIR" ]]; then
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"
fi

# repo layout: top has CMake that pulls subdir ./pdf2htmlEX
if [[ -f "$PDF2_DIR/CMakeLists.txt" ]]; then
  PDF2_SRC="$PDF2_DIR/pdf2htmlEX"
else
  PDF2_SRC="$PDF2_DIR"
fi

# ---------- vendor poppler (headers+import libs) ----------
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB"

# import libraries (use .dll.a copied as .a)
cp -f /mingw64/lib/libpoppler.dll.a      "$VENDOR_POP_ROOT/libpoppler.a"
mkdir -p "$VENDOR_POP_ROOT/glib" "$VENDOR_POP_ROOT/cpp"
cp -f /mingw64/lib/libpoppler-glib.dll.a "$VENDOR_POP_ROOT/glib/libpoppler-glib.a"
cp -f /mingw64/lib/libpoppler-cpp.dll.a  "$VENDOR_POP_ROOT/cpp/libpoppler-cpp.a"

# **copy ALL poppler headers** so CharCodeToUnicode.h and friends are present
VENDOR_POP_HDR="$PDF2_SRC/../poppler/poppler"
rm -rf "$VENDOR_POP_HDR"
mkdir -p "$VENDOR_POP_HDR"
cp -a /mingw64/include/poppler/* "$VENDOR_POP_HDR/"

# ---------- vendor fontforge bits ----------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

# synth import lib for libfontforge.dll (present on MSYS2)
if [[ -f /mingw64/bin/libfontforge.dll ]]; then
  tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  gendef /mingw64/bin/libfontforge.dll
  dlltool -d libfontforge.def -l "$VENDOR_FF_LIB/libfontforge.a"
  popd >/dev/null; rm -rf "$tmp"
fi

# extra libs (only those we actually need are present in MSYS2)
if [[ -f /mingw64/lib/libuninameslist.a ]]; then
  cp -f /mingw64/lib/libuninameslist.a "$VENDOR_FF_LIB/"
fi

# ---------- patch sources for modern toolchain/poppler ----------
# 1) relax cmake minimum (in all nested CMakeLists)
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} sed -i -E \
  's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# 2) C++20 headers where needed
for f in "$PDF2_SRC/src/pdf2htmlEX.cc" "$PDF2_SRC/src/HTMLRenderer/font.cc"; do
  if [[ -f "$f" ]] && ! grep -q '^#include <optional>' "$f"; then
    sed -i '1i #include <optional>' "$f"
  fi
done

# 3) poppler API nits in font.cc
FONTC="$PDF2_SRC/src/HTMLRenderer/font.cc"
if [[ -f "$FONTC" ]]; then
  # shared_ptr<GfxFont>(font) pattern → getFont(font, ...)
  sed -i -E 's/getFont\s*\(\s*std::shared_ptr<\s*GfxFont\s*>\s*\(\s*font\s*\)\s*,/getFont(font,/' "$FONTC"
  # unique_ptr construction change
  sed -i 's/if(std::unique_ptr<FoFiTrueType> fftt = FoFiTrueType::load(/if(std::unique_ptr<FoFiTrueType> fftt(FoFiTrueType::load(/g' "$FONTC"
  # optional name handling
  sed -i -E 's/font->getName\(\)\.value_or\(\s*""\s*\)/std::string(font->getName() ? font->getName()->c_str() : "")/g' "$FONTC"
fi

# 4) ensure <array> included for the new overload signature
HDR="$PDF2_SRC/src/HTMLRenderer/HTMLRenderer.h"
if [[ -f "$HDR" ]] && ! grep -q '<array>' "$HDR"; then
  sed -i '1i #include <array>' "$HDR"
fi

# 5) robustly insert the new overload *inside* struct HTMLRenderer (after first 'public:')
PYBIN="$(command -v python || command -v python3 || true)"
if [[ -n "${PYBIN:-}" ]] && [[ -f "$HDR" ]]; then
  "$PYBIN" - "$HDR" << 'PY'
import sys, io, re
p = sys.argv[1]
t = open(p, 'r', encoding='utf-8', newline='').read()
if 'std::array<double, 4>& bbox' not in t:
    # locate struct HTMLRenderer block
    m = re.search(r'(struct\s+HTMLRenderer\s*:\s*OutputDev\s*\{)', t)
    if m:
        start = m.end()
        # find first 'public:' after struct start
        mp = re.search(r'\bpublic:\b', t[start:])
        if mp:
            ins_at = start + mp.end()
            add = (
                "\n    using OutputDev::beginTransparencyGroup;\n"
                "    virtual void beginTransparencyGroup(\n"
                "        GfxState *state,\n"
                "        const std::array<double, 4>& bbox,\n"
                "        GfxColorSpace *blendingColorSpace,\n"
                "        bool isolated, bool knockout, bool forSoftMask);\n"
            )
            t = t[:ins_at] + add + t[ins_at:]
            open(p, 'w', encoding='utf-8', newline='').write(t)
PY
fi

# 6) add the array-overload implementation in draw.cc if missing
DRAW="$PDF2_SRC/src/HTMLRenderer/draw.cc"
if [[ -f "$DRAW" ]] && ! grep -q 'beginTransparencyGroup(GfxState \*state, const std::array<double, 4>&' "$DRAW"; then
  cat >> "$DRAW" <<'CPP'

// --- pdf2htmlEX compatibility shim for new Poppler signature ---
void HTMLRenderer::beginTransparencyGroup(
    GfxState *state,
    const std::array<double, 4>& bbox,
    GfxColorSpace *blendingColorSpace,
    bool isolated, bool knockout, bool forSoftMask)
{
    double b[4] = {bbox[0], bbox[1], bbox[2], bbox[3]};
    beginTransparencyGroup(state, b, blendingColorSpace, isolated, knockout, forSoftMask);
}
CPP
fi

# 7) provide a shim header so #include <CharCodeToUnicode.h> resolves cleanly
SHIM_DIR="$PDF2_SRC/src"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/CharCodeToUnicode.h" <<'HPP'
#pragma once
#if defined(__has_include)
#  if __has_include(<poppler/CharCodeToUnicode.h>)
#    include <poppler/CharCodeToUnicode.h>
#  elif __has_include("../poppler/poppler/CharCodeToUnicode.h")
#    include "../poppler/poppler/CharCodeToUnicode.h"
#  else
#    error "CharCodeToUnicode.h not found in Poppler includes"
#  endif
#else
#  include "../poppler/poppler/CharCodeToUnicode.h"
#endif
HPP

# ---------- configure & build ----------
BUILD_DIR="$PDF2_SRC/build"
cmake -S "$PDF2_SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS -std=c++20 -I/mingw64/include/poppler"

cmake --build "$BUILD_DIR" --parallel

# (optional) package the exe
if [[ -f "$BUILD_DIR/pdf2htmlEX.exe" ]]; then
  echo "Built: $BUILD_DIR/pdf2htmlEX.exe"
fi
