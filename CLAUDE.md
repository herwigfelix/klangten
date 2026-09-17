# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

**Klangten**, a GPLv3 fork of Elten 3 (Dawid Pieper) on branch `klangten`. Klangten keeps Elten's self-voicing, keyboard-driven UI but talks to a **Klango** server (`https://ten.klango.online`) instead of EltenLink, and installs side by side with a normal Elten. `readme.md` documents the fork and keeps the upstream README below "Original Elten README"; `NOTICE.md` and `THIRD-PARTY-NOTICES.md` carry the GPL §5a statements.

Upstream docs stay valid for the shared parts: `docs/architecture.md` (runtime model, `$scene`, interaction ownership), `docs/building.md`, `docs/contributing.md`, `docs/eltenapps.md`. Klangten-specific: `docs/klangten-releases.md`.

**The server side lives in a separate, private repository** (the Klango server; package `klango/klangten/`, contract in its `KLANGTEN.md`). Its checkout path is recorded in that repository's own `CLAUDE.md`/`AGENTS.md`, not here. Rule for that side: implement Elten's HTTP/JSON *interface* (paths, field names, semantics) but never copy Elten code, comments, docs or translations into the server. Conversely, nothing from the private repository — original Klango code, sounds, themes or secrets — may be added to this public repository.

## Commands

```sh
bundle install
./run.sh                                       # run from source (--dev = local server, run.bat on Windows)
bundle exec ruby elten.rb                      # the same without the wrapper
KLANGTEN_API_URL=http://127.0.0.1:5100 bundle exec ruby elten.rb   # against a local Klangten dev server
ruby -c path/to/file.rb                        # syntax check (there is no test suite in this repo)
```

Server-side tests (private Klango server repository, they cover the API this client speaks):

```sh
cd <klango-server-repo>/klango_server
.venv/bin/python -m pytest -q tests                                  # full suite
.venv/bin/python -m pytest -q tests/test_klangten_forum.py           # one file
.venv/bin/python -m pytest -q tests/test_klangten_forum.py::test_x   # one test
.venv/bin/python -m klango.klangten --port 5100                      # Klangten dev server
```

Packaging (build scripts are not executable in git — call them through `sh`/`bat`):

```sh
./compile.sh --pkg                             # dist/osx/Klangten.pkg (--release = signed + notarized)
compile.bat --pkg                              # dist\windows\KlangtenSetup.exe
sh tools/build-osx-arm64.sh --app              # what compile.sh calls underneath
tools/build-windows.bat --pkg --build-id 2026091401   # multi-arch helper, needs an ARM64 host
```

- macOS: unsigned builds are **ad-hoc signed inside the build** (`cmake/macos_bundle.cmake`), before the launcher embeds its integrity hashes. Signing the bundle afterwards breaks the integrity check ("modified package file"); rebuild instead.
- Windows: `CMakePresets.json` requires the "Visual Studio 18 2026" generator. On a VS 2022 host configure manually (`cmake -S . -B build\launcher-windows-x64 -G "Visual Studio 17 2022" -A x64 -DELTEN_BUILD_ID=…`, `Win32` for x86) and build targets `EltenLauncher`, `EltenLauncherFacade` (x86), `EltenPkg`.
- The ARM64 Windows launcher can only be built on an ARM64 host (its Ruby runtime has to run during the build); `cmake/windows_bundle.cmake` therefore treats `elten-arm64.exe` as optional and the facade falls back to x64.
- Release ids, version bumping (three files) and publishing to the Klango server: `docs/klangten-releases.md`.

## Architecture notes that span files

- **`filelist` is the load order.** Every `src/**.rb` file must be listed in dependency order, optionally with `:windows` / `:linux` / `:osx` tags. A file missing here works in ad-hoc tests and fails in packaged builds.
- **Layers**: `src/eltenlink/` (JSON API client per resource) → `src/eapi/` (config, HTTP, speech, audio, notifications, programs) → `src/ui/` (audio-first controls, `loop_update`) → `src/scenes/` (`$scene` workflows) → `src/platforms/` + `src/ri/` (per-OS adapters).
- **Threads**: scenes do not run on the main thread; on Windows the main thread is the window message loop. Anything that profiles, hooks or drives the UI must target the scene thread.
- **Input path**: `EltenAPI::KeyboardState.update` receives `synthetic_keys` (the global `$setkeys` is injected there each frame), and typed characters come from `EltenWindow.take_character` via `getkeychar`. Elten ignores input while its window is not foreground — useful to know when automating.

## Klangten-specific structure and conventions

- **`src/eltenlink/klangten_config.rb`** holds `Klangten::Config` (API host, product name, `VERSION`, feature switches) and `Klangten::Updates` (installer names, arch, install commands). Env overrides: `KLANGTEN_API_URL`, `KLANGTEN_HTTP2=0`, `KLANGTEN_UPDATES=0`, `KLANGTEN_TCLIB`, `KLANGTEN_RELAY_HOST/_PORT`. The user-visible version also lives in `launcher/installer/inst_elten.iss` and `cmake/macos_bundle.cmake`.
- **`src/eapi/common/klangten.rb`** provides the fork notice, server-terms text and helpers; wrap text that must literally say "Elten" in `unbranded { … }`.
- **Branding is display-time**: `src/eapi/dictionary.rb` substitutes Elten→Klangten and EltenLink→Klango in translated output. Do not rename msgids.
- **Feed = Mastodon** (`src/eapi/mastodon/`, `src/scenes/mastodon_timeline.rb`); EltenLink feeds are gone.
- **Conferences = TeamConference** (`src/eapi/teamconference.rb`, libraries in `bin/`, token from `GET /api/v1/conference/token`); Elten's own VoIP/relay code was removed.
- **Built-in programs** live unpacked in `src/programs/` (youtube, filemanager, ffmpeg, mcp) and are loaded as trusted by `src/eapi/program_builtins.rb`; their translations are in `locale/programs/`.
- **Main menu order** is Community → Media → Files → Programs → Tools. In `src/eapi/mainmenu.rb` every `@menu.submenu` call *inside* the Community block nests into it — top-level entries must be added after that block closes.
- **Removed**: premium, payments, auctions, sponsors, calendar, tasks. `holds_premiumpackage`/`requires_premiumpackage` always return true, so former premium features are available to everyone.
- **Two update channels**: `stable`/`rc`/`beta` come from the Klango server, `rolling` from the public GitHub releases (`src/eltenlink/klangten_github.rb`, settings page "Auto updater"). `get_updatesbranch` never sends `rolling` to the server, and the rolling channel is checked at startup and on demand only, never polled.
- **Coexistence with Elten** must be preserved when touching packaging or platform code: data dir `…/sixdotsIT/klangten`, `klangten.ini`/`klangten.log`, window class `KLANGTENMAINWND`, autostart value `klangten`, temp dir `<temp>/klangten`, installer AppId, bundle id `it.sixdots.klangten`, NVDA add-on `KLANGTEN`.
- Add `Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.` to the header of every upstream file you change (GPL §5a); new files get a Klangten header.
- **Localisation**: English source strings via `_()`/`p_()`, German in `locale/de-DE/LC_MESSAGES/elten.po` recompiled with `msgfmt --check-format`. Never regenerate `locale/elten.pot` (see `docs/contributing.md`).

## Traps that already cost time

- Klango maps global forums and personal boards to **synthetic group ids above 10⁹**. Never build arrays indexed by group/forum id (`src/scenes/forum.rb` uses hashes); an array froze the client for a minute on macOS and crashed it on Windows.
- MSVC 2022 rejects string literals over ~16 KB (C2026). The embedded Ruby bootstrap in `launcher/src/launcher.cpp` is therefore split into two adjacent raw literals — keep each piece under the limit.
- `confirm()` focuses "No" by default; for actions the user explicitly chose, pass `default_yes: true` (see the sound theme download).
- The app bundle's development region is Polish, so `[NSLocale currentLocale]` reports e.g. `pl_DE`. First-run language uses `preferredLanguages` in `src/platforms/osx/ri/systemhelpers.rb`.
- Never let the client reach `elten.link`; the updater additionally rejects installer URLs whose scheme, host or port differ from the configured API.
- BASS (`bin/*`) is proprietary and Elten's licence has no linking exception — see `THIRD-PARTY-NOTICES.md` before shipping binaries.
- Klangten must not be mentioned publicly on klango.online until the fork is published on GitHub; server-side names, file prefixes and user agents are deliberately neutral.
