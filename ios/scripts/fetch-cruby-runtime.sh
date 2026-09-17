#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Option 2 (recommended): fetch a maintained, prebuilt CRuby runtime for iOS
# instead of cross-compiling CRuby from scratch. Uses xord/cruby, which ships a
# CRuby (MRI) xcframework (device + simulator) with OpenSSL, libyaml and a large
# stdlib (socket, openssl, zlib, psych, json, digest, date, ...) statically
# linked. VERIFIED: this runtime boots on the iOS simulator and runs Elten's
# real iOS interaction code (7/7 assertions) via CRuby_init.
#
# Version note: the prebuilt is CRuby 4.0.x — matching Elten's own Ruby line.
#
# Usage: [CRUBY_VERSION=4.0.401] ./fetch-cruby-runtime.sh
set -euo pipefail

CRUBY_VERSION="${CRUBY_VERSION:-4.0.401}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Klangten/vendor/cruby"
URL="https://github.com/xord/cruby/releases/download/v${CRUBY_VERSION}/CRuby_prebuilt-${CRUBY_VERSION}.tar.gz"
TMP="$(mktemp -d)"

echo "==> Fetching CRuby ${CRUBY_VERSION} prebuilt"
echo "    $URL"
curl -fsSL -o "$TMP/cruby.tar.gz" "$URL"
mkdir -p "$DEST"
tar xzf "$TMP/cruby.tar.gz" -C "$TMP"
rsync -a --delete "$TMP/CRuby/" "$DEST/"
rm -rf "$TMP"

echo "==> Installed to $DEST"
echo "    xcframework: $DEST/CRuby.xcframework (slices: ios-arm64, ios-arm64_x86_64-simulator, macos)"
echo "    headers:     $DEST/include"
echo "    stdlib:      $DEST/lib/ruby"
echo
echo "Link CRuby.xcframework into the app and boot Ruby with CRuby_init(Init_prelude, false)"
echo "(see ios/Klangten/Sources/ruby_shim.c). The stdlib in lib/ruby is bundled by build-app.sh."
echo
echo "NOTE — extensions NOT in this prebuilt that the FULL Elten app still needs:"
echo "  * fiddle (+libffi)  -- REQUIRED: Elten's platform layer and BASS audio are Fiddle-based"
echo "  * bigdecimal        -- used by parts of the app"
echo "  * nokogiri, zstd-ruby, ruby-xz -- C-extension gems (forum HTML, compression)"
echo "Add these via a local CRuby build with the extensions enabled, or compile them"
echo "for iOS and register with CRuby's addExtension:init: / rb_ext_ractor_safe."
