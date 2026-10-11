#!/bin/sh
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: program names klangten-<arch>.
set -eu

machine=$(uname -m) || {
  echo "Klangten: cannot detect the Linux architecture." >&2
  exit 127
}

case "$machine" in
  aarch64|arm64) binary=klangten-arm64 ;;
  x86_64|amd64) binary=klangten-x64 ;;
  i386|i486|i586|i686|x86) binary=klangten-x86 ;;
  *)
    echo "Klangten: unsupported Linux architecture: $machine" >&2
    exit 127
    ;;
esac

facade=$(readlink -f -- "$0") || {
  echo "Klangten: cannot resolve the facade path." >&2
  exit 127
}
launcher=${facade%/*}/$binary

if [ ! -x "$launcher" ]; then
  echo "Klangten: missing executable for $machine: $launcher" >&2
  exit 127
fi

exec "$launcher" "$@"
