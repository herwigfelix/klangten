#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Stages the TeamConference core library (MIT, https://github.com/herwigfelix/TeamConference,
# directory lib/) for the iOS app. Input is the xcframework that the TeamConference
# repository builds for iOS (dist/mobile/ios/TeamConferenceCore.xcframework); the
# output is one static library per slice, laid out like vendor/codecs:
#   vendor/teamconference/iphoneos-arm64/libteamconference_core.a
#   vendor/teamconference/iphonesimulator-arm64/libteamconference_core.a
#   vendor/teamconference/iphonesimulator-x86_64/libteamconference_core.a
# assemble.sh links it when present; without it conferences report "not available".
#
# Usage: [TEAMCONFERENCE_XCFRAMEWORK=/path/TeamConferenceCore.xcframework] ./fetch-teamconference.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
XC="${TEAMCONFERENCE_XCFRAMEWORK:-$HERE/../../projekte/teamconference/dist/mobile/ios/TeamConferenceCore.xcframework}"
DEST="$HERE/Klangten/vendor/teamconference"
[ -d "$XC" ] || { echo "!! TeamConferenceCore.xcframework not found: $XC (set TEAMCONFERENCE_XCFRAMEWORK)"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/iphoneos-arm64" "$DEST/iphonesimulator-arm64" "$DEST/iphonesimulator-x86_64"
cp "$XC/ios-arm64/libteamconference_core.a" "$DEST/iphoneos-arm64/"
SIM="$XC/ios-arm64_x86_64-simulator/libteamconference_core.a"
lipo -thin arm64 "$SIM" -output "$DEST/iphonesimulator-arm64/libteamconference_core.a"
lipo -thin x86_64 "$SIM" -output "$DEST/iphonesimulator-x86_64/libteamconference_core.a"

for lib in "$DEST"/*/libteamconference_core.a; do
  syms="$(nm -gU "$lib" 2>/dev/null || true)"
  grep -q " T _tc_join_group_room$" <<<"$syms" || { echo "!! $lib lacks tc_join_group_room"; exit 1; }
done
echo "==> TeamConference staged in $DEST"
