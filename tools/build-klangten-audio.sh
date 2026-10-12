#!/bin/sh
# A part of Klangten. GNU GPL v3 (see license).
#
# Builds klangten_audio, Klangten's own sound engine (ext/klangten_audio),
# for macOS or Linux: LAME and a slim LGPL build of FFmpeg as static
# libraries, then one shared library that holds them together with
# miniaudio and Klangten's code.
#
#   sh tools/build-klangten-audio.sh            # for this machine
#   sh tools/build-klangten-audio.sh --clean    # rebuild FFmpeg and LAME too
#
# Result: bin/osx/libklangten_audio.dylib or bin/linux-<arch>/libklangten_audio.so
# Sources of FFmpeg and LAME are downloaded into ext/klangten_audio/deps/src
# (not in git). Windows: tools/build-klangten-audio.bat (MSYS2/MinGW).
#
# FFmpeg is configured with --enable-version3 and WITHOUT --enable-gpl and
# --enable-nonfree: LGPL v3, compatible with Klangten's GPL v3. Only the
# demuxers, decoders and protocols Klangten plays are built in.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXT="$ROOT/ext/klangten_audio"
FFMPEG_VERSION=9.0.2
LAME_VERSION=3.100
JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )

case "$(uname -s)" in
  Darwin)
    OS=osx
    RUNTIME=osx
    LIBNAME=libklangten_audio.dylib
    MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}
    export MACOSX_DEPLOYMENT_TARGET
    ;;
  Linux)
    OS=linux
    case "$(uname -m)" in
      x86_64) RUNTIME=linux-x64 ;;
      aarch64|arm64) RUNTIME=linux-arm64 ;;
      i?86) RUNTIME=linux-x86 ;;
      *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
    esac
    LIBNAME=libklangten_audio.so
    ;;
  *) echo "unsupported system $(uname -s)"; exit 1 ;;
esac

DEPS="$EXT/deps/$RUNTIME"
SRC="$EXT/deps/src"
mkdir -p "$SRC" "$DEPS"

if [ "$1" = "--clean" ]; then rm -rf "$DEPS"; mkdir -p "$DEPS"; fi

fetch() {
  [ -f "$SRC/$2" ] || curl -sSfL -o "$SRC/$2" "$1"
}

# ------------------------------------------------------------------ LAME
if [ ! -f "$DEPS/lib/libmp3lame.a" ]; then
  fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION.tar.gz"
  rm -rf "$DEPS/build-lame" && mkdir -p "$DEPS/build-lame"
  tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$DEPS/build-lame"
  cd "$DEPS/build-lame/lame-$LAME_VERSION"
  # lame 3.100 exports a symbol that no longer exists
  sed -i.orig '/lame_init_old/d' include/libmp3lame.sym
  CFLAGS="-O2 -fPIC" ./configure --prefix="$DEPS" --disable-shared --enable-static \
    --disable-frontend --disable-decoder --with-pic >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
  cd "$ROOT"
fi

# ---------------------------------------------------------------- FFmpeg
if [ ! -f "$DEPS/lib/libavformat.a" ]; then
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
  rm -rf "$DEPS/build-ffmpeg" && mkdir -p "$DEPS/build-ffmpeg"
  tar -xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$DEPS/build-ffmpeg"
  cd "$DEPS/build-ffmpeg/ffmpeg-$FFMPEG_VERSION"
  TLS=""
  if [ "$OS" = linux ]; then TLS="--enable-openssl"; fi
  ./configure --prefix="$DEPS" \
    --enable-static --disable-shared --enable-pic --enable-version3 \
    --disable-programs --disable-doc --disable-avdevice --disable-swscale --disable-avfilter \
    --disable-everything --disable-autodetect $TLS \
    $( [ "$OS" = osx ] && echo --enable-securetransport ) \
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

# ----------------------------------------------------------- the library
OUT="$ROOT/bin/$RUNTIME"
mkdir -p "$OUT"
CFLAGS="-O2 -fPIC -fvisibility=hidden -Wall -Wno-unused-function -I$EXT/src -I$EXT/vendor -I$DEPS/include"
SOURCES="$EXT/src/ka_core.c $EXT/src/ka_decoder.c $EXT/src/ka_sources.c $EXT/src/ka_fx.c $EXT/src/ka_encode.c $EXT/src/ka_miniaudio.c"
LIBS="$DEPS/lib/libavformat.a $DEPS/lib/libavcodec.a $DEPS/lib/libswresample.a $DEPS/lib/libavutil.a $DEPS/lib/libmp3lame.a"
if [ "$OS" = osx ]; then
  cc $CFLAGS -dynamiclib -install_name @rpath/$LIBNAME -o "$OUT/$LIBNAME" $SOURCES $LIBS \
    -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation \
    -framework Security -framework CoreServices -lm -lpthread
  codesign --force --sign - "$OUT/$LIBNAME" >/dev/null 2>&1 || true
else
  cc $CFLAGS -shared -Wl,-soname,$LIBNAME -Wl,-Bsymbolic -o "$OUT/$LIBNAME" $SOURCES $LIBS \
    -lssl -lcrypto -ldl -lm -lpthread
fi
echo "built $OUT/$LIBNAME ($(du -h "$OUT/$LIBNAME" | cut -f1))"
