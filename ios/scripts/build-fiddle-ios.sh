#!/usr/bin/env bash
# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2026 Dawid Pieper
# Elten is free software: GNU General Public License v3.
#
# Build fiddle (+libffi) for iOS and add it to the CRuby runtime.
#
# The xord/cruby prebuilt does NOT ship fiddle, but Elten's entire platform layer
# and the BASS audio engine are Fiddle-based, so it is required. This compiles
# libffi and the fiddle 1.1.8 C extension (matching CRuby's bundled fiddle) for
# one iOS slice and links them into the app; ruby_shim.c registers Init_fiddle
# via ruby_init_ext so `require 'fiddle'` uses the static extension.
#
# VERIFIED on the iOS simulator (arm64): require 'fiddle', Fiddle.dlopen(nil),
# a real strlen() FFI call, and objc_getClass('NSObject'/'UIPasteboard'/
# 'AVSpeechSynthesizer') all succeed — i.e. Elten's ObjC bridge works.
#
# Usage: SDK=iphonesimulator ARCH=arm64 ./build-fiddle-ios.sh
set -euo pipefail

SDK="${SDK:-iphonesimulator}"          # iphoneos | iphonesimulator
ARCH="${ARCH:-arm64}"
MIN_IOS="${MIN_IOS:-16.0}"
RUBY_VERSION="${RUBY_VERSION:-4.0.4}"  # must match the CRuby runtime's Ruby
LIBFFI_VERSION="${LIBFFI_VERSION:-3.6.0}"

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)/Elten"
CRUBY_INC="$IOS_DIR/vendor/cruby/include"
OUT="$IOS_DIR/vendor/fiddle/$SDK-$ARCH"
WORK="${WORK:-$(mktemp -d)}"

[ -d "$CRUBY_INC" ] || { echo "!! Run fetch-cruby-runtime.sh first (need $CRUBY_INC)"; exit 1; }

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" -f clang)"
if [ "$SDK" = "iphonesimulator" ]; then TARGET="${ARCH}-apple-ios${MIN_IOS}-simulator"
else TARGET="${ARCH}-apple-ios${MIN_IOS}"; fi
mkdir -p "$OUT"

# --- 1. libffi -------------------------------------------------------------
cd "$WORK"
curl -fsSLO "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
tar xzf "libffi-${LIBFFI_VERSION}.tar.gz"
cd "libffi-${LIBFFI_VERSION}"
export CC="$CLANG -target $TARGET -isysroot $SDKROOT"
export CFLAGS="-target $TARGET -isysroot $SDKROOT -O2 -fno-common"
export CCASFLAGS="-target $TARGET -isysroot $SDKROOT"
export LDFLAGS="-target $TARGET -isysroot $SDKROOT"
# host CPU picks the port (aarch64 vs arm); build must DIFFER to trigger cross
# mode (iOS shares the darwin triple with macOS).
HOST_CPU="aarch64"; [ "$ARCH" = "x86_64" ] && HOST_CPU="x86_64"
./configure --host="${HOST_CPU}-apple-darwin" --build=i386-apple-darwin \
  --disable-shared --enable-static --disable-docs --prefix="$WORK/ffi-out" >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
cp "$WORK/ffi-out/lib/libffi.a" "$OUT/libffi.a"

# --- 2. fiddle 1.1.8 C extension ------------------------------------------
cd "$WORK"
unset CC CFLAGS CCASFLAGS LDFLAGS
curl -fsSLO "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz"
tar xzf "ruby-${RUBY_VERSION}.tar.gz"
FDIR="$(find "$WORK/ruby-${RUBY_VERSION}" -type d -path '*fiddle-*/ext/fiddle' | head -1)"
[ -n "$FDIR" ] || { echo "!! fiddle ext not found in ruby source"; exit 1; }

# iOS-appropriate feature defines (normally produced by extconf; iOS lacks
# <link.h> and FFI_STDCALL, size_t is unsigned -> SIGNEDNESS +1).
DEFS=(-DHAVE_DLFCN_H -DHAVE_SYS_MMAN_H -DHAVE_FFI_CLOSURE_ALLOC \
      -DHAVE_FFI_PREP_CIF_VAR -DHAVE_RUBY_MEMORY_VIEW_H -DSIGNEDNESS_OF_SIZE_T=1)
mkdir -p "$WORK/fobj"
for src in "$FDIR"/*.c; do
  "$CLANG" -target "$TARGET" -isysroot "$SDKROOT" -O2 -fno-common "${DEFS[@]}" \
    -I"$CRUBY_INC" -I"$WORK/ffi-out/include" -I"$FDIR" \
    -c "$src" -o "$WORK/fobj/$(basename "$src" .c).o"
done
xcrun ar rcs "$OUT/libfiddle.a" "$WORK/fobj"/*.o

echo "==> Built for $TARGET:"
echo "    $OUT/libffi.a   ($(xcrun lipo -archs "$OUT/libffi.a"))"
echo "    $OUT/libfiddle.a (Init_fiddle: $(nm "$OUT/libfiddle.a" | grep -c 'T _Init_fiddle'))"
echo
echo "Link both into the app (OTHER_LDFLAGS) and keep ruby_init_ext(\"fiddle.so\", Init_fiddle)"
echo "in ruby_shim.c. bigdecimal / nokogiri / zstd / xz follow the same pattern."
