#!/usr/bin/env bash
set -euo pipefail

# -------- toolchain --------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR=Ninja
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CXXFLAGS=" -O2 -DNDEBUG -Wno-overloaded-virtual"

# -------- deps --------
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-poppler mingw-w64-x86_64-poppler-data \
  mingw-w64-x86_64-cairo mingw-w64-x86_64-freetype mingw-w64-x86_64-harfbuzz \
  mingw-w64-x86_64-libpng mingw-w64-x86_64-fontforge mingw-w64-x86_64-libuninameslist \
  mingw-w64-x86_64-binutils mingw-w64-x86_64-ntldd \
  cmake ninja git zip curl pkgconf mingw-w64-x86_64-tools-git

ROOT="$(pwd)"
BUILD="$ROOT/.build"
SRC_DIR="$BUILD/pdf2htmlEX-src"
mkdir -p "$BUILD"

# -------- clone --------
if [[ ! -d "$SRC_DIR/.git" ]]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$SRC_DIR"
fi

# Determine the actual CMake source folder.
# Newer repo layouts keep CMakeLists.txt in subdir 'pdf2htmlEX'.
if [[ -f "$SRC_DIR/pdf2htmlEX/CMakeLists.txt" ]]; then
  PDF2_SRC="$SRC_DIR/pdf2htmlEX"
elif [[ -f "$SRC_DIR/CMakeLists.txt" ]]; then
  PDF2_SRC="$SRC_DIR"
else
  echo "ERROR: Could not locate CMakeLists.txt."
  echo "Checked:"
  echo "  - $SRC_DIR/pdf2htmlEX/CMakeLists.txt"
  echo "  - $SRC_DIR/CMakeLists.txt"
  echo "Directory tree:"
  ls -la "$SRC_DIR"
  exit 1
fi
echo "Using source dir: $PDF2_SRC"

# -------- vendor Poppler (headers + import libs) --------
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_ROOT/glib" "$VENDOR_POP_ROOT/cpp"
cp -f /mingw64/lib/libpoppler.dll.a      "$VENDOR_POP_ROOT/libpoppler.a"
cp -f /mingw64/lib/libpoppler-glib.dll.a "$VENDOR_POP_ROOT/glib/libpoppler-glib.a"
cp -f /mingw64/lib/libpoppler-cpp.dll.a  "$VENDOR_POP_ROOT/cpp/libpoppler-cpp.a"

# Copy *all* Poppler headers so CharCodeToUnicode.h et al. are present
VENDOR_POP_HDR="$PDF2_SRC/../poppler/poppler"
rm -rf "$VENDOR_POP_HDR"
mkdir -p "$VENDOR_POP_HDR"
cp -a /mingw64/include/poppler/* "$VENDOR_POP_HDR/"

# -------- vendor FontForge bits --------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

# Build import lib from the DLL (present on MSYS2)
if [[ -f /mingw64/bin/libfontforge.dll ]]; then
  tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  gendef /mingw64/bin/libfontforge.dll
  dlltool -d libfontforge.def -l "$VENDOR_FF_LIB/libfontforge.a"
  popd >/dev/null; rm -rf "$tmp"
fi
# Uninameslist is a static .a in MSYS2
[[ -f /mingw64/lib/libuninameslist.a ]] && cp -f /mingw64/lib/libuninameslist.a "$VENDOR_FF_LIB/"

# -------- source patches for modern Poppler/Toolchain --------
# Relax cmake minimum (in all nested CMakeLists)
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} sed -i -E \
  's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# Add <optional> where needed
for f in "$PDF2_SRC/src/pdf2htmlEX.cc" "$PDF2_SRC/src/HTMLRenderer/font.cc"; do
  if [[ -f "$f" ]] && ! grep -q '^#include <optional>' "$f"; then
    sed -i '1i #include <optional>' "$f"
  fi
done

# Poppler API tweaks in font.cc
FONTC="$PDF2_SRC/src/HTMLRenderer/font.cc"
if [[ -f "$FONTC" ]]; then
  sed -i -E 's/getFont\s*\(\s*std::shared_ptr<\s*GfxFont\s*>\s*\(\s*font\s*\)\s*,/getFont(font,/' "$FONTC"
  sed -i 's/if(std::unique_ptr<FoFiTrueType> fftt = FoFiTrueType::load(/if(std::unique_ptr<FoFiTrueType> fftt(FoFiTrueType::load(/g' "$FONTC"
  sed -i -E 's/font->getName\(\)\.value_or\(\s*""\s*\)/std::string(font->getName() ? font->getName()->c_str() : "")/g' "$FONTC"
fi

# Ensure <array> for new overload signature
HDR="$PDF2_SRC/src/HTMLRenderer/HTMLRenderer.h"
if [[ -f "$HDR" ]] && ! grep -q '<array>' "$HDR"; then
  sed -i '1i #include <array>' "$HDR"
fi

# Insert the new array-based overload *inside* struct HTMLRenderer, under public:
PYBIN="$(command -v python || command -v python3 || true)"
if [[ -n "${PYBIN:-}" ]] && [[ -f "$HDR" ]]; then
  "$PYBIN" - "$HDR" << 'PY'
import sys, re
p = sys.argv[1]
t = open(p, 'r', encoding='utf-8', newline='').read()
if 'std::array<double, 4>& bbox' not in t:
    m = re.search(r'(struct\s+HTMLRenderer\s*:\s*OutputDev\s*\{)', t)
    if m:
        start = m.end()
        mp = re.search(r'\bpublic:\b', t[start:])
        if mp:
            ins = start + mp.end()
            add = (
                "\n    using OutputDev::beginTransparencyGroup;\n"
                "    virtual void beginTransparencyGroup(\n"
                "        GfxState *state,\n"
                "        const std::array<double, 4>& bbox,\n"
                "        GfxColorSpace *blendingColorSpace,\n"
                "        bool isolated, bool knockout, bool forSoftMask);\n"
            )
            t = t[:ins] + add + t[ins:]
            open(p, 'w', encoding='utf-8', newline='').write(t)
PY
fi

# Provide the matching implementation in draw.cc if missing
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

# Shim header so includes to CharCodeToUnicode always resolve
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

# -------- configure & build --------
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

# Optional: show path to artifact
[[ -f "$BUILD_DIR/pdf2htmlEX.exe" ]] && echo "Built: $BUILD_DIR/pdf2htmlEX.exe"
