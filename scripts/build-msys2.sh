#!/usr/bin/env bash
set -euxo pipefail

# Toolchain
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export PKG_CONFIG=/mingw64/bin/pkg-config
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig:/mingw64/share/pkgconfig
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CMAKE_BUILD_PARALLEL_LEVEL=4

echo "=== versions ==="
cmake --version
ninja --version
$CC --version | head -1
pkg-config --version

PREFIX=/mingw64
ROOT="$PWD"
BUILD="$ROOT/.build"
STAGE="$ROOT/stage"
DIST="$ROOT/dist"
mkdir -p "$BUILD" "$STAGE" "$DIST"

# Poppler with GLib (version with GLib fixes that builds on modern GCC)
POPLER_VER="21.06.1"
POPLER_TARBALL="poppler-${POPLER_VER}.tar.xz"
POPLER_URL="https://poppler.freedesktop.org/${POPLER_TARBALL}"

# ---- Build Poppler (GLib ON, Qt OFF) -----------------------------------------
cd "$BUILD"
[ -f "$POPLER_TARBALL" ] || curl -L -o "$POPLER_TARBALL" "$POPLER_URL"
rm -rf "poppler-${POPLER_VER}"
tar -xf "$POPLER_TARBALL"

cmake -S "poppler-${POPLER_VER}" -B "poppler-${POPLER_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF \
  -DENABLE_GLIB=ON \
  -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_GTK_TESTS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# sanity: ensure GLib pc file is visible
pkg-config --modversion poppler-glib

# ---- Build pdf2htmlEX (active upstream) --------------------------------------
cd "$BUILD"
if [ ! -d pdf2htmlEX-src ]; then
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git pdf2htmlEX-src
fi
PDF2_SRC="pdf2htmlEX-src"
[ -f "${PDF2_SRC}/CMakeLists.txt" ] || PDF2_SRC="${PDF2_SRC}/pdf2htmlEX"

# Patch all CMakeLists to >= 3.5 (avoid modern CMake policy gate)
find "$PDF2_SRC" -name CMakeLists.txt -print0 | \
  xargs -0 -I{} sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# Disable tests and ensure template exists (some tags reference it)
if [ ! -f "${PDF2_SRC}/test/test.py.in" ]; then
  mkdir -p "${PDF2_SRC}/test"
  cat > "${PDF2_SRC}/test/test.py.in" <<'EOF'
#!/usr/bin/env @PYTHON@
print("pdf2htmlEX tests disabled for CI")
EOF
fi

# Configure: Boost OFF (recommended-but-optional), Qt will be found if needed
cmake -S "${PDF2_SRC}" -B "${PDF2_SRC}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${PREFIX}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_SVG=ON \
  -DENABLE_BOOST=OFF \
  -DBUILD_TESTING=OFF -DENABLE_TESTS=OFF -DPDF2HTMLEX_BUILD_TESTS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --build "${PDF2_SRC}/build" --parallel
cmake --install "${PDF2_SRC}/build"

# ---- Stage portable bundle ----------------------------------------------------
mkdir -p "${STAGE}/bin" "${STAGE}/share"
cp -v "${PREFIX}/bin/pdf2htmlEX.exe" "${STAGE}/bin/"
[ -d "${PREFIX}/share/pdf2htmlEX" ] && cp -Rv "${PREFIX}/share/pdf2htmlEX" "${STAGE}/share/" || true
[ -d "${PREFIX}/share/poppler"   ] && cp -Rv "${PREFIX}/share/poppler"   "${STAGE}/share/" || true

# Pull dependent DLLs next to the exe
ntldd -R "${STAGE}/bin/pdf2htmlEX.exe" \
  | awk '/=>/ {print $3}' \
  | sed -e 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -v "$dll" "${STAGE}/bin/" || true; done

mkdir -p "$DIST"
cd "$STAGE/.."
zip -r "${DIST}/pdf2htmlEX-windows-portable.zip" "stage"
echo "OK: ${DIST}/pdf2htmlEX-windows-portable.zip"
