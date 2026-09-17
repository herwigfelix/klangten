#!/bin/sh
# run.sh - Klangten aus dem Quelltext starten (macOS und Linux).
#
#   ./run.sh              gegen den öffentlichen Klango-Server (ten.klango.online)
#   ./run.sh --dev        gegen einen lokalen Entwicklungsserver auf Port 5100
#   ./run.sh --api URL    gegen einen beliebigen Server
#   ./run.sh -- ARGS      alles nach -- geht unverändert an elten.rb
#
# Das ist ein Quelltextlauf: der eingebaute Updater ist dabei abgeschaltet, weil
# er nur in Launcher-Builds greift (siehe launched_by_launcher? in elten.rb).
# Ein fertiges Programm baut compile.sh.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

API=""
ARGS=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dev) API="http://127.0.0.1:5100"; shift ;;
		--api) API="${2:?--api braucht eine URL}"; shift 2 ;;
		--api=*) API="${1#*=}"; shift ;;
		-h|--help)
			echo "Verwendung: ./run.sh [--dev] [--api URL] [-- ARGUMENTE...]"
			exit 0 ;;
		--) shift; while [ "$#" -gt 0 ]; do ARGS="$ARGS $1"; shift; done; break ;;
		*) ARGS="$ARGS $1"; shift ;;
	esac
done

if [ -n "$API" ]; then
	echo "API: $API"
	KLANGTEN_API_URL="$API"
	export KLANGTEN_API_URL
fi

if command -v bundle >/dev/null 2>&1; then
	# bundle check ist still, wenn alles da ist, und nennt sonst die Lücke.
	bundle check >/dev/null 2>&1 || {
		echo "Gems fehlen, installiere sie (das kann beim ersten Mal lange dauern)..."
		bundle install
	}
	# shellcheck disable=SC2086
	exec bundle exec ruby elten.rb $ARGS
else
	echo "bundler nicht gefunden - starte mit dem System-Ruby ohne Bundler."
	# shellcheck disable=SC2086
	exec ruby elten.rb $ARGS
fi
