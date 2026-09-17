#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Reproducible proof that Elten's real iOS code runs on an embedded CRuby runtime
# WITH Fiddle, in the iOS simulator. It:
#   1. fetches the maintained CRuby prebuilt (Option 2),
#   2. builds fiddle + libffi for iOS (build-fiddle-ios.sh),
#   3. stages Elten's real platform files + the CRuby stdlib,
#   4. builds a tiny host app and runs boot.rb on the simulator.
# boot.rb exercises Fiddle (dlopen, a real strlen() call, objc_getClass for
# NSObject/UIPasteboard/AVSpeechSynthesizer — Elten's actual ObjC bridge) plus
# the gesture/keyboard model. Expected: 8/8 PASS.
#
# Usage: ios/embedtest/run.sh ["iPhone 17 Pro"]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEV="${1:-iPhone 17 Pro}"
CRUBY_DIR="$REPO/ios/Klangten/vendor/cruby"
FIDDLE_DIR="$REPO/ios/Klangten/vendor/fiddle/iphonesimulator-arm64"

# 1. Runtime (Option 2)
[ -d "$CRUBY_DIR/CRuby.xcframework" ] || "$REPO/ios/scripts/fetch-cruby-runtime.sh"

# 2. fiddle + libffi (iOS simulator arm64)
if [ ! -f "$FIDDLE_DIR/libfiddle.a" ] || [ ! -f "$FIDDLE_DIR/libffi.a" ]; then
  echo "==> Building fiddle + libffi for iOS simulator"
  SDK=iphonesimulator ARCH=arm64 "$REPO/ios/scripts/build-fiddle-ios.sh"
fi

# 3. Vendor slices + headers into the harness
mkdir -p "$HERE/vendor"
cp -R "$CRUBY_DIR/include" "$HERE/vendor/include"
cp "$CRUBY_DIR/CRuby.xcframework/ios-arm64_x86_64-simulator/libruby-static.a" "$HERE/vendor/libruby-static.a"
cp "$FIDDLE_DIR/libfiddle.a" "$HERE/vendor/libfiddle.a"
cp "$FIDDLE_DIR/libffi.a"    "$HERE/vendor/libffi.a"
# CRuby stdlib (fiddle.rb + fiddle/*) preserving structure
rm -rf "$HERE/stdlib"; cp -R "$CRUBY_DIR/lib/ruby/4.0.0" "$HERE/stdlib"
# Elten's REAL platform files
cp "$REPO/src/platforms/ios/ri/desktopruntime.rb" "$HERE/ruby/desktopruntime.rb"
cp "$REPO/src/ui/controls/onscreen_keyboard.rb"   "$HERE/ruby/onscreen_keyboard.rb"
cp "$REPO/src/platforms/ios/ui/touchinput.rb"     "$HERE/ruby/touchinput.rb"

# 4. Build (arm64-only; libffi/libfiddle are single-slice) + run
cd "$HERE"
xcodegen generate >/dev/null
xcodebuild -project EltenEmbedTest.xcodeproj -scheme EltenEmbedTest -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build >/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$DEV" it.sixdots.klangten.embedtest 2>/dev/null || true
xcrun simctl uninstall "$DEV" it.sixdots.klangten.embedtest 2>/dev/null || true
xcrun simctl install "$DEV" "build/Build/Products/Debug-iphonesimulator/EltenEmbedTest.app" >/dev/null
xcrun simctl launch "$DEV" it.sixdots.klangten.embedtest >/dev/null
sleep 6
CONT="$(xcrun simctl get_app_container "$DEV" it.sixdots.klangten.embedtest data 2>/dev/null)"
echo "===================================================================="
cat "$CONT/Documents/elten_test.txt" 2>/dev/null || echo "no result (app may still be starting)"
echo "===================================================================="
