#!/usr/bin/env bash
set -euxo pipefail

# --- MinGW toolchain + Ninja --------------------------------------------------
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

POPLER_VER="0.89.0"      # good match for pdf2htmlEX v0.18.8.rc1
PDF2_TAG="v0.18.8.rc1"

mkdir -p "$BUILD" "$STAGE" "$DIST"

# --------------------------------------------------------------------
# Use prebuilt FontForge (MSYS2). Avoids flaky source build.
# --------------------------------------------------------------------

# ---------- Poppler (WITH GLib wrapper) ---------------------------------------
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
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF \
  -DENABLE_GLIB=ON \        # <— enable poppler-glib so pdf2htmlEX can link
  -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_GTK_TESTS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# Verify pkg-config can see poppler-glib (guards against the previous error)
pkg-config --modversion poppler-glib

# ---------- pdf2htmlEX (release tag) ------------------------------------------
echo "=== pdf2htmlEX ${PDF2_TAG} ==="
cd "$BUILD"
PDF2_TARBALL="pdf2htmlEX-${PDF2_TAG}.tar.gz"
[ -f "$PDF2_TARBALL" ] || curl -L -o "$PDF2_TARBALL" \
  "https://github.com/pdf2htmlEX/pdf2htmlEX/archive/refs/tags/${PDF2_TAG}.tar.gz"

rm -rf "pdf2htmlEX-src"
mkdir "pdf2htmlEX-src"
tar -xf "$PDF2_TARBALL" -C "pdf2htmlEX-src" --strip-components=1

# Release tar layout: CMakeLists may be under ./pdf2htmlEX/
SRC_DIR="pdf2htmlEX-src"
if [ -f "${SRC_DIR}/CMakeLists.txt" ]; then
  PDF2_SRC="${SRC_DIR}"
elif [ -f "${SRC_DIR}/pdf2htmlEX/CMakeLists.txt" ]; then
  PDF2_SRC="${SRC_DIR}/pdf2htmlEX"
else
  echo "Could not find CMakeLists.txt in ${SRC_DIR}"
  find "${SRC_DIR}" -maxdepth 2 -name CMakeLists.txt -print
  exit 1
fi

# Some tags configure a test template; disable tests and provide a stub.
if [ ! -f "${PDF2_SRC}/test/test.py.in" ]; then
  echo "Synthesizing placeholder test.py.in (tests disabled)…"
  mkdir -p "${PDF2_SRC}/test"
  cat > "${PDF2_SRC}/test/test.py.in" <<'EOF'
#!/usr/bin/env @PYTHON@
# Placeholder for CI builds; tests disabled.
if __name__ == "__main__":
    print("pdf2htmlEX tests disabled")
EOF
fi

echo "Using source dir: ${PDF2_SRC}"
ls -al "${PDF2_SRC}"

# Tell CMake to use the installed (pkg-config visible) poppler/glib
cmake -S "${PDF2_SRC}" -B "${PDF2_SRC}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${PREFIX}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_SVG=ON \
  -DBUILD_TESTING=OFF -DENABLE_TESTS=OFF -DPDF2HTMLEX_BUILD_TESTS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --build "${PDF2_SRC}/build" --parallel
cmake --install "${PDF2_SRC}/build"

# ---------- Stage portable bundle ---------------------------------------------
echo "=== Stage portable bundle ==="
mkdir -p "${STAGE}/bin" "${STAGE}/share"

# exe
cp -v "${PREFIX}/bin/pdf2htmlEX.exe" "${STAGE}/bin/"

# runtime data
[ -d "${PREFIX}/share/pdf2htmlEX" ] && cp -Rv "${PREFIX}/share/pdf2htmlEX" "${STAGE}/share/" || true
[ -d "${PREFIX}/share/poppler"   ] && cp -Rv "${PREFIX}/share/poppler"   "${STAGE}/share/" || true

# dependent DLLs next to exe
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
