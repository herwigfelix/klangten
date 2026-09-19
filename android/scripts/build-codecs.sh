#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Builds the audio codecs the core opens through Fiddle (src/eapi/audio/opus.rb,
# speexdsp.rb, encoders/ogg.rb, encoders/vorbis.rb) as plain shared libraries
# for the APK: libopus.so, libogg.so, libvorbis.so, libvorbisenc.so,
# libspeexdsp.so in vendor/jnilibs/<abi>/. Same versions as the iOS build.
#
# The libraries are built statically and then wrapped with our own soname:
# libtool's versioned names (libogg.so.0) cannot be packed into an APK.
#
# Usage: [ABI=arm64-v8a] android/scripts/build-codecs.sh
set -euo pipefail

ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1)}"
TC="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android ;;
  x86_64)      TRIPLE=x86_64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
  *) echo "!! unsupported ABI $ABI"; exit 1 ;;
esac
HOST_TRIPLE="${TRIPLE/armv7a/arm}"

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ANDROID_DIR/build/codecs-$ABI"
PREFIX="$WORK/prefix"
DL="$ANDROID_DIR/build/downloads"
OUT="$ANDROID_DIR/vendor/jnilibs/$ABI"
mkdir -p "$WORK" "$PREFIX" "$DL" "$OUT"

export CC="$TC/bin/${TRIPLE}${API}-clang" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib"
LINK_FLAGS=(-shared -Wl,-z,max-page-size=16384 -Wl,--no-undefined)

build() { # name url [configure args...]
  local name="$1" url="$2"; shift 2
  local file; file="$(basename "$url")"
  [ -f "$DL/$file" ] || curl -fL --retry 3 -o "$DL/$file" "$url"
  rm -rf "$WORK/$name" && mkdir "$WORK/$name" && tar xzf "$DL/$file" -C "$WORK/$name" --strip-components 1
  echo "==> $name"
  (cd "$WORK/$name" && CFLAGS="-O2 -fPIC" ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
     --enable-static --disable-shared "$@" >"$WORK/$name.log" 2>&1 \
   && make -j"$JOBS" >>"$WORK/$name.log" 2>&1 && make install >>"$WORK/$name.log" 2>&1) \
   || { tail -30 "$WORK/$name.log"; exit 1; }
}
wrap() { # soname archive [libs...]
  local so="$1" archive="$2"; shift 2
  "$CC" "${LINK_FLAGS[@]}" -Wl,-soname,"$so" -o "$OUT/$so" \
    -Wl,--whole-archive "$PREFIX/lib/$archive" -Wl,--no-whole-archive -L"$OUT" "$@" -lm
}

build libogg "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz"
build opus "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" --disable-doc --disable-extra-programs
build speexdsp "https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz"
build libvorbis "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz" \
  --with-ogg="$PREFIX" --disable-examples --disable-docs

wrap libogg.so libogg.a
wrap libopus.so libopus.a
wrap libspeexdsp.so libspeexdsp.a
wrap libvorbis.so libvorbis.a -logg
wrap libvorbisenc.so libvorbisenc.a -lvorbis -logg

echo "==> codecs for $ABI in $OUT: libogg.so libopus.so libspeexdsp.so libvorbis.so libvorbisenc.so"
