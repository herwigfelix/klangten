#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Turn-key assembler: stages the Elten Ruby core + stdlib + gem libs into the
# app bundle resources and generates the Xcode project with every native link.
# After this you only set your signing Team in Xcode and press Run.
#
# Prerequisites (run once, for each slice you build — see ios/README.md):
#   ios/scripts/fetch-cruby-runtime.sh
#   SDK=iphonesimulator ARCH=arm64 ios/scripts/build-fiddle-ios.sh   # + iphoneos
#   SDK=iphonesimulator ARCH=arm64 ios/scripts/build-gems-ios.sh     # + iphoneos
#   SDK=iphonesimulator ARCH=arm64 ios/scripts/build-codecs-ios.sh   # + iphoneos
#   ios/scripts/fetch-native-libs.sh   (BASS xcframeworks)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RES="$HERE/Resources"
CRUBY="$HERE/vendor/cruby"
[ -d "$CRUBY/CRuby.xcframework" ] || { echo "!! run ios/scripts/fetch-cruby-runtime.sh first"; exit 1; }

# Signing persists across regeneration: put your details in ios/Klangten/signing.env
#   DEVELOPMENT_TEAM=ABCDE12345      # your 10-char Team ID (Xcode Signing tab)
#   BUNDLE_ID=it.sixdots.klangten          # optional, a unique bundle id
[ -f "$HERE/signing.env" ] && . "$HERE/signing.env"
BUNDLE_ID="${BUNDLE_ID:-it.sixdots.klangten}"
SIGN=""
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  SIGN=$(printf '        DEVELOPMENT_TEAM: %s\n        CODE_SIGN_STYLE: Automatic' "$DEVELOPMENT_TEAM")
fi

echo "==> Staging Klangten core"
rm -rf "$RES"; mkdir -p "$RES/eltencore"
for item in elten.rb filelist src resources locale patchs audio; do
  [ -e "$REPO/$item" ] && rsync -a --exclude '.git' --exclude bin "$REPO/$item" "$RES/eltencore/"
done

echo "==> Staging CRuby stdlib"
cp -R "$CRUBY/lib/ruby" "$RES/stdlib"

echo "==> Staging gem libs"
mkdir -p "$RES/gemlibs"; TMP="$(mktemp -d)"
gemlib() { # name-version
  curl -fsSL -o "$TMP/$1.gem" "https://rubygems.org/downloads/$1.gem"
  mkdir -p "$TMP/$1"; tar xf "$TMP/$1.gem" -C "$TMP/$1"; tar xzf "$TMP/$1/data.tar.gz" -C "$TMP/$1"
  [ -d "$TMP/$1/lib" ] && cp -R "$TMP/$1/lib/." "$RES/gemlibs/"
}
for g in nokogiri-1.19.4 zstd-ruby-2.0.6 ruby-xz-1.0.3 rubyzip-3.2.2 http-2-1.1.3 base62-1.0.0 base64-0.3.0 ostruct-0.6.3; do
  gemlib "$g"; echo "    $g"
done
# nokogiri: require_relative can't reach a statically-linked ext -> use require
perl -0pi -e 's{require_relative "\#\{Regexp.last_match\(1\)\}/nokogiri"}{require "\#{Regexp.last_match(1)}/nokogiri"}' "$RES/gemlibs/nokogiri/extension.rb" 2>/dev/null || true
rm -rf "$TMP"

cp "$HERE/ios_boot.rb" "$RES/ios_boot.rb"

echo "==> Generating Xcode project"
LP='$(SRCROOT)/vendor/fiddle/$(PLATFORM_NAME)-$(CURRENT_ARCH)'
GP='$(SRCROOT)/vendor/gems/$(PLATFORM_NAME)-$(CURRENT_ARCH)'
CP='$(SRCROOT)/vendor/codecs/$(PLATFORM_NAME)-$(CURRENT_ARCH)'
{
cat <<YAML
name: Klangten
options:
  bundleIdPrefix: it.sixdots
  deploymentTarget: { iOS: "18.0" }
  createIntermediateGroups: true
targets:
  Klangten:
    type: application
    platform: iOS
    sources:
      - Sources
      - path: Resources/eltencore
        type: folder
        buildPhase: resources
      - path: Resources/stdlib
        type: folder
        buildPhase: resources
      - path: Resources/gemlibs
        type: folder
        buildPhase: resources
      - path: Resources/ios_boot.rb
        buildPhase: resources
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: Klangten
        # Ohne diese beiden Zeilen schreibt xcodegen seine Vorgaben 1.0 und 1 in
        # die Info.plist, statt die Fassung aus MARKETING_VERSION zu uebernehmen.
        CFBundleShortVersionString: \$(MARKETING_VERSION)
        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)
        UILaunchScreen: {}
        UIBackgroundModes: [audio]
        NSMicrophoneUsageDescription: Klangten uses the microphone for voice messages and conferences.
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait, UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
$SIGN
        TARGETED_DEVICE_FAMILY: "1,2"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "5.0"
        ENABLE_DEBUG_DYLIB: "NO"
        SWIFT_OBJC_BRIDGING_HEADER: Sources/Elten-Bridging-Header.h
        HEADER_SEARCH_PATHS: [\$(inherited), \$(SRCROOT)/vendor/cruby/include]
        LIBRARY_SEARCH_PATHS: [\$(inherited), $LP, $GP, $CP]
        OTHER_LDFLAGS:
          - \$(inherited)
          - -lz
          - -lresolv
          - -lc++
          - -lxml2
          - -lxslt
          - -lexslt
          - -lfiddle
          - -lffi
          - -lbigdecimal
          - -lzstdruby
          - -lnokogiri
          - -Wl,-force_load,$CP/libopus.a
          - -Wl,-force_load,$CP/libogg.a
          - -Wl,-force_load,$CP/libvorbis.a
          - -Wl,-force_load,$CP/libspeexdsp.a
          # Export the app's own symbols into the dynamic table so the embedded
          # Ruby can resolve the host bridge (elten_host_*) via dlopen(nil)/dlsym.
          # Without this the @_cdecl entry points are not visible and the app is
          # silent + unresponsive to gestures.
          - -Wl,-export_dynamic
    dependencies:
      - framework: vendor/cruby/CRuby.xcframework
        embed: false
YAML
for xc in "$HERE"/Frameworks/*.xcframework; do
  [ -e "$xc" ] || continue
  echo "      - framework: Frameworks/$(basename "$xc")"
  echo "        embed: true"
  echo "        codeSign: true"
done
echo "      - sdk: AVFoundation.framework"
echo "      - sdk: UIKit.framework"
} > "$HERE/project.yml"

cd "$HERE"
xcodegen generate
echo
echo "==> Done. Open Klangten.xcodeproj, set your signing Team + a unique bundle id, pick your iPhone, Run."
