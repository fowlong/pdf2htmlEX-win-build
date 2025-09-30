#!/usr/bin/env bash
set -euxo pipefail

# Env
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++
export PKG_CONFIG=/mingw64/bin/pkg-config
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig:/mingw64/share/pkgconfig
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CMAKE_BUILD_PARALLEL_LEVEL=4

echo "=== tool versions ==="
cmake --version
ninja --version
$CC --version | head -1 || true
pkg-config --version

trap 'echo "---- LOOK FOR CMakeError/Output logs ----";
      find "$PWD" -name CMakeError.log -o -name CMakeOutput.log -print -exec sed -n "1,200p" "{}" \; || true' ERR

PREFIX=/mingw64
ROOT="$PWD"
BUILD="$ROOT/.build"
STAGE="$ROOT/stage"
DIST="$ROOT/dist"

POPLER_VER="0.89.0"
FF_VER="20200314"

mkdir -p "$BUILD" "$STAGE" "$DIST"

# ---------- FontForge (headless) ----------
echo "=== FontForge ${FF_VER} ==="
cd "$BUILD"
FF_TARBALL="fontforge-${FF_VER}.tar.xz"
[ -f "$FF_TARBALL" ] || curl -L -o "$FF_TARBALL" "https://sourceforge.net/projects/fontforge.mirror/files/${FF_VER}/fontforge-${FF_VER}.tar.xz/download"
rm -rf "fontforge-${FF_VER}"
tar -xf "$FF_TARBALL"
cmake -S "fontforge-${FF_VER}" -B "fontforge-${FF_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_GUI=OFF -DENABLE_X11=OFF \
  -DENABLE_PYTHON_SCRIPTING=OFF -DENABLE_PYTHON_EXTENSION=OFF \
  -DENABLE_LIBSPIRO=ON -DENABLE_WOFF2=OFF -DENABLE_LIBGIF=OFF
cmake --build "fontforge-${FF_VER}/build" --parallel
cmake --install "fontforge-${FF_VER}/build"

# ---------- Poppler (xpdf/unstable headers) ----------
echo "=== Poppler ${POPLER_VER} ==="
cd "$BUILD"
POPLER_TARBALL="poppler-${POPLER_VER}.tar.xz"
[ -f "$POPLER_TARBALL" ] || curl -L -o "$POPLER_TARBALL" "https://poppler.freedesktop.org/poppler-${POPLER_VER}.tar.xz"
rm -rf "poppler-${POPLER_VER}"
tar -xf "$POPLER_TARBALL"
cmake -S "poppler-${POPLER_VER}" -B "poppler-${POPLER_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF -DENABLE_GLIB=OFF \
  -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_GTK_TESTS=OFF
cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# ---------- pdf2htmlEX ----------
echo "=== pdf2htmlEX (master) ==="
cd "$BUILD"
rm -rf pdf2htmlEX
git clone --depth=1 https://github.com/pdf2htmlEX/pdf2htmlEX.git
cmake -S pdf2htmlEX -B pdf2htmlEX/build \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_SVG=ON
cmake --build pdf2htmlEX/build --parallel
cmake --install pdf2htmlEX/build

# ---------- Stage portable bundle ----------
echo "=== Stage portable bundle ==="
mkdir -p "${STAGE}/bin" "${STAGE}/share"
cp -v "${PREFIX}/bin/pdf2htmlEX.exe" "${STAGE}/bin/"
[ -d "${PREFIX}/share/pdf2htmlEX" ] && cp -Rv "${PREFIX}/share/pdf2htmlEX" "${STAGE}/share/" || true
[ -d "${PREFIX}/share/poppler"   ] && cp -Rv "${PREFIX}/share/poppler"   "${STAGE}/share/" || true

# grab dependent DLLs
ntldd -R "${STAGE}/bin/pdf2htmlEX.exe" \
  | awk '/=>/ {print $3}' \
  | sed -e 's#\\#/#g' \
  | sort -u \
  | while read -r dll; do
      [ -f "$dll" ] && cp -v "$dll" "${STAGE}/bin/" || true
    done

mkdir -p "$DIST"
cd "$STAGE/.."
zip -r "${DIST}/pdf2htmlEX-windows-portable.zip" "stage"
echo "Artifact ready at ${DIST}/pdf2htmlEX-windows-portable.zip"
