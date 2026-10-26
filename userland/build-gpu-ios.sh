#!/bin/bash
# Build the iOS-side GPU userland on a Mac (local or the GitHub macos runner):
#   out/libOSMesa.8.dylib        Mesa 25.0.7 (freedreno + softpipe) behind OSMesa  -> /topaz/lib/
#   out/libtopaz-gl.dylib        OpenGL ES behind EAGLContext (gpu/eagl.c + gpu/gl_osmesa.c)
#   out/libtopaz-inject.dylib    inserted into backboardd (gpu/topaz_inject.c); loads libtopaz-gl
# All three are ad-hoc signed. Install them in the iOS root under /topaz/lib and start backboardd
# with boot-arg  topaz_inject=/topaz/lib/libtopaz-inject.dylib,backboardd  (kern.exec_inject).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$ROOT/build-mesa" "$ROOT/out"
bash "$ROOT/mk-mesa-mac.sh"
M=$ROOT/build-mesa/out
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
DYN=("$CC" -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wno-deprecated-declarations)
O=$ROOT/build-gpu
rm -rf "$O"; mkdir -p "$O"
python3 "$ROOT/gpu/mkeagl.py" "$ROOT/gpu/eagl_slots.txt" "$M/gl.xml" "$M/exported-gl.txt" "$ROOT/gpu/eagl.c" > "$O/eagl_gen.h"
"${DYN[@]}" -dynamiclib -install_name /topaz/lib/libtopaz-gl.dylib -I"$O" -I"$ROOT/gpu" \
	-framework CoreFoundation -framework IOKit -framework IOSurface -lobjc "$M/libOSMesa.8.dylib" \
	-o "$O/libtopaz-gl.dylib" "$ROOT/gpu/eagl.c" "$ROOT/gpu/gl_osmesa.c"
"${DYN[@]}" -dynamiclib -install_name /topaz/lib/libtopaz-inject.dylib -I"$ROOT/gpu" \
	-framework CoreFoundation -framework IOKit -lobjc \
	-o "$O/libtopaz-inject.dylib" "$ROOT/gpu/topaz_inject.c"
cp "$M/libOSMesa.8.dylib" "$O/"
for f in "$O"/*.dylib; do codesign --force -s - "$f"; done
cp "$O"/*.dylib "$ROOT/out/"
ls -l "$ROOT/out"
