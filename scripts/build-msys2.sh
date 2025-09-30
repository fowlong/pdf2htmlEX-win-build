#!/usr/bin/env bash
set -euxo pipefail

# -------- toolchain --------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
# make warnings non-fatal for Poppler API drift
export CXXFLAGS="${CXXFLAGS:-} -O2 -DNDEBUG -Wno-overloaded-virtual"

# -------- deps --------
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

# -------- sources --------
ROOT="$(pwd)"
BUILD="$ROOT/.build"
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# -------- vendor Poppler (libs + headers) --------
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_ROOT" "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

copy_lib_as_a () { # $1=basename $2=destdir
  local base="$1" dest="$2"
  mkdir -p "$dest"
  if   [ -f "/mingw64/lib/lib${base}.a"     ]; then cp -f "/mingw64/lib/lib${base}.a"     "$dest/lib${base}.a"
  elif [ -f "/mingw64/lib/lib${base}.dll.a" ]; then cp -f "/mingw64/lib/lib${base}.dll.a" "$dest/lib${base}.a"
  else echo "ERROR: lib${base}{.a,.dll.a} missing"; exit 1; fi
}

copy_lib_as_a poppler      "$VENDOR_POP_ROOT"
copy_lib_as_a poppler      "$VENDOR_POP_SUB"
copy_lib_as_a poppler-glib "$VENDOR_GLIB_SUB"
copy_lib_as_a poppler-cpp  "$VENDOR_CPP_SUB"

# headers: mirror the full poppler tree where pdf2htmlEX expects it
VENDOR_POP_HDR="$PDF2_SRC/../poppler/poppler"
rm -rf "$VENDOR_POP_HDR"; mkdir -p "$VENDOR_POP_HDR"
cp -r /mingw64/include/poppler/* "$VENDOR_POP_HDR/"

# -------- FontForge import libs (synthesize if needed) --------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

synth_from_dll () { # $1=basename $2=out.a
  local base="$1" out="$2" dll=""
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do [ -f "$f" ] && { dll="$f"; break; }; done
    [ -n "$dll" ] && break || true
  done
  [ -z "$dll" ] && { echo "NOTE: no DLL for ${base}; skipping synth"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  ( set -e; cd "$tmp"; gendef "$dll"; dlltool -d "lib${base}.def" -l "$out" )
  rm -rf "$tmp"
}

for L in fontforge gutils gunicode uninameslist; do
  if   [ -f "/mingw64/lib/lib${L}.a"     ]; then cp -f "/mingw64/lib/lib${L}.a"     "$VENDOR_FF_LIB/"
  elif [ -f "/mingw64/lib/lib${L}.dll.a" ]; then cp -f "/mingw64/lib/lib${L}.dll.a" "$VENDOR_FF_LIB/lib${L}.a"
  else synth_from_dll "$L" "$VENDOR_FF_LIB/lib${L}.a"
  fi
done

# -------- patches/shims --------
# normalize cmake minimums
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# header/source: ensure <optional>
for f in "$PDF2_SRC/src/pdf2htmlEX.cc" "$PDF2_SRC/src/HTMLRenderer/font.cc"; do
  [ -f "$f" ] && ! grep -q '^#include <optional>' "$f" && sed -i '1i #include <optional>' "$f" || true
done

# fix CairoFontEngine::getFont signature (GfxFont* expected)
if [ -f "$PDF2_SRC/src/HTMLRenderer/font.cc" ]; then
  sed -i -E 's/getFont\s*\(\s*std::shared_ptr<\s*GfxFont\s*>\s*\(\s*font\s*\)\s*,/getFont(font,/' \
    "$PDF2_SRC/src/HTMLRenderer/font.cc" || true
fi

# fix unique_ptr direct-init for FoFiTrueType::load
if [ -f "$PDF2_SRC/src/HTMLRenderer/font.cc" ]; then
  sed -i 's/if(std::unique_ptr<FoFiTrueType> fftt = FoFiTrueType::load(/if(std::unique_ptr<FoFiTrueType> fftt(FoFiTrueType::load(/g' \
    "$PDF2_SRC/src/HTMLRenderer/font.cc" || true
fi

# fix getName().value_or("") (GooString* on Poppler)
if [ -f "$PDF2_SRC/src/HTMLRenderer/font.cc" ]; then
  sed -i -E 's/font->getName\(\)\.value_or\(\s*""\s*\)/std::string(font->getName() ? font->getName()->c_str() : "")/g' \
    "$PDF2_SRC/src/HTMLRenderer/font.cc" || true
fi

# --- Poppler >= 24.x beginTransparencyGroup(std::array<...>) compat ---
HDR="$PDF2_SRC/src/HTMLRenderer/HTMLRenderer.h"
if [ -f "$HDR" ]; then
  # include <array> once
  grep -q '<array>' "$HDR" || sed -i '1i #include <array>' "$HDR"
  # expose base overloads to avoid hiding warnings
  awk '
  /class[ \t]+HTMLRenderer/ {in=1}
  in && /public:/ && !done { print; print "    using OutputDev::beginTransparencyGroup;"; done=1; next }
  { print }' "$HDR" > "$HDR.tmp" && mv "$HDR.tmp" "$HDR"
  # add declaration for the new std::array overload if missing
  grep -q 'beginTransparencyGroup\s*(GfxState \*state, const std::array<double, 4>&' "$HDR" || \
    sed -i '/beginTransparencyGroup\s*(GfxState[^\n]*const double \*/a \ \ \ \ virtual void beginTransparencyGroup(GfxState *state, const std::array<double, 4>& bbox, GfxColorSpace *blendingColorSpace, bool isolated, bool knockout, bool forSoftMask);\n' "$HDR" || true
fi

SRC_DRAW="$PDF2_SRC/src/HTMLRenderer/draw.cc"
if [ -f "$SRC_DRAW" ]; then
  grep -q 'beginTransparencyGroup(GfxState \*state, const std::array<double, 4>&' "$SRC_DRAW" || cat >> "$SRC_DRAW" <<'EOF'

// ---- Poppler >= 24.x bbox adapter (forward to the legacy pointer overload) ----
#include <array>
namespace pdf2htmlEX {
void HTMLRenderer::beginTransparencyGroup(GfxState *state,
                                          const std::array<double, 4>& bbox,
                                          GfxColorSpace *blendingColorSpace,
                                          bool isolated, bool knockout, bool forSoftMask) {
    double b[4] = {bbox[0], bbox[1], bbox[2], bbox[3]};
    this->beginTransparencyGroup(state, b, blendingColorSpace, isolated, knockout, forSoftMask);
}
} // namespace pdf2htmlEX
EOF
fi

# placeholder tests if upstream omitted them
[ -f "$PDF2_SRC/test/test.py.in" ] || { mkdir -p "$PDF2_SRC/test"; printf '#!/usr/bin/env @PYTHON@\nprint("tests disabled")\n' > "$PDF2_SRC/test/test.py.in"; }

# -------- configure & build --------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS -I/mingw64/include/poppler"

cmake --build "$PDF2_SRC/build" --parallel
