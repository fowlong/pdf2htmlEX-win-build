#!/usr/bin/env bash
set -euxo pipefail

# Use MinGW toolchain + Ninja
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export PKG_CONFIG=/mingw64/bin/pkg-config
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig:/mingw64/share/pkgconfig
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CMAKE_BUILD_PARALLEL_LEVEL=4

echo "=== tool versions ==="
cmake --version
ninja --version
$CC --version | head -1
pkg-config --version

trap 'echo "---- CMake logs ----";
      find "$PWD" -name CMakeError.log -o -name CMakeOutput.log -print -exec sed -n "1,160p" "{}" \; || true' ERR

PREFIX=/mingw64
ROOT="$PWD"
BUILD="$ROOT/.build"
STAGE="$ROOT/stage"
DIST="$ROOT/dist"

POPLER_VER="0.89.0"          # official target for pdf2htmlEX v0.18.8.rc1
PDF2_TAG="v0.18.8.rc1"       # build this tag to ensure CMakeLists is present

mkdir -p "$BUILD" "$STAGE" "$DIST"

# --------------------------------------------------------------------
# We use prebuilt FontForge (MSYS2 package). No fragile source build.
# --------------------------------------------------------------------

# ---------- Poppler (with "xpdf/unstable" headers) ----------
echo "=== Poppler ${POPLER_VER} ==="
cd "$BUILD"
POPLER_TARBALL="poppler-${POPLER_VER}.tar.xz"
[ -f "$POPLER_TARBALL" ] || curl -L -o "$POPLER_TARBALL" "https://poppler.freedesktop.org/poppler-${POPLER_VER}.tar.xz"
rm -rf "poppler-${POPLER_VER}"
tar -xf "$POPLER_TARBALL"
cmake -S "poppler-${POPLER_VER}" -B "poppler-${POPLER_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF -DENABLE_GLIB=OFF \
  -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_GTK_TESTS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# ---------- pdf2htmlEX (release tag) ----------
echo "=== pdf2htmlEX ${PDF2_TAG} ==="
cd "$BUILD"
PDF2_TARBALL="pdf2htmlEX-${PDF2_TAG}.tar.gz"
[ -f "$PDF2_TARBALL" ] || curl -L -o "$PDF2_TARBALL" "https://github.com/pdf2htmlEX/pdf2htmlEX/archive/refs/tags/${PDF2_TAG}.tar.gz"
rm -rf "pdf2htmlEX-src"
mkdir "pdf2htmlEX-src"
tar -xf "$PDF2_TARBALL" -C "pdf2htmlEX-src" --strip-components=1

cmake -S "pdf2htmlEX-src" -B "pdf2htmlEX-src/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${PREFIX}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_SVG=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "pdf2htmlEX-src/build" --parallel
cmake --install "pdf2htmlEX-src/build"

# ---------- Stage portable bundle ----------
echo "=== Stage portable bundle ==="
mkdir -p "${STAGE}/bin" "${STAGE}/share"
cp -v "${PREFIX}/bin/pdf2htmlEX.exe" "${STAGE}/bin/"
[ -d "${PREFIX}/share/pdf2htmlEX" ] && cp -Rv "${PREFIX}/share/pdf2htmlEX" "${STAGE}/share/" || true
[ -d "${PREFIX}/share/poppler"   ] && cp -Rv "${PREFIX}/share/poppler"   "${STAGE}/share/" || true

# collect dependent DLLs
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
