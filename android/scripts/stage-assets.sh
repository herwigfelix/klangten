#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Stages the Ruby files the APK carries as assets into android/build/assets/ruby:
#   stdlib/    Ruby standard library (from vendor/<abi>/stdlib)
#   app/       the probe (later: the Klangten core)
# and the TeamConference library into vendor/jnilibs when it is available.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ABI="${ABI:-arm64-v8a}"
STDLIB="$ANDROID_DIR/vendor/$ABI/stdlib"
OUT="$ANDROID_DIR/build/assets/ruby"
[ -d "$STDLIB" ] || { echo "!! run scripts/build-runtime.sh first"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT/app"
cp -R "$STDLIB" "$OUT/stdlib"
# Not needed at run time on the device.
rm -rf "$OUT/stdlib/bundler" "$OUT/stdlib/rdoc" "$OUT/stdlib/ruby_vm/rjit" 2>/dev/null || true
cp "$ANDROID_DIR/app/ruby/probe.rb" "$OUT/probe.rb"

TC="${TEAMCONFERENCE_JNILIBS:-$ANDROID_DIR/../../projekte/teamconference/dist/mobile/android/jniLibs}"
if [ -f "$TC/$ABI/libteamconference_core.so" ]; then
  mkdir -p "$ANDROID_DIR/vendor/jnilibs/$ABI"
  cp "$TC/$ABI/libteamconference_core.so" "$ANDROID_DIR/vendor/jnilibs/$ABI/"
fi
echo "==> assets: $(du -sh "$OUT" | cut -f1) in $OUT"
