#!/bin/sh
# A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
# GNU General Public License, version 3 (see license).
#
# Builds ext/klangten_spotify (Rust, librespot) for Android into
# android/vendor/jnilibs/<abi>/libklangten_spotify.so. Klangten opens it by
# name (src/eapi/spotify.rb), like every library inside the APK.
#
# Needs: rustup target aarch64-linux-android, Android NDK r28 (NDK=...).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1)}"
[ -d "$NDK" ] || { echo "!! Android NDK r28 not found (set NDK=...)"; exit 1; }
TC="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)"
case "$ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android ;;
  x86_64) TRIPLE=x86_64-linux-android ;;
  *) echo "unsupported ABI $ABI"; exit 1 ;;
esac
VAR=$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')
CC="$TC/bin/$TRIPLE$API-clang"

export "CARGO_TARGET_${VAR}_LINKER=$CC"
export "CC_$(echo "$TRIPLE" | tr '-' '_')=$CC"
export "AR_$(echo "$TRIPLE" | tr '-' '_')=$TC/bin/llvm-ar"

cd "$ROOT/ext/klangten_spotify"
cargo build --release --locked --target "$TRIPLE"
OUT="$ROOT/android/vendor/jnilibs/$ABI"
mkdir -p "$OUT"
"$TC/bin/llvm-strip" --strip-unneeded -o "$OUT/libklangten_spotify.so" "target/$TRIPLE/release/libklangten_spotify.so"
echo "built $OUT/libklangten_spotify.so ($(du -h "$OUT/libklangten_spotify.so" | cut -f1))"
