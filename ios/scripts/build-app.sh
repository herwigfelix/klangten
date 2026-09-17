#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Stage the Elten Ruby core into the app bundle resources, generate the Xcode
# project and build for a chosen destination.
#
# Prerequisites (see README.md): ios/Klangten/vendor/ruby (static libruby + headers,
# from build-libruby-ios.sh) and ios/Klangten/Frameworks (native libs, from
# fetch-native-libs.sh). Without them the app builds in "no Ruby" mode and just
# logs that the runtime is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/ios/Klangten"
RES="$IOS_DIR/Resources/elten"

echo "==> Staging Klangten Ruby core into $RES"
rm -rf "$RES"
mkdir -p "$RES"
# Copy exactly what the runtime loads. filelist drives the load order; the boot
# code reads relative paths from the app root.
for item in elten.rb filelist src audio locale resources nvda patchs; do
  if [ -e "$REPO_ROOT/$item" ]; then
    rsync -a --delete-excluded \
      --exclude '.git' --exclude 'bin' \
      "$REPO_ROOT/$item" "$RES/"
  fi
done

# Stage the CRuby stdlib (lib/ruby) next to the app sources so requires resolve.
if [ -d "$IOS_DIR/vendor/cruby/lib/ruby" ]; then
  echo "==> Staging CRuby stdlib"
  rsync -a "$IOS_DIR/vendor/cruby/lib" "$RES/"
else
  echo "!! CRuby runtime not found. Run ios/scripts/fetch-cruby-runtime.sh first."
fi

echo "==> Generating Xcode project"
cd "$IOS_DIR"
xcodegen generate

DEST="${1:-generic/platform=iOS Simulator}"
echo "==> Building for: $DEST"
xcodebuild -project Klangten.xcodeproj -scheme Klangten -configuration Debug \
  -destination "$DEST" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build

echo "==> Done. App: $IOS_DIR/build/Build/Products/Debug-*/Klangten.app"
