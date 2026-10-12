#!/bin/sh
# A part of Klangten. GNU GPL v3 (see license).
# Builds and runs the self test of klangten_audio against the library in bin/.
# The test only ever uses the null device (KLANGTEN_AUDIO_NULL=1).
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
case "$(uname -s)" in
  Darwin) RUNTIME=osx; LIB=libklangten_audio.dylib ;;
  *) case "$(uname -m)" in x86_64) RUNTIME=linux-x64 ;; aarch64|arm64) RUNTIME=linux-arm64 ;; *) RUNTIME=linux-x86 ;; esac; LIB=libklangten_audio.so ;;
esac
OUT=${TMPDIR:-/tmp}/ka_selftest
cc -O1 -g -I"$ROOT/ext/klangten_audio/src" -o "$OUT" "$ROOT/ext/klangten_audio/test/selftest.c" \
  -L"$ROOT/bin/$RUNTIME" -lklangten_audio -Wl,-rpath,"$ROOT/bin/$RUNTIME" -lm
KLANGTEN_AUDIO_NULL=1 "$OUT" "$@"
