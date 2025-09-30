#!/usr/bin/env bash
set -euxo pipefail

# -------- toolchain ----------
export PATH=/mingw64/bin:/usr/bin:$PATH
export CC=/mingw64/bin/gcc.exe
export CXX=/mingw64/bin/g++.exe
export RC=/mingw64/bin/windres.exe
export CMAKE_GENERATOR="Ninja"
export CMAKE_MAKE_PROGRAM=/mingw64/bin/ninja.exe

# make missing <optional> includes a no-op (some files forget to include it)
# also ensure the compiler can always see Poppler headers directly
export CXXFLAGS="${CXXFLAGS:-} -include optional -I/mingw64/include/poppler"

# -------- deps (correct names; no poppler-glib/cpp subpackages) ----------
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
  cmake ninja git curl zip

# -------- pull sources ----------
ROOT="$(pwd)"
BUILD="$ROOT/.build"
PDF2_DIR="$BUILD/pdf2htmlEX-src"
[ -d "$PDF2_DIR" ] || git clone --depth 1 https://github.com/pdf2htmlEX/pdf2htmlEX.git "$PDF2_DIR"

PDF2_SRC="$PDF2_DIR"
# some repos have the project in a subdir
[ -f "$PDF2_SRC/CMakeLists.txt" ] || PDF2_SRC="$PDF2_DIR/pdf2htmlEX"

# -------- provide vendor libs/headers from system Poppler ----------
# We do NOT build Poppler ourselves. We vendor the MSYS2-provided libs
# so pdf2htmlEX's CMake finds them in its expected layout.
VENDOR_POP_ROOT="$PDF2_SRC/../poppler/build"
VENDOR_POP_SUB="$VENDOR_POP_ROOT/poppler"
VENDOR_GLIB_SUB="$VENDOR_POP_ROOT/glib"
VENDOR_CPP_SUB="$VENDOR_POP_ROOT/cpp"
mkdir -p "$VENDOR_POP_SUB" "$VENDOR_GLIB_SUB" "$VENDOR_CPP_SUB"

# import libraries
cp -f /mingw64/lib/libpoppler*.a         "$VENDOR_POP_ROOT/"     || true
cp -f /mingw64/lib/libpoppler*.a         "$VENDOR_POP_SUB/"       || true
cp -f /mingw64/lib/libpoppler-glib*.a    "$VENDOR_GLIB_SUB/"      || true
cp -f /mingw64/lib/libpoppler-cpp*.a     "$VENDOR_CPP_SUB/"       || true

# headers: rely on -I/mingw64/include/poppler via CXXFLAGS so we don’t copy stale trees

# -------- FontForge import libs (generate if missing) ----------
VENDOR_FF_LIB="$PDF2_SRC/../fontforge/build/lib"
mkdir -p "$VENDOR_FF_LIB"

synth_from_dll() { # $1=basename (e.g. fontforge)  $2=out.a
  local base="$1" out="$2" dll=""
  # try lib${base}.dll or lib${base}-*.dll
  for pat in "/mingw64/bin/lib${base}-"*.dll "/mingw64/bin/lib${base}.dll"; do
    for f in $pat; do
      [ -f "$f" ] && { dll="$f"; break; }
    done
    [ -n "$dll" ] && break
  done
  [ -z "$dll" ] && { echo "NOTE: No DLL for ${base}; skipping synth"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  ( set -e; cd "$tmp"; gendef "$dll"; dlltool -d *.def -l "$out" )
  rm -rf "$tmp"
}

for L in fontforge gutils gunicode uninameslist; do
  if compgen -G "/mingw64/lib/lib${L}.a" >/dev/null || compgen -G "/mingw64/lib/lib${L}.dll.a" >/dev/null; then
    cp -f /mingw64/lib/lib${L}*.a "$VENDOR_FF_LIB/" || true
  else
    synth_from_dll "$L" "$VENDOR_FF_LIB/lib${L}.a"
  fi
done

# -------- small cmake compatibility shim ----------
# Some forks use old cmake mins; normalize quietly.
find "$PDF2_SRC" -name CMakeLists.txt -print0 | xargs -0 -I{} \
  sed -i -E 's/^[[:space:]]*cmake_minimum_required\s*\([^)]*\)/cmake_minimum_required(VERSION 3.5)/I' {}

# If the test harness file is missing, create a tiny placeholder.
[ -f "$PDF2_SRC/test/test.py.in" ] || {
  mkdir -p "$PDF2_SRC/test"
  printf '%s\n' '#!/usr/bin/env @PYTHON@' 'print("tests disabled")' > "$PDF2_SRC/test/test.py.in"
}

# -------- configure & build ----------
cmake -S "$PDF2_SRC" -B "$PDF2_SRC/build" \
  -G "$CMAKE_GENERATOR" \
  -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_RC_COMPILER="$RC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/mingw64 \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"

cmake --build "$PDF2_SRC/build" --parallel
