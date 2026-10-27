#!/bin/sh
# Build SafeJSC's JSC-internals backend against one WebKit build:
#   Internals/build-internals.sh [WEBKIT_BUILD_DIR] [OUT_DYLIB]
# (default WebKitBuild/Release at the top of this checkout, /tmp/libSafeJSCInternals.dylib). The dylib is
# loaded by whoever wants the backend (PerfBench internals=PATH); SafeJSC finds it by dlsym,
# and it activates only when that same WebKit build's JavaScriptCore is the one loaded
# (DYLD_FRAMEWORK_PATH=WEBKIT_BUILD_DIR).
set -e
W=${1:-$(cd "$(dirname "$0")/../../../../.." && pwd)/WebKitBuild/Release}
OUT=${2:-/tmp/libSafeJSCInternals.dylib}
HERE=$(cd "$(dirname "$0")" && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
IMAGE="$W/JavaScriptCore.framework/Versions/A/JavaScriptCore"
xcrun clang++ -std=c++2b -O3 -dynamiclib -o "$OUT" "$HERE/SafeJSCInternals.cpp" \
  -I"$HERE/../CJSCKeepAlive/include" -I"$W/usr/local/include" -F"$W" -iframework "$W" \
  -framework JavaScriptCore -DNDEBUG -fno-exceptions -fno-rtti -fvisibility=hidden -Wno-everything \
  -DSAFEJSC_INTERNALS_JSC_IMAGE="\"$IMAGE\"" \
  -Wl,-exported_symbol,_safejsc_internals_v1 -install_name "$OUT"
echo "$OUT (for $IMAGE)"
