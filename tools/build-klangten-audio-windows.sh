#!/bin/sh
# A part of Klangten. GNU GPL v3 (see license).
#
# Builds klangten_audio.dll for Windows (x64, x86, arm64) with llvm-mingw in
# an MSYS2 shell: LAME and an LGPL v3 build of FFmpeg (TLS through Windows'
# own SChannel) as static libraries, linked into one DLL with no other
# dependency than Windows itself (UCRT).
#
#   LLVM_MINGW=/c/llvm-mingw sh tools/build-klangten-audio-windows.sh x64 x86 arm64
#
# Result: bin/windows-<arch>/klangten_audio.dll. MSYS2 needs: make nasm
# diffutils pkgconf tar xz curl. llvm-mingw: github.com/mstorsjo/llvm-mingw
# (the ucrt-x86_64 release).
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXT="$ROOT/ext/klangten_audio"
FFMPEG_VERSION=9.0.2
LAME_VERSION=3.100
LLVM_MINGW=${LLVM_MINGW:-/c/llvm-mingw}
export PATH="$LLVM_MINGW/bin:$PATH"
JOBS=$(nproc 2>/dev/null || echo 4)
SRC="$EXT/deps/src"
mkdir -p "$SRC"

fetch() {
  [ -f "$SRC/$2" ] || curl -sSfL -o "$SRC/$2" "$1"
}
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION.tar.gz"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"

[ $# -gt 0 ] || set -- x64 x86 arm64

for ARCH in "$@"; do
  case "$ARCH" in
    x64) TRIPLE=x86_64-w64-mingw32; FFARCH=x86_64 ;;
    x86) TRIPLE=i686-w64-mingw32; FFARCH=x86 ;;
    arm64) TRIPLE=aarch64-w64-mingw32; FFARCH=aarch64 ;;
    *) echo "unknown architecture $ARCH"; exit 1 ;;
  esac
  DEPS="$EXT/deps/windows-$ARCH"
  mkdir -p "$DEPS"
  echo "== $ARCH"

  if [ ! -f "$DEPS/lib/libmp3lame.a" ]; then
    rm -rf "$DEPS/build-lame" && mkdir -p "$DEPS/build-lame"
    tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$DEPS/build-lame"
    cd "$DEPS/build-lame/lame-$LAME_VERSION"
    sed -i.orig '/lame_init_old/d' include/libmp3lame.sym
    CC=$TRIPLE-clang CFLAGS="-O2" ./configure --host=$TRIPLE --prefix="$DEPS" \
      --disable-shared --enable-static --disable-frontend --disable-decoder >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
    cd "$ROOT"
  fi

  if [ ! -f "$DEPS/lib/libavformat.a" ]; then
    rm -rf "$DEPS/build-ffmpeg" && mkdir -p "$DEPS/build-ffmpeg"
    tar -xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$DEPS/build-ffmpeg"
    cd "$DEPS/build-ffmpeg/ffmpeg-$FFMPEG_VERSION"
    ./configure --prefix="$DEPS" \
      --target-os=mingw32 --arch=$FFARCH --cross-prefix=$TRIPLE- --cc=$TRIPLE-clang --cxx=$TRIPLE-clang++ \
      --enable-static --disable-shared --enable-version3 \
      --disable-programs --disable-doc --disable-avdevice --disable-swscale --disable-avfilter \
      --disable-everything --disable-autodetect --enable-schannel --enable-w32threads \
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

  OUT="$ROOT/bin/windows-$ARCH"
  mkdir -p "$OUT"
  $TRIPLE-clang -O2 -Wall -Wno-unused-function -I"$EXT/src" -I"$EXT/vendor" -I"$DEPS/include" \
    -shared -o "$OUT/klangten_audio.dll" \
    "$EXT/src/ka_core.c" "$EXT/src/ka_decoder.c" "$EXT/src/ka_sources.c" "$EXT/src/ka_fx.c" "$EXT/src/ka_encode.c" "$EXT/src/ka_miniaudio.c" \
    "$DEPS/lib/libavformat.a" "$DEPS/lib/libavcodec.a" "$DEPS/lib/libswresample.a" "$DEPS/lib/libavutil.a" "$DEPS/lib/libmp3lame.a" \
    -static -lws2_32 -lsecur32 -lncrypt -lcrypt32 -lbcrypt -lole32 -luuid -lwinmm -s
  echo "built $OUT/klangten_audio.dll ($(du -h "$OUT/klangten_audio.dll" | cut -f1))"
done
