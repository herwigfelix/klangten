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

## Rolling release channel (GitHub)

Besides the branches served by the Klango server, the update channel in Settings > Auto updater offers **Rolling release (GitHub)**. It reads the newest release of the public repository `herwigfelix/klangten` instead of the server, which is where the workflows in `.github/workflows` publish every tagged build.

| Step | Client code | Source |
| --- | --- | --- |
| Start-up check | `src/scenes/loading.rb` → `github_latest_release`, `github_release_build_id` | `GET https://api.github.com/repos/herwigfelix/klangten/releases/latest`, then the asset `build-id.txt` |
| Download | `src/eapi/network.rb` `download_github_installer` | the installer asset, verified against `<installer>.sha256` |
| Installation after exit | unchanged (`src/main.rb`, `Klangten::Updates.install_command`) | — |

- A release must publish three assets per platform: the installer under its usual name (`KlangtenSetup.exe`, `Klangten.pkg`, `klangten-linux.run`), a checksum file `<installer>.sha256` in `sha256sum`/`shasum` format, and `build-id.txt` with the build id compiled into it. A release without them is ignored.
- The same rule as on the server decides: the build id must **differ**, so a rollback works by publishing an older build again.
- Downloads are accepted only from `github.com` and GitHub's asset hosts (`Klangten::GitHub.trusted_url?`); size and SHA-256 must match before the file is stored, and `src/main.rb` checks the hash again immediately before the installer runs.
- There is **no background polling** in this channel: GitHub is asked once at start-up and whenever the user triggers an update. `Configuration.checkupdates` ("Check for updates automatically") switches the automatic check off in both channels — including the 600 s server poll, which upstream did not gate.
- `rolling` is never sent to the Klango server; `get_updatesbranch` maps it back to the branch the build was made for (`src/eapi/core/cache.rb`).

## Continuous integration

`.github/workflows/build-macos.yml` (runner `macos-26`) and `.github/workflows/build-windows.yml` (runner `windows-2025-vs2026`) build on a `v*` tag and on manual dispatch. Both derive the build id from the tag (`v0.1.1` → `0.1.1`) or from the run number, write `<installer>.sha256` and `build-id.txt` next to the installer, upload them as artifacts and, for a tag, attach them to the release — which is exactly what the rolling channel expects.

The Ruby runtime and the gems are compiled from source by the build itself, so both jobs cache `build/launcher-*/ruby`. macOS additionally installs `ruby-install` and needs `rustc` for YJIT. The Windows job builds x64, x86 and the facade `elten.exe`, but not ARM64: that target's Ruby runtime has to run during the build and therefore needs an ARM64 host.

### macOS signing in CI

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID **Application** certificate, base64 of the `.p12` |
| `MACOS_SIGN_IDENTITY` | identity string, e.g. `Developer ID Application: … (TEAMID)` |
| `MACOS_TEAM_ID` | Apple Team ID |
| `MACOS_API_KEY_BASE64`, `MACOS_API_KEY_ID`, `MACOS_API_ISSUER_ID` | App Store Connect key for notarization |
| `MACOS_INSTALLER_CERT_P12_BASE64`, `MACOS_INSTALLER_CERT_PASSWORD`, `MACOS_INSTALLER_IDENTITY` | Developer ID **Installer** certificate — only with it can the `.pkg` be signed (`productsign`) |

The workflow imports the certificates into a throw-away keychain, makes it the default one and stores the notarization credentials as the keychain profile `klangten-notary`, which `cmake/macos_bundle.cmake` uses. Without the installer certificate the build falls back to an unsigned (ad-hoc signed) package and says so in the log; nothing else changes, so adding those three secrets later is enough to get signed packages.

Locally the same is done by `./compile.sh --release`, which reads `compile.sh.dat` (template: `compile.sh.dat.example`, git-ignored).
