#!/usr/bin/env bash
set -euxo pipefail

# Toolchain & paths
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export PKG_CONFIG=/mingw64/bin/pkg-config
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
export CMAKE_BUILD_PARALLEL_LEVEL=4

ROOT="$(pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
STAGE="$ROOT/stage"
mkdir -p "$BUILD" "$DIST" "$STAGE"

echo "=== versions ==="
cmake --version
ninja --version
$CC --version | head -1
pkg-config --version

# ------------------- 1) Build static Poppler (21.06.1, GLib ON) ----------------
POPLER_VER="21.06.1"
POPLER_TARBALL="poppler-${POPLER_VER}.tar.xz"
POPLER_URL="https://poppler.freedesktop.org/${POPLER_TARBALL}"

cd "$BUILD"
[ -d "poppler-${POPLER_VER}" ] || { curl -L "$POPLER_URL" -o "$POPLER_TARBALL"; tar -xf "$POPLER_TARBALL"; }

cmake -S "poppler-${POPLER_VER}" -B "poppler-${POPLER_VER}/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_UNSTABLE_API_ABI_HEADERS=ON \
  -DENABLE_UTILS=OFF -DENABLE_GTK_DOC=OFF \
  -DENABLE_GLIB=ON \
  -DENABLE_CPP=ON \
  -DENABLE_QT5=OFF -DENABLE_QT6=OFF

cmake --build "poppler-${POPLER_VER}/build" --parallel
cmake --install "poppler-${POPLER_VER}/build"

# Paths to the static libs we just built
POP_BUILD="poppler-${POPLER_VER}/build"
LIB_POPPLER="$BUILD/$POP_BUILD/poppler/libpoppler.a"
LIB_POPPLER_GLIB="$BUILD/$POP_BUILD/glib/libpoppler-glib.a"
LIB_POPPLER_CPP="$BUILD/$POP_BUILD/cpp/libpoppler-cpp.a"

# ------------------- 2) Get pdf2htmlEX sources ---------------------------------
PDF2_DIR="$BUILD/pdf2htmlEX-src"
if [ ! -d "$PDF2_DIR" ]; then
  git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"
fi

# Repo sometimes nests the project in ./pdf2htmlEX/
if [ -f "$PDF2_DIR/CMakeLists.txt" ]; then
  PDF2_SRC="$PDF2_DIR"
else
  PDF2_SRC="$PDF2_DIR/pdf2htmlEX"
fi

# Make the path layout that its CMake expects:
#   ../poppler/build/{poppler,glib,cpp}/libpoppler*.a
LOCAL_POP="$PDF2_SRC/../poppler/build"
mkdir -p "$LOCAL_POP/poppler" "$LOCAL_POP/glib" "$LOCAL_POP/cpp"
cp -f "$LIB_POPPLER"      "$LOCAL_POP/poppler/"    # libpoppler.a
cp -f "$LIB_POPPLER_GLIB" "$LOCAL_POP/glib/"       # libpoppler-glib.a
[ -f "$LIB_POPPLER_CPP" ] && cp -f "$LIB_POPPLER_CPP" "$LOCAL_POP/cpp/" || true

# Some branches expect a test template; drop a stub to keep configure happy
if [ ! -f "$PDF2_SRC/test/test.py.in" ]; then
  mkdir -p "$PDF2_SRC/test"
  cat > "$PDF2_SRC/test/test.py.in" <<'EOF'
#!/usr/bin/env @PYTHON@
print("tests disabled in CI")
EOF
fi

# Normalize minimum CMake (avoid policy nags)
find "$PDF2_SRC" -name CMakeLists.txt -print0 | \
  xargs -0 -I{} sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# ------------------- 3) Configure & build pdf2htmlEX ---------------------------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 -DCMAKE_INSTALL_PREFIX=/mingw64

cmake --build "$PDF2_SRC/build" --parallel

# ------------------- 4) Stage a portable bundle --------------------------------
EXE="$PDF2_SRC/build/pdf2htmlEX.exe"
cp -f "$EXE" "$STAGE/"

# Use ntldd to pull in runtime DLLs next to the exe
ntldd -R "$STAGE/pdf2htmlEX.exe" \
  | awk '/=>/ {print $3}' \
  | sed 's#\\#/#g' | sort -u \
  | while read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$STAGE/" || true; done

mkdir -p "$DIST"
(cd "$STAGE/.." && zip -r "$DIST/pdf2htmlEX-windows-portable.zip" "$(basename "$STAGE")")
echo "OK -> $DIST/pdf2htmlEX-windows-portable.zip"
