#!/usr/bin/env bash
set -euxo pipefail

# All work happens inside MSYS2's MINGW64 env on the Actions runner
PREFIX=/mingw64
ROOT="$PWD"
BUILD_DIR="$ROOT/.build"
STAGE="$ROOT/stage"
DIST="$ROOT/dist"

# Versions pinned to what pdf2htmlEX supports
# Ref: pdf2htmlEX v0.18.8.rc1 notes (Poppler 0.89.0, FontForge 20200314)
POPLER_VER="0.89.0"
FF_VER="20200314"

mkdir -p "$BUILD_DIR" "$STAGE" "$DIST"

echo "=== Build FontForge ${FF_VER} (no GUI, no Python) ==="
cd "$BUILD_DIR"
# Official 20200314 source tarball mirrors
# (Choose one; SourceForge mirror used here.)
FF_TARBALL="fontforge-${FF_VER}.tar.xz"
if [ ! -f "$FF_TARBALL" ]; then
  curl -L -o "$FF_TARBALL" "https://sourceforge.net/projects/fontforge.mirror/files/${FF_VER}/fontforge-${FF_VER}.tar.xz/download"
fi
tar -xf "$FF_TARBALL"
mkdir -p "fontforge-${FF_VER}/build" && cd "fontforge-${FF_VER}/build"

cmake -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_GUI=OFF -DENABLE_X11=OFF \
  -DENABLE_PYTHON_SCRIPTING=OFF -DENABLE_PYTHON_EXTENSION=OFF \
  -DENABLE_LIBSPIRO=ON -DENABLE_LIBGIF=OFF -DENABLE_WOFF2=OFF \
  ..
cmake --build . --parallel
cmake --install .
cd "$BUILD_DIR"

echo "=== Build Poppler ${POPLER_VER} with UNSTABLE/XPDF headers ==="
POPLER_TARBALL="poppler-${POPLER_VER}.tar.xz"
if [ ! -f "$POPLER_TARBALL" ]; then
  curl -L -o "$POPLER_TARBALL" "https://poppler.freedesktop.org/poppler-${POPLER_VER}.tar.xz"
fi
tar -xf "$POPLER_TARBALL"
mkdir -p "poppler-${POPLER_VER}/build" && cd "poppler-${POPLER_VER}/build"

# IMPORTANT: headers switch changed to -DENABLE_UNSTABLE_API_ABI_HEADERS=ON
# (needed by pdf2htmlEX)
cmake -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF \
  -DENABLE_GTK_DOC=OFF \
  -DENABLE_GLIB=OFF \
  -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_GTK_TESTS=OFF \
  ..
cmake --build . --parallel
cmake --install .
cd "$BUILD_DIR"

echo "=== Build pdf2htmlEX (master) ==="
if [ ! -d pdf2htmlEX ]; then
  git clone --depth=1 https://github.com/pdf2htmlEX/pdf2htmlEX.git
fi
cd pdf2htmlEX
mkdir -p build && cd build

# pdf2htmlEX upstream uses CMake; ENABLE_SVG optional
cmake -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DENABLE_SVG=ON \
  ..
cmake --build . --parallel
cmake --install .

echo "=== Stage portable bundle ==="
mkdir -p "${STAGE}/bin" "${STAGE}/share"
# main exe
cp -v "${PREFIX}/bin/pdf2htmlEX.exe" "${STAGE}/bin/"
# runtime data
if [ -d "${PREFIX}/share/pdf2htmlEX" ]; then
  cp -Rv "${PREFIX}/share/pdf2htmlEX" "${STAGE}/share/"
fi
# poppler data (CJK encodings etc.)
if [ -d "${PREFIX}/share/poppler" ]; then
  cp -Rv "${PREFIX}/share/poppler" "${STAGE}/share/"
fi

# pull in all dependent DLLs
echo "Collecting dependent DLLs..."
# ntldd prints dependency mapping; copy only existing files
ntldd -R "${STAGE}/bin/pdf2htmlEX.exe" \
  | awk '/=>/ {print $3}' \
  | sed -e 's#\\#/#g' \
  | sort -u \
  | while read -r dll; do
      if [ -f "$dll" ]; then
        cp -v "$dll" "${STAGE}/bin/" || true
      fi
    done

# Zip it
echo "=== Create zip artifact ==="
cd "$STAGE/.."
zip -r "${DIST}/pdf2htmlEX-windows-portable.zip" "stage"

echo "Done. Artifact at: ${DIST}/pdf2htmlEX-windows-portable.zip"
