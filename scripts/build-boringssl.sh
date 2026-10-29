#!/usr/bin/env bash
# Builds BoringSSL (libcrypto + libssl) as static libraries for iOS arm64 devices
# into Vendor/boringssl/{include,lib}. Runs on macOS (GitHub Actions runner).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/boringssl"
WORK="${RUNNER_TEMP:-/tmp}/boringssl-src"
REF="${BORINGSSL_REF:-main}"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

rm -rf "$WORK"
git clone --depth 1 --branch "$REF" https://github.com/google/boringssl.git "$WORK"
echo "BoringSSL commit: $(git -C "$WORK" rev-parse HEAD)"

cmake -S "$WORK" -B "$WORK/build-ios" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DBUILD_TESTING=OFF

cmake --build "$WORK/build-ios" --target crypto ssl --config Release -j "$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$WORK/include" "$OUT/include"
find "$WORK/build-ios" -name libcrypto.a -exec cp {} "$OUT/lib/" \;
find "$WORK/build-ios" -name libssl.a -exec cp {} "$OUT/lib/" \;

test -f "$OUT/lib/libcrypto.a"
test -f "$OUT/lib/libssl.a"
lipo -info "$OUT/lib/libcrypto.a"
echo "BoringSSL ready in $OUT"
