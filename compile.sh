#!/bin/sh
# compile.sh - Klangten bauen (macOS und Linux).
#
#   ./compile.sh                 App bauen (macOS: dist/osx/Klangten.app)
#   ./compile.sh --pkg           zusätzlich das Installationspaket
#   ./compile.sh --release       mit Developer ID signieren und notarisieren
#   ./compile.sh --build-id ID   Build id einbetten (sonst der Git-Hash)
#
# Unter Linux baut das Skript alle drei Architekturen, soweit vorhanden, und mit
# --pkg das selbstentpackende dist/linux/klangten-linux.run.
#
# --release liest die Zugangsdaten aus compile.sh.dat (Vorlage:
# compile.sh.dat.example, nicht im Git). Ohne diese Datei bricht es ab, statt
# still etwas Unsigniertes auszuliefern. Nötig sind:
#
#   SIGN_IDENTITY        "Developer ID Application: ... (TEAMID)"
#   INSTALLER_IDENTITY   "Developer ID Installer: ... (TEAMID)"  (nur für --pkg)
#   API_KEY_P8           Pfad des App-Store-Connect-Schlüssels (.p8)
#   API_KEY_ID           dessen Key-ID
#   API_ISSUER_ID        die Issuer-ID des Teams
#
# Zum Starten aus dem Quelltext: ./run.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

PKG=0
RELEASE=0
BUILD_ID=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--pkg) PKG=1; shift ;;
		--release) RELEASE=1; shift ;;
		--build-id) BUILD_ID="${2:?--build-id braucht einen Wert}"; shift 2 ;;
		--build-id=*) BUILD_ID="${1#*=}"; shift ;;
		-h|--help)
			echo "Verwendung: ./compile.sh [--pkg] [--release] [--build-id ID]"
			exit 0 ;;
		*) echo "Unbekanntes Argument: $1"; exit 1 ;;
	esac
done

OS=$(uname -s)

# ------------------------------------------------------------------ Zugangsdaten

DAT="$ROOT/compile.sh.dat"
if [ "$RELEASE" = 1 ]; then
	if [ "$OS" != "Darwin" ]; then
		echo "FEHLER: --release ist nur für macOS gedacht; Linux-Pakete werden nicht signiert."
		exit 1
	fi
	if [ ! -f "$DAT" ]; then
		echo "FEHLER: $DAT fehlt."
		echo "        cp compile.sh.dat.example compile.sh.dat && chmod 600 compile.sh.dat"
		exit 1
	fi
	# shellcheck disable=SC1090
	. "$DAT"
	for v in SIGN_IDENTITY API_KEY_P8 API_KEY_ID API_ISSUER_ID; do
		eval "wert=\$$v"
		[ -n "$wert" ] || { echo "FEHLER: $v fehlt in compile.sh.dat"; exit 1; }
	done
	case "$API_KEY_P8" in
		/*) ;;
		*) API_KEY_P8="$ROOT/$API_KEY_P8" ;;
	esac
	[ -f "$API_KEY_P8" ] || { echo "FEHLER: API-Schlüssel nicht gefunden: $API_KEY_P8"; exit 1; }
	security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" || {
		echo "FEHLER: Signatur-Identität nicht im Schlüsselbund: $SIGN_IDENTITY"
		echo "        Vorhandene:"; security find-identity -v -p codesigning
		exit 1
	}
	# Das Paket wird mit productsign signiert und braucht dafür eine eigene
	# Installer-Identität. Fehlt sie, bleibt es bei der signierten App.
	if [ "$PKG" = 1 ] && [ -z "${INSTALLER_IDENTITY:-}" ]; then
		echo "Hinweis: INSTALLER_IDENTITY fehlt - es wird nur die App signiert, kein Paket."
		PKG=0
	fi
fi

# ------------------------------------------------------------------------ Linux

if [ "$OS" = "Linux" ]; then
	echo "== Klangten für Linux =="
	for arch in x64 arm64 x86; do
		script="$ROOT/tools/build-linux-$arch.sh"
		[ -f "$script" ] || continue
		echo "-- $arch"
		if [ -n "$BUILD_ID" ]; then
			sh "$script" --build-id "$BUILD_ID" || echo "   $arch übersprungen (Build fehlgeschlagen)"
		else
			sh "$script" || echo "   $arch übersprungen (Build fehlgeschlagen)"
		fi
	done
	if [ "$PKG" = 1 ]; then
		sh "$ROOT/tools/build-linux.sh" --pkg
		echo "Fertig: dist/linux/klangten-linux.run"
	else
		echo "Fertig: build/release/linux  (--pkg für das Installationspaket)"
	fi
	exit 0
fi

if [ "$OS" != "Darwin" ]; then
	echo "Dieses Skript unterstützt macOS und Linux. Für Windows: compile.bat"
	exit 1
fi

# ------------------------------------------------------------------------ macOS

set --
if [ "$PKG" = 1 ]; then
	set -- --pkg
else
	set -- --app
fi
[ -n "$BUILD_ID" ] && set -- "$@" --build-id "$BUILD_ID"

if [ "$RELEASE" = 1 ]; then
	NOTARY_PROFILE="${NOTARY_PROFILE:-klangten-notary}"
	echo "== Notarisierungs-Profil auffrischen =="
	xcrun notarytool store-credentials "$NOTARY_PROFILE" \
		--key "$API_KEY_P8" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID"

	set -- "$@" --sign --sign-app-identity "$SIGN_IDENTITY" --notary-profile "$NOTARY_PROFILE"
	[ -n "${INSTALLER_IDENTITY:-}" ] && set -- "$@" --sign-installer-identity "$INSTALLER_IDENTITY"
	echo "== Signierter Build: $SIGN_IDENTITY =="
else
	echo "== Klangten für macOS (unsigniert, ad-hoc signiert) =="
fi

sh "$ROOT/tools/build-osx-arm64.sh" "$@"

echo
if [ "$PKG" = 1 ]; then
	echo "Fertig: dist/osx/Klangten.pkg"
else
	echo "Fertig: dist/osx/Klangten.app  (--pkg für das Installationspaket)"
fi
