#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Fetch the un4seen BASS audio libraries for iOS (core + the add-ons Elten uses)
# and stage their frameworks into ios/Klangten/Frameworks. BASS is a third-party
# library: free for non-commercial use, a license is required for commercial use
# (see un4seen.com). VERIFIED: with these embedded + linked, Elten's bass.rb and
# the whole audio subsystem load on the iOS simulator.
#
# Elten also wraps opus/ogg/vorbis/speexdsp directly — build those with
# build-codecs-ios.sh. Steam Audio (phonon) for 3D audio is optional and built
# separately from Valve's open-source repo.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/Klangten/Frameworks"
SLICE="${SLICE:-simulator}"   # 'simulator' or 'ios' (device)
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$DEST"; cd "$WORK"

# core + the add-ons referenced by src/eapi/audio/*.rb
ADDONS=(bass bassmix bassenc bassenc_mp3 bassopus bassflac bassmidi basshls basswebm)
for a in "${ADDONS[@]}"; do
  name="$a"; [ "$a" = bass ] && url="bass24-ios.zip" || url="${a}24-ios.zip"
  if curl -fsSL --max-time 60 -o "$a.zip" "https://www.un4seen.com/files/$url" 2>/dev/null; then
    rm -rf "x-$a"; unzip -o -q "$a.zip" -d "x-$a" 2>/dev/null
    fw="$(find "x-$a" -type d -name '*.framework' -path "*${SLICE}*" | head -1)"
    [ -z "$fw" ] && fw="$(find "x-$a" -type d -name '*.framework' | head -1)"
    if [ -n "$fw" ]; then rm -rf "$DEST/$(basename "$fw")"; cp -R "$fw" "$DEST/"; echo "  OK  $(basename "$fw")"; fi
  else
    echo "  --  $a not available (bass_fx / bass_vst may be desktop-only; Elten loads them optionally)"
  fi
done

echo
echo "==> Frameworks in $DEST:"
ls "$DEST" 2>/dev/null | sed 's/^/    /'
echo "Add each as an embedded, code-signed framework dependency (see ios/Klangten/project.yml)."
