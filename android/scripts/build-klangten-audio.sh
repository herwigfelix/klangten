#!/bin/sh
# A part of Klangten. GNU GPL v3 (see license).
#
# Builds Klangten's sound engine klangten_audio for Android (arm64-v8a):
# LAME and an LGPL v3 FFmpeg as static libraries, TLS through the OpenSSL
# that build-runtime.sh already built for Ruby, all inside one
# libklangten_audio.so in android/vendor/jnilibs/<abi>/ (the APK's jniLibs).
# The static libraries' symbols stay hidden, so Ruby's own OpenSSL and this
# copy never meet.
#
#   sh android/scripts/build-runtime.sh          # first, once (OpenSSL)
#   sh android/scripts/build-klangten-audio.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1)}"
[ -d "$NDK" ] || { echo "!! Android NDK r28 not found (set NDK=...)"; exit 1; }
TC="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
case "$ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android; FFARCH=aarch64 ;;
  x86_64) TRIPLE=x86_64-linux-android; FFARCH=x86_64 ;;
  *) echo "unsupported ABI $ABI"; exit 1 ;;
esac
CC="$TC/bin/$TRIPLE$API-clang"
SSL="$ROOT/android/build/runtime-$ABI/prefix"
[ -f "$SSL/lib/libssl.a" ] || { echo "!! OpenSSL not built yet: run android/scripts/build-runtime.sh"; exit 1; }

EXT="$ROOT/ext/klangten_audio"
DEPS="$EXT/deps/android-$ABI"
SRC="$EXT/deps/src"
FFMPEG_VERSION=9.0.2
LAME_VERSION=3.100
mkdir -p "$SRC" "$DEPS"
[ -f "$SRC/lame-$LAME_VERSION.tar.gz" ] || curl -sSfL -o "$SRC/lame-$LAME_VERSION.tar.gz" "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
[ -f "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" ] || curl -sSfL -o "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

if [ ! -f "$DEPS/lib/libmp3lame.a" ]; then
  rm -rf "$DEPS/build-lame" && mkdir -p "$DEPS/build-lame"
  tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$DEPS/build-lame"
  cd "$DEPS/build-lame/lame-$LAME_VERSION"
  sed -i.orig '/lame_init_old/d' include/libmp3lame.sym
  # config.sub of lame 3.100 does not know android; tell it the plain triple
  CC="$CC" CFLAGS="-O2 -fPIC" ./configure --host=${TRIPLE%-android}-linux --prefix="$DEPS" \
    --disable-shared --enable-static --disable-frontend --disable-decoder --with-pic >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
  cd "$ROOT"
fi

if [ ! -f "$DEPS/lib/libavformat.a" ]; then
  rm -rf "$DEPS/build-ffmpeg" && mkdir -p "$DEPS/build-ffmpeg"
  tar -xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$DEPS/build-ffmpeg"
  cd "$DEPS/build-ffmpeg/ffmpeg-$FFMPEG_VERSION"
  ./configure --prefix="$DEPS" \
    --target-os=android --arch=$FFARCH --enable-cross-compile --cc="$CC" \
    --nm="$TC/bin/llvm-nm" --ar="$TC/bin/llvm-ar" --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" \
    --extra-cflags="-I$SSL/include" --extra-ldflags="-L$SSL/lib" \
    --enable-static --disable-shared --enable-pic --enable-version3 \
    --disable-programs --disable-doc --disable-avdevice --disable-swscale --disable-avfilter \
    --disable-everything --disable-autodetect --enable-openssl \
    --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    --enable-network \
    --enable-protocol=file,http,https,tcp,tls,hls,crypto,data,httpproxy \
    --enable-demuxer=mp3,aac,mov,matroska,ogg,flac,wav,w64,aiff,asf,hls,mpegts,ac3,eac3,caf,au,loas,wv,ape,tta,dts,amr \
    --enable-decoder=mp3,mp3float,mp2,mp2float,mp1,mp1float,aac,aac_latm,alac,flac,vorbis,opus,wmav1,wmav2,wmapro,wmalossless,ac3,eac3,dca,ape,wavpack,tta,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_wav,adpcm_ms,gsm,gsm_ms \
    --enable-parser=mpegaudio,aac,aac_latm,flac,vorbis,opus,ac3,dca \
    >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
  cd "$ROOT"
fi

OUT="$ROOT/android/vendor/jnilibs/$ABI"
mkdir -p "$OUT"
"$CC" -O2 -fPIC -fvisibility=hidden -Wall -Wno-unused-function -I"$EXT/src" -I"$EXT/vendor" -I"$DEPS/include" \
  -shared -Wl,-soname,libklangten_audio.so -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=16384 \
  -o "$OUT/libklangten_audio.so" \
  "$EXT/src/ka_core.c" "$EXT/src/ka_decoder.c" "$EXT/src/ka_sources.c" "$EXT/src/ka_fx.c" "$EXT/src/ka_encode.c" "$EXT/src/ka_miniaudio.c" \
  "$DEPS/lib/libavformat.a" "$DEPS/lib/libavcodec.a" "$DEPS/lib/libswresample.a" "$DEPS/lib/libavutil.a" "$DEPS/lib/libmp3lame.a" \
  "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" -lm -ldl -llog
"$TC/bin/llvm-strip" --strip-unneeded "$OUT/libklangten_audio.so"
echo "built $OUT/libklangten_audio.so ($(du -h "$OUT/libklangten_audio.so" | cut -f1))"
