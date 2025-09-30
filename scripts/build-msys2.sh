# --- toolchain ---
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe
# make any missing <optional> includes harmless
export CXXFLAGS="${CXXFLAGS:-} -include optional"

# --- install system dependencies (correct package names) ---
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
  git curl zip

# --- clone pdf2htmlEX ---
ROOT="$(pwd)"
BUILD="$ROOT/.build"
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"
PDF2_SRC="$PDF2_DIR"
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# --- vendor poppler headers/libs from MSYS2 (no local poppler build!) ---
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

# import libs as .a (MSYS2 packages provide them)
cp -f /mingw64/lib/libpoppler*.a "$VENDOR_POP_ROOT/" || true
cp -f /mingw64/lib/libpoppler*.a "$VENDOR_POP_SUB/" || true
cp -f /mingw64/lib/libpoppler-glib*.a "$VENDOR_GLIB_SUB/" || true
cp -f /mingw64/lib/libpoppler-cpp*.a "$VENDOR_CPP_SUB/" || true

# headers (copy whole tree so pdf2htmlEX includes resolve)
VENDOR_POP_HEADERS="$PDF2_SRC/../poppler/poppler"
mkdir -p "$VENDOR_POP_HEADERS"
cp -a /mingw64/include/poppler/* "$VENDOR_POP_HEADERS/"

# --- FontForge import libs (synthesize if pacman didn’t ship a static import) ---
mkdir -p "$PDF2_SRC/../fontforge/build/lib"
synth() { # $1=base $2=out.a
  local base="$1" out="$2" dll=""
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do [ -f "$f" ] && { dll="$f"; break; }; done
    [ -n "$dll" ] && break
  done
  [ -z "$dll" ] && { echo "NOTE: no $base DLL; skipping synth"; return 0; }
  local tmp; tmp="$(mktemp -d)"; (
    set -e; cd "$tmp"; gendef "$dll"; dlltool -d *.def -l "$out"
  ); rm -rf "$tmp"
}
for L in fontforge gutils gunicode uninameslist; do
  if [ -f "/mingw64/lib/lib${L}.a" ] || [ -f "/mingw64/lib/lib${L}.dll.a" ]; then
    cp -f /mingw64/lib/lib${L}*.a "$PDF2_SRC/../fontforge/build/lib/" || true
  else
    synth "$L" "$PDF2_SRC/../fontforge/build/lib/lib${L}.a"
  fi
done

# --- minimal test stub + cmake compatibility shim ---
[ -f "$PDF2_SRC/test/test.py.in" ] || { mkdir -p "$PDF2_SRC/test"; printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"; }
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# --- configure & build ---
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/mingw64 -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"
cmake --build "$PDF2_SRC/build" --parallel
