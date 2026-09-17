#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Build the audio codec libraries Elten wraps directly via Fiddle (opus, ogg,
# vorbis, speexdsp) as static libs for iOS. They must be linked with
# -Wl,-force_load so their symbols survive dead-stripping and Fiddle can resolve
# them at runtime from the main image (Elten's iOS dlopen_library returns the
# process-wide handle). VERIFIED: with these linked, Elten's opus.rb / oggvorbis.rb
# / speexdsp.rb load on the iOS simulator.
#
# Usage: SDK=iphonesimulator ARCH=arm64 ./build-codecs-ios.sh
set -euo pipefail

SDK="${SDK:-iphonesimulator}"; ARCH="${ARCH:-arm64}"; MIN_IOS="${MIN_IOS:-16.0}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Klangten/vendor/codecs/$SDK-$ARCH"
WORK="${WORK:-$(mktemp -d)}"
SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"; CLANG="$(xcrun --sdk "$SDK" -f clang)"
[ "$SDK" = iphonesimulator ] && TARGET="${ARCH}-apple-ios${MIN_IOS}-simulator" || TARGET="${ARCH}-apple-ios${MIN_IOS}"
export CC="$CLANG -target $TARGET -isysroot $SDKROOT"
export CFLAGS="-target $TARGET -isysroot $SDKROOT -O2 -fno-common"
export LDFLAGS="-target $TARGET -isysroot $SDKROOT"
mkdir -p "$OUT"; cd "$WORK"

fetch() { curl -fsSL -o "$1.tgz" "$2"; rm -rf "$1"; mkdir "$1"; tar xzf "$1.tgz" -C "$1" --strip-components=1; }
xbuild() { ( cd "$1" && ./configure --host=aarch64-apple-darwin --build=x86_64-apple-darwin \
             --disable-shared --enable-static "${@:2}" >/dev/null 2>&1 && make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1 ) || true; }

fetch libogg    "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz";        xbuild libogg
fetch opus      "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz";         xbuild opus
fetch speexdsp  "https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz";    xbuild speexdsp
fetch libvorbis "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz"
xbuild libvorbis --with-ogg-includes="$WORK/libogg/include" --with-ogg-libraries="$WORK/libogg/src/.libs"

cp "$WORK/libogg/src/.libs/libogg.a"                 "$OUT/libogg.a"
cp "$WORK/opus/.libs/libopus.a"                      "$OUT/libopus.a"
cp "$WORK/speexdsp/libspeexdsp/.libs/libspeexdsp.a"  "$OUT/libspeexdsp.a"
cp "$WORK/libvorbis/lib/.libs/libvorbis.a"           "$OUT/libvorbis.a"

echo "==> Codec static libs in $OUT:"
for a in "$OUT"/*.a; do echo "    $(basename "$a")  $(xcrun lipo -archs "$a")"; done
echo "Link each with -Wl,-force_load,<path> so Fiddle can resolve their symbols."
