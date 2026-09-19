#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Downloads BASS and its add-ons for Android from un4seen.com into
# android/vendor/jnilibs/<abi>/, where Gradle packs them into the APK.
# BASS is proprietary (see THIRD-PARTY-NOTICES.md), so it is never committed.
# Not available for Android: bass_fx, bass_aac, bass_ac3, basswma, bass_spx, bass_vst.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ANDROID_DIR/vendor/jnilibs"
DL="$ANDROID_DIR/build/downloads/bass"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64 x86}"
MODULES="bass bassmix bassenc bassenc_mp3 bassopus bassflac bassmidi basshls basswebm bassalac"
mkdir -p "$DL"

for m in $MODULES; do
  zip="$DL/${m}24-android.zip"
  [ -f "$zip" ] || curl -fsSL --retry 3 -o "$zip" "https://www.un4seen.com/files/${m}24-android.zip"
  rm -rf "$DL/x" && mkdir "$DL/x" && unzip -qo "$zip" -d "$DL/x"
  for abi in $ABIS; do
    so="$(find "$DL/x" -path "*/$abi/lib$m.so" | head -1)"
    [ -n "$so" ] || { echo "   $m: no $abi"; continue; }
    mkdir -p "$DEST/$abi" && cp "$so" "$DEST/$abi/"
  done
done
rm -rf "$DL/x"
echo "==> BASS for Android in $DEST: $(ls "$DEST"/arm64-v8a 2>/dev/null | tr '\n' ' ')"
