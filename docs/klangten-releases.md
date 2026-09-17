# Klangten releases and updates

Klangten's built-in updater is served by the Klango server the client is connected to (default `https://ten.klango.online`, or `KLANGTEN_API_URL`). This document describes how the updater decides, how to build releases with a meaningful build id and version, and how to publish them.

## How the updater works

| Step | Client code | Server endpoint |
| --- | --- | --- |
| Start-up check (launcher builds, setting "Check for updates at startup") | `src/scenes/loading.rb` | `GET /api/v1/system/build-id?branch=&os=&arch=&build_id=` returns `build_id`, `version_string` |
| Background check every 600 s (launcher builds, logged in) | `src/eapi/notifications.rb` | `POST /api/v1/system/updates` with `branch, os, arch, current_build_id` returns `client{build_id, current_build_id, version_string, update}`, `apps[]` |
| Download before installing (update prompt, notification, Tools > Install Klangten, Reinstall on the loading screen) | `src/eapi/network.rb` `download_verified_installer` | `GET /api/v1/system/installer?branch=&os=&arch=` returns `filename, size, sha256, url`, then the file from `url` |
| Installation after exit | `src/main.rb`, `Klangten::Updates.install_command` | none |

- An update is offered when a release is published for the client's platform and branch and its build id **differs** from the client's own build id. There is no "newer than" comparison: publishing an older installer again rolls clients back.
- The installer is downloaded without credentials, only from the configured Klangten API (scheme, host and port must match, otherwise `system.untrusted_installer_url`), and is accepted only when its size and SHA-256 match the metadata. The hash is checked again immediately before the installer is started. There is no separate code signature check; the metadata comes from the same server over TLS.
- The downloaded file is stored in Klangten's own data directory as `KlangtenSetup.exe`, `Klangten.pkg` or `klangten-linux.run`, so an Elten installation on the same machine is never touched.
- Installers started after Klangten exits:
  - Windows: `"KlangtenSetup.exe" /tasks="" /silent` (Inno Setup with Klangten's own AppId; interactive installs omit the switches)
  - macOS: `Klangten.pkg` is opened in the Installer app
  - Linux: `klangten-linux.run --silent` (it elevates itself with `pkexec` if needed), then `/opt/klangten/elten` is started again
- Running from source (`ruby elten.rb`) never checks for updates on its own, and a build without a build id is never offered one. The Tools menu entry still lets a source run download and start the installer deliberately.
- `KLANGTEN_UPDATES=0` disables the updater completely (menu entries, settings, checks). The switch lives in `src/eltenlink/klangten_config.rb`.

### Values sent by the client

| Parameter | Values | Source |
| --- | --- | --- |
| `os` | `windows`, `osx`, `linux` | `platform_os` |
| `branch` | `stable` (also for the setting "Auto"), `rc`, `beta` | Settings > Updates branch |
| `arch` | `x64`, `x86`, `arm64` | `ELTEN_LAUNCHER_ARCH` set by the launcher |
| `build_id` / `current_build_id` | the id embedded at build time, empty for source runs | `Elten.build_id` |

### Which release a client receives

The server looks for a release in this order:

1. **Architecture:** `<platform>-<arch>`, then the emulation fallback (Windows arm64 → x64, macOS arm64 → x64), then the universal release `<platform>`. Linux has no emulation fallback.
2. **Branch:** if a branch has no release at all, `beta` falls back to `rc`, and `rc` to `stable`.

Current packages are published as follows:

| Package | Contents | Publish as |
| --- | --- | --- |
| `dist/windows/KlangtenSetup.exe` | x64 and x86 launchers. There is no arm64 launcher: the facade `elten.exe` starts the x64 launcher on Windows on ARM | `--platform windows` (universal). ARM64 devices receive it without a separate entry |
| `dist/osx/Klangten.pkg` | arm64 | `--platform osx --arch arm64` (or universal) |
| `dist/linux/klangten-linux.run` | arm64, x64 and x86 payloads; the installer picks one | `--platform linux` (universal) |

## Build id and version

**Build id.** Every release build must embed an explicit id with `--build-id`. Use one id for all platforms of a release, e.g. the date plus a counter: `2026091401`. Allowed characters are `A-Z a-z 0-9 . _ + -`, at most 64 characters, and not `0`. Without `--build-id`, CMake embeds the git commit hash (or `UNKNOWN_<random>`), which is fine for development. Be aware that such a launcher build is offered the published release, because its id differs. The id used for a build is written to `build-id` in the CMake build directory and shown on the Version screen ("Build ID").

**Version string.** The version shown to users is not a build parameter. Bump it by hand in all three places before a release:

| File | Value |
| --- | --- |
| `src/eltenlink/klangten_config.rb` | `VERSION = "0.2.0"` (window title, user agent, Version screen) |
| `launcher/installer/inst_elten.iss` | `AppVersion=Klangten 0.2.0` |
| `cmake/macos_bundle.cmake` | `--version "0.2.0"` (both `pkgbuild` calls) |

Pass the same value to the release tool with `--version`.

## Building releases

The general build prerequisites are described in [Building Elten 3](building.md). Release commands with id `2026091401`:

**Windows** (build host with Visual Studio 2026):

```bat
tools\build-windows.bat --pkg --sign --build-id 2026091401
```

This builds the x64 and x86 launchers and the facade, and creates `dist\windows\KlangtenSetup.exe`. Omit `--sign` for an unsigned test build. `--signtool` and `--timestamp-url` are optional. The per-architecture scripts accept the same `--build-id` (`tools\build-windows-x64.bat --build-id 2026091401`).

**macOS** (Apple Silicon):

```sh
tools/build-osx.sh --pkg --sign --build-id 2026091401
```

This creates `dist/osx/Klangten.pkg`, signed and notarised when `--sign` is given (identities and notary profile: see `tools/build-osx-arm64.sh`).

**Linux** (each architecture on a matching host or cross toolchain, all with the same id):

```sh
./tools/build-linux-x64.sh --build-id 2026091401 --jobs 4
./tools/build-linux-arm64.sh --build-id 2026091401 --jobs 4
./tools/build-linux-x86.sh --build-id 2026091401 --jobs 4
# merge the three trees into build/release/linux (elten-arm64, elten-x64, elten-x86, bin/linux-*), then:
./tools/build-linux.sh --pkg
```

This creates `dist/linux/klangten-linux.run`. `build-linux.sh` refuses to package unless all three architectures are present.

## Publishing on the Klango server

The release tool belongs to the server (`klango_server/klango/klangten/release.py`). It computes size and SHA-256, copies the installer into the release store and atomically replaces the metadata. The endpoints pick up the change immediately, without a restart. Run it as the service user so that gunicorn can read the files:

```sh
scp dist/windows/KlangtenSetup.exe dist/osx/Klangten.pkg dist/linux/klangten-linux.run root@klango.online:/tmp/

cd /opt/klango/app
REL="sudo -u klango .venv/bin/python -m klango.klangten.release --dir /opt/klango/data/klangten_releases"

$REL publish --platform windows --branch stable --build-id 2026091401 --version 0.2.0 \
  --file /tmp/KlangtenSetup.exe --notes "Klangten 0.2.0"
$REL publish --platform osx --arch arm64 --branch stable --build-id 2026091401 --version 0.2.0 \
  --file /tmp/Klangten.pkg
$REL publish --platform linux --branch stable --build-id 2026091401 --version 0.2.0 \
  --file /tmp/klangten-linux.run

$REL list                                                     # what is published
$REL resolve --platform windows --arch arm64 --branch stable  # what a client would receive
$REL remove --platform windows --branch stable                # withdraw a release
```

Options: `--arch` (default `universal`), `--branch` (default `stable`), `--filename` (default: the name of `--file`), `--notes`. `--platform` also accepts `macos`. Without `--dir`, the tool uses `KLANGTEN_RELEASES_DIR`, otherwise `klangten_releases` next to `KLANGO_DB`.

Recommended order: publish to `--branch beta`, update a test installation (Settings > Updates branch: Beta), then publish the same files to `stable`. The store keeps the current and the previous installer for every target. To roll back, publish the previous installer again with its old build id.

## Testing an update locally

1. Start a development server with a throw-away database and release store (in `klango_server`):
   `KLANGO_DB=/tmp/kt.sqlite3 KLANGTEN_RELEASES_DIR=/tmp/kt-releases .venv/bin/python -m klango.klangten --port 5100`
2. Publish a test installer with the release tool (`--dir /tmp/kt-releases`) and a build id different from your launcher build.
3. Start the launcher build with `KLANGTEN_API_URL=http://127.0.0.1:5100`. The start-up check offers the update, and the installer is downloaded, verified and started after exit.

Server details (store layout, HTTP behaviour, deployment notes) are documented in `klango_server/KLANGTEN.md`, section "Updater".
