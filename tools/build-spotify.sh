#!/usr/bin/env sh
# Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT). GNU GPL v3.
#
# Builds the Spotify library (ext/klangten_spotify) for this machine and
# places it where Klangten looks for it:
#   macOS (Apple silicon)  bin/osx/libklangten_spotify.dylib
#   Linux x86-64           bin/linux-x64/libklangten_spotify.so
#   Linux arm64            bin/linux-arm64/libklangten_spotify.so
# Needs Rust (stable, https://rustup.rs). Windows: tools\build-spotify.bat.
# The release workflows call this before packaging; without the library
# Klangten simply hides Spotify.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CRATE="$ROOT/ext/klangten_spotify"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) DEST=osx; FILE=libklangten_spotify.dylib ;;
  Linux-x86_64) DEST=linux-x64; FILE=libklangten_spotify.so ;;
  Linux-aarch64|Linux-arm64) DEST=linux-arm64; FILE=libklangten_spotify.so ;;
  *) echo "build-spotify.sh: no Spotify build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

if [ "$DEST" = osx ]; then
  # The library must load on every macOS the app supports.
  MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}
  export MACOSX_DEPLOYMENT_TARGET
fi

cd "$CRATE"
cargo build --release --locked
mkdir -p "$ROOT/bin/$DEST"
cp "target/release/$FILE" "$ROOT/bin/$DEST/$FILE"

if [ "$DEST" = osx ]; then
  # Own install name, so the library does not point at the build directory.
  install_name_tool -id "@rpath/$FILE" "$ROOT/bin/$DEST/$FILE"
  # install_name_tool breaks the linker's ad-hoc signature, and macOS kills a
  # process that loads an unsigned library on arm64. The bundle build signs
  # everything again with the real identity.
  codesign -f -s - "$ROOT/bin/$DEST/$FILE"
fi
echo "Spotify library: bin/$DEST/$FILE"
