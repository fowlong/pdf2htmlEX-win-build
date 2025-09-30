#!/usr/bin/env bash
set -euxo pipefail

# Workspace
ROOT="$(pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
mkdir -p "$BUILD" "$DIST"

# Versions locked to what is known to build together.
# pdf2htmlEX v0.18.8.rc1 pairs with poppler 0.89.0.
POPLER_VER="poppler-0.89.0"
POPLER_URL="https://poppler.freedesktop.org/${POPLER_VER}.tar.xz"
PDF2_VER_TAG="v0.18.8.rc1"
PDF2_REPO="https://github.com/pdf2htmlEX/pdf2htmlEX.git"

# ---------- 1) Build static Poppler 0.89.0 ----------
cd "$BUILD"
if [ ! -d "$POPLER_VER" ]; then
  curl -L "$POPLER_URL" -o "${POPLER_VER}.tar.xz"
  tar xJf "${POPLER_VER}.tar.xz"
fi

mkdir -p poppler-build
cmake -S "$POPLER_VER" -B poppler-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_CPP=OFF \
  -DENABLE_UTILS=OFF \
  -DENABLE_GLIB=ON \
  -DENABLE_QT5=OFF \
  -DENABLE_QT6=OFF \
  -DWITH_NSS3=OFF \
  -DTESTDATADIR=""

cmake --build poppler-build --parallel
cmake --install poppler-build

# ---------- 2) Clone pdf2htmlEX sources ----------
if [ ! -d "pdf2htmlEX-src" ]; then
  git clone --depth 1 --branch "$PDF2_VER_TAG" "$PDF2_REPO" pdf2htmlEX-src
fi

# pdf2htmlEX places top-level CMakeLists.txt in subdir 'pdf2htmlEX'
PDF2_DIR="pdf2htmlEX-src/pdf2htmlEX"

# Some CMake versions complain unless min version is at the top;
# ensure it's compatible with our runner (3.5+ is OK).
# Also keep tests happy even though we won't run them.
if [ ! -f "$PDF2_DIR/test/test.py.in" ]; then
  mkdir -p "$PDF2_DIR/test"
  cat > "$PDF2_DIR/test/test.py.in" <<'PY'
#!/usr/bin/env python3
print("noop test stub")
PY
fi

# ---------- 3) Make Poppler static libs available where pdf2htmlEX expects ----------
# pdf2htmlEX historically looks under ../poppler/build/{poppler,glib}
# Mirror that layout and copy the freshly built static libs there.
LOCAL_POPPLER_ROOT="$PDF2_DIR/../poppler/build"
mkdir -p "$LOCAL_POPPLER_ROOT/poppler" "$LOCAL_POPPLER_ROOT/glib"

# copy core & glib static libs from our poppler build tree
# (Ninja puts them under these subdirs in the build tree)
cp -f "$BUILD/poppler-build/poppler/libpoppler.a"      "$LOCAL_POPPLER_ROOT/poppler/" || true
cp -f "$BUILD/poppler-build/glib/libpoppler-glib.a"    "$LOCAL_POPPLER_ROOT/glib/"    || true

# Sanity check – fail early if static archives are missing
test -f "$LOCAL_POPPLER_ROOT/poppler/libpoppler.a"
test -f "$LOCAL_POPPLER_ROOT/glib/libpoppler-glib.a"

# ---------- 4) Configure & build pdf2htmlEX ----------
mkdir -p "$PDF2_DIR/build"

# Patch CMake minimum version inside subproject if needed (be tolerant)
# This avoids the "CMake < 3.5 removed policy" errors on Actions.
sed -i -E '1,/^project\(/ s/^([[:space:]]*)cmake_minimum_required\(.*\)$/cmake_minimum_required(VERSION 3.5)/I' \
  "$PDF2_DIR/CMakeLists.txt" || true

cmake -S "$PDF2_DIR" -B "$PDF2_DIR/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe \
  -DCMAKE_C_COMPILER=/mingw64/bin/gcc.exe \
  -DCMAKE_CXX_COMPILER=/mingw64/bin/g++.exe \
  -DCMAKE_RC_COMPILER=/mingw64/bin/windres.exe \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64

cmake --build "$PDF2_DIR/build" --parallel

# ---------- 5) Stage a minimal portable bundle ----------
EXE="$PDF2_DIR/build/pdf2htmlEX.exe"
cp -f "$EXE" "$DIST/"

# Pull in the DLLs pdf2htmlEX needs at runtime (cairo, glib, freetype, etc.)
# Note: This makes a "fat" portable folder so users can run the exe standalone.
need () { pacman -Ql "$1" | awk '/\/bin\/[^/]+\.dll$/ {print $2}'; }

DLLS=()
DLLS+=($(need mingw-w64-x86_64-glib2))
DLLS+=($(need mingw-w64-x86_64-cairo))
DLLS+=($(need mingw-w64-x86_64-freetype))
DLLS+=($(need mingw-w64-x86_64-fontconfig))
DLLS+=($(need mingw-w64-x86_64-libpng))
DLLS+=($(need mingw-w64-x86_64-libjpeg-turbo))
DLLS+=($(need mingw-w64-x86_64-libtiff))
DLLS+=($(need mingw-w64-x86_64-openjpeg2))
DLLS+=($(need mingw-w64-x86_64-lcms2))
DLLS+=($(need mingw-w64-x86_64-libxml2))
DLLS+=($(need mingw-w64-x86_64-zlib))
DLLS+=($(need mingw-w64-x86_64-harfbuzz))
DLLS+=($(need mingw-w64-x86_64-libcurl))

for f in "${DLLS[@]}"; do
  [ -f "$f" ] && cp -n "$f" "$DIST/" || true
done

# Poppler is statically linked; but if anything dynamic slips through, add its DLLs too (defensive).
if ls /mingw64/bin/libpoppler*.dll >/dev/null 2>&1; then
  cp -n /mingw64/bin/libpoppler*.dll "$DIST/" || true
fi

echo "Done. Artifact staged in: $DIST"
