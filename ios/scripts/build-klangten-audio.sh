#!/bin/sh
# A part of Klangten. GNU GPL v3 (see license).
#
# Builds Klangten's sound engine for iOS as ios/Klangten/Frameworks/
# klangten_audio.xcframework (a dynamic framework for the device and the
# arm64 simulator). assemble.sh embeds every xcframework in that folder.
# FFmpeg (LGPL v3, TLS through SecureTransport) and LAME are linked in
# statically; miniaudio is compiled as Objective-C so it can set the audio
# session (playback; playAndRecord only while recording).
#
#   sh ios/scripts/build-klangten-audio.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EXT="$ROOT/ext/klangten_audio"
SRC="$EXT/deps/src"
FFMPEG_VERSION=9.0.2
LAME_VERSION=3.100
MIN_IOS=15.0
JOBS=$(sysctl -n hw.ncpu)
OUTDIR="$ROOT/ios/Klangten/Frameworks"
mkdir -p "$SRC" "$OUTDIR"
[ -f "$SRC/lame-$LAME_VERSION.tar.gz" ] || curl -sSfL -o "$SRC/lame-$LAME_VERSION.tar.gz" "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
[ -f "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" ] || curl -sSfL -o "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

build_slice() {
  SLICE=$1 SDK=$2 TARGET=$3
  DEPS="$EXT/deps/$SLICE"
  SYSROOT=$(xcrun -sdk "$SDK" --show-sdk-path)
  CC="$(xcrun -sdk "$SDK" -f clang)"
  CFLAGS="-target $TARGET -isysroot $SYSROOT -O2 -fPIC"
  mkdir -p "$DEPS"

  if [ ! -f "$DEPS/lib/libmp3lame.a" ]; then
    rm -rf "$DEPS/build-lame" && mkdir -p "$DEPS/build-lame"
    tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$DEPS/build-lame"
    ( cd "$DEPS/build-lame/lame-$LAME_VERSION"
      sed -i.orig '/lame_init_old/d' include/libmp3lame.sym
      # lame's configure misses the standard headers when cross-compiling
      CC="$CC" CFLAGS="$CFLAGS -DSTDC_HEADERS -include string.h -include strings.h" LDFLAGS="-target $TARGET -isysroot $SYSROOT" ./configure --host=aarch64-apple-darwin --prefix="$DEPS" \
        --disable-shared --enable-static --disable-frontend --disable-decoder >/dev/null
      make -j"$JOBS" >/dev/null && make install >/dev/null )
  fi

  if [ ! -f "$DEPS/lib/libavformat.a" ]; then
    rm -rf "$DEPS/build-ffmpeg" && mkdir -p "$DEPS/build-ffmpeg"
    tar -xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$DEPS/build-ffmpeg"
    ( cd "$DEPS/build-ffmpeg/ffmpeg-$FFMPEG_VERSION"
      ./configure --prefix="$DEPS" \
        --target-os=darwin --arch=aarch64 --enable-cross-compile --cc="$CC" \
        --sysroot="$SYSROOT" --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
        --enable-static --disable-shared --enable-pic --enable-version3 \
        --disable-programs --disable-doc --disable-avdevice --disable-swscale --disable-avfilter \
        --disable-everything --disable-autodetect --enable-securetransport \
        --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
        --enable-network \
        --enable-protocol=file,http,https,tcp,tls,hls,crypto,data,httpproxy \
        --enable-demuxer=mp3,aac,mov,matroska,ogg,flac,wav,w64,aiff,asf,hls,mpegts,ac3,eac3,caf,au,loas,wv,ape,tta,dts,amr \
        --enable-decoder=mp3,mp3float,mp2,mp2float,mp1,mp1float,aac,aac_latm,alac,flac,vorbis,opus,wmav1,wmav2,wmapro,wmalossless,ac3,eac3,dca,ape,wavpack,tta,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_wav,adpcm_ms,gsm,gsm_ms \
        --enable-parser=mpegaudio,aac,aac_latm,flac,vorbis,opus,ac3,dca \
        >/dev/null
      make -j"$JOBS" >/dev/null && make install >/dev/null )
  fi

  FW="$EXT/deps/$SLICE/klangten_audio.framework"
  rm -rf "$FW" && mkdir -p "$FW"
  "$CC" $CFLAGS -fvisibility=hidden -I"$EXT/src" -I"$EXT/vendor" -I"$DEPS/include" \
    -dynamiclib -install_name @rpath/klangten_audio.framework/klangten_audio \
    -o "$FW/klangten_audio" \
    "$EXT/src/ka_core.c" "$EXT/src/ka_decoder.c" "$EXT/src/ka_sources.c" "$EXT/src/ka_fx.c" "$EXT/src/ka_encode.c" \
    -x objective-c "$EXT/src/ka_miniaudio.c" -x none \
    "$DEPS/lib/libavformat.a" "$DEPS/lib/libavcodec.a" "$DEPS/lib/libswresample.a" "$DEPS/lib/libavutil.a" "$DEPS/lib/libmp3lame.a" \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation \
    -framework CoreFoundation -framework Security -lm
  cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>klangten_audio</string>
  <key>CFBundleIdentifier</key><string>it.sixdots.klangten.audio</string>
  <key>CFBundleName</key><string>klangten_audio</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
PLIST
}

build_slice ios-arm64 iphoneos arm64-apple-ios$MIN_IOS
build_slice ios-arm64-simulator iphonesimulator arm64-apple-ios$MIN_IOS-simulator

rm -rf "$OUTDIR/klangten_audio.xcframework"
xcodebuild -create-xcframework \
  -framework "$EXT/deps/ios-arm64/klangten_audio.framework" \
  -framework "$EXT/deps/ios-arm64-simulator/klangten_audio.framework" \
  -output "$OUTDIR/klangten_audio.xcframework" >/dev/null
echo "built $OUTDIR/klangten_audio.xcframework"
