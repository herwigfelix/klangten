# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

**Klangten**, a GPLv3 fork of Elten 3 (Dawid Pieper). Development happens on `main`; `upstream-main` keeps the untouched upstream state this fork started from. Klangten keeps Elten's self-voicing, keyboard-driven UI but talks to a **Klango** server (`https://ten.klango.online`) instead of EltenLink, and installs side by side with a normal Elten. `readme.md` documents the fork and keeps the upstream README below "Original Elten README"; `NOTICE.md` and `THIRD-PARTY-NOTICES.md` carry the GPL §5a statements.

Upstream docs stay valid for the shared parts: `docs/architecture.md` (runtime model, `$scene`, interaction ownership), `docs/building.md`, `docs/contributing.md`, `docs/eltenapps.md`. Klangten-specific: `docs/klangten-releases.md`, `docs/testing.md` (the test harness).

**The server side lives in a separate, private repository** (the Klango server; package `klango/klangten/`, contract in its `KLANGTEN.md`). Its checkout path is recorded in that repository's own `CLAUDE.md`/`AGENTS.md`, not here. Rule for that side: implement Elten's HTTP/JSON *interface* (paths, field names, semantics) but never copy Elten code, comments, docs or translations into the server. Conversely, nothing from the private repository — original Klango code, sounds, themes or secrets — may be added to this public repository.

## Commands

```sh
bundle install
./run.sh                                       # run from source (--dev = local server, run.bat on Windows)
bundle exec ruby elten.rb                      # the same without the wrapper
KLANGTEN_API_URL=http://127.0.0.1:5100 bundle exec ruby elten.rb   # against a local Klangten dev server
ruby -c path/to/file.rb                        # syntax check
ruby test/run.rb                               # test suite: headless flow tests (rake test does the same)
ruby test/run.rb test/flows/test_forum.rb -n /reply/   # one file / matching tests
KLANGTEN_SERVER_DIR=<klango-server-repo>/klango_server ruby test/run.rb   # include the online tests
```

**Testing (`docs/testing.md`).** `test/support/klangten_test` runs the real core headless: same filelist, scenes, forms and input path, with test doubles only for window, speech and clipboard (swapped in by a hook in `elten.rb`), virtual time, a closed network and an empty data directory per test; each test is its own process. A test presses keys and checks what was heard (`k.press("down")`, `k.type("hans")`, `k.menu("Community", "Forum")`, `k.expect("…")`, `k.expect_sound("…")`); online tests start the real Klango server from `KLANGTEN_SERVER_DIR` and are skipped without it (public CI, `.github/workflows/tests.yml`).

- **Every new or changed feature gets a flow test** in `test/flows/test_<area>.rb`: the way in by keyboard, what the user hears, what arrives on the server. Bug fixes get a test that fails without the fix.
- A thread that runs for the whole session (a service started from the interface) must be registered in `test/support/klangten_test/hooks.rb`, otherwise `settle` waits for it forever; a new platform file that opens a window, speaks or uses the clipboard needs a test double in `KlangtenTestBoot::REPLACE`. Details and limits in `docs/testing.md`.

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
./compile.sh --dmg                             # dist/osx/Klangten.dmg (--release = signed + notarized)
compile.bat --pkg                              # dist\windows\KlangtenSetup.exe
sh tools/build-osx-arm64.sh --app              # what compile.sh calls underneath
tools/build-windows.bat --pkg --build-id 2026091401   # multi-arch helper, needs an ARM64 host
```

- macOS: unsigned builds are **ad-hoc signed inside the build** (`cmake/macos_bundle.cmake`), before the launcher embeds its integrity hashes. Signing the bundle afterwards breaks the integrity check ("modified package file"); rebuild instead.
- Windows: `CMakePresets.json` requires the "Visual Studio 18 2026" generator. On a VS 2022 host configure manually (`cmake -S . -B build\launcher-windows-x64 -G "Visual Studio 17 2022" -A x64 -DELTEN_BUILD_ID=…`, `Win32` for x86) and build targets `EltenLauncher`, `EltenLauncherFacade` (x86), `EltenPkg`.
- The ARM64 Windows launcher can only be built on an ARM64 host (its Ruby runtime has to run during the build); `cmake/windows_bundle.cmake` therefore treats `klangten-arm64.exe` as optional and the facade falls back to x64.
- Release ids, version bumping (three files) and publishing to the Klango server: `docs/klangten-releases.md`.

## Architecture notes that span files

- **`filelist` is the load order.** Every `src/**.rb` file must be listed in dependency order, optionally with `:windows` / `:linux` / `:osx` / `:ios` tags; `:!tag` *excludes* a file from one platform. A file missing here works in ad-hoc tests and fails in packaged builds.
- **Layers**: `src/eltenlink/` (JSON API client per resource) → `src/eapi/` (config, HTTP, speech, audio, notifications, programs) → `src/ui/` (audio-first controls, `loop_update`) → `src/scenes/` (`$scene` workflows) → `src/platforms/` + `src/ri/` (per-OS adapters).
- **Threads**: scenes do not run on the main thread; on Windows the main thread is the window message loop. Anything that profiles, hooks or drives the UI must target the scene thread.
- **Input path**: `EltenAPI::KeyboardState.update` receives `synthetic_keys` (the global `$setkeys` is injected there each frame), and typed characters come from `EltenWindow.take_character` via `getkeychar`. Elten ignores input while its window is not foreground — useful to know when automating.

## Klangten-specific structure and conventions

- **`src/eltenlink/klangten_config.rb`** holds `Klangten::Config` (API host, product name, `VERSION`, feature switches) and `Klangten::Updates` (installer names, arch, install commands). Env overrides: `KLANGTEN_API_URL`, `KLANGTEN_HTTP2=0`, `KLANGTEN_UPDATES=0`, `KLANGTEN_TCLIB`, `KLANGTEN_RELAY_HOST/_PORT`. The user-visible version also lives in `launcher/installer/inst_elten.iss` and `cmake/macos_bundle.cmake`; the Windows version resources read `VERSION` from `klangten_config.rb` at configure time.
- **Another server, another data directory** (`docs/klangten-start-options.md`): start options `--overwrite-config-path`, `--overwrite-recordings-path`, `--srv-host-base-url` (also `--x=v`, `x=v`; env `KLANGTEN_CONFIG_DIR`, `KLANGTEN_RECORDINGS_DIR`, `KLANGO_SRV_HOST_BASE_URL`) are parsed by `Klangten::Startup` (`src/eltenlink/klangten_startup.rb`, loaded early by `elten.rb` like the config) and act through the environment, so restarts, the updater and autostart keep them. `Klangten::Config.api_url` is `KLANGTEN_API_URL` (developer switch, never confirmed) > `ten.<host>` of the chosen server (IPs/localhost unchanged) > `ten.klango.online`. Anything belonging to the software (update check, installer, extras, error reports, Bass URL warm-up) must use `EltenLink::Client.software` / `Config.software_api_base_url` - the official server, without the session of the chosen one; `Klangten::Updates.trusted_url?` checks against it. Server-specific texts use `Config.server_terms_url`/`server_web_url`, `klangten_two_factor_telegram_bot(link)`, `klangten_two_factor_admin_contact`. Save locations go through `Dirs.documents`/`.music`/`.downloads` (never `Dirs.user + "Music"`), which follow `--overwrite-recordings-path`.
- **Foreign-server warning and licence lock**: `klangten_confirm_server` (`src/eapi/common/klangten.rb`) runs in `Scene_Loading` right before the first request; no request to the chosen server may happen before it. Confirmed servers live in `trusted_servers.txt` of the *standard* data directory (`Klangten::ServerTrust`), deliberately not in an overridden one. A server without licence answers 503 + plain text; `EltenAPI::HTTPClient#note_api_response` records it in `Klangten::ServerLock`, the client raises `EltenLink::Error` with code `server.license_locked` and the server's text, loading/login say it, `loop_update` announces it once otherwise.
- **`src/eapi/common/klangten.rb`** provides the fork notice, server-terms text and helpers; wrap text that must literally say "Elten" in `unbranded { … }`.
- **Branding is display-time**: `src/eapi/dictionary.rb` substitutes Elten→Klangten and EltenLink→Klango in translated output. Do not rename msgids.
- **Feed = Mastodon** (`src/eapi/mastodon/`, `src/scenes/mastodon_timeline.rb`); EltenLink feeds are gone.
- **Conferences = TeamConference** (`src/eapi/teamconference.rb`, libraries in `bin/`, on iOS linked into the app via `ios/scripts/fetch-teamconference.sh`, token from `GET /api/v1/conference/token`); Elten's own VoIP/relay code was removed. The library comes from the public TeamConference repository only; `tc_join_group_room` is optional (without it just the forum-group rooms disappear). Windows DLLs must be built with `+crt-static`, the installer ships no VC++ runtime.
- **Built-in programs** live unpacked in `src/programs/` (only mcp) and are loaded as trusted by `src/eapi/program_builtins.rb`. YouTube (`src/eapi/youtube.rb`, `Scene_YouTube`), file manager (`Scene_FileManager`), playlist (`src/eapi/playlist.rb`, `Scene_Playlist`), document reader (`src/eapi/document_text.rb`) and the encoders (`src/eapi/audio/encoders/mp3.rb` via bassenc_mp3; `ffmpeg.rb`: FFmpeg formats are always listed on Windows x64 and FFmpeg is downloaded when one is chosen - `MediaEncoders.prepare(encoder)` on the UI thread before encoding; system FFmpeg on macOS/Linux; no menu entry) are Klangten's own core code, clean-room rewrites of former Elten programs that carried no licence - never copy from those programs or from Klango. The main menu shows a scene only when its class exists and `available?` (if defined) is true.
- **Background playback and recordings** (0.4): `KlangtenBackgroundPlayer` (`src/eapi/backgroundplayer.rb`) plays one entry on while you work elsewhere; a player hands its sound over with B (`player(..., background: {...})`, `Player#detach`). It and the playlist take turns through `KlangtenMedia` (the one that starts pauses the other; `KlangtenMedia.suspend` around foreground players); `KlangtenMedia.tick` runs from `loop_update`. "Player: ..." quick actions (F7, Shift+F7, Shift+F5/F6, Control+F11 for the microphone, given once where free), `Scene_NowPlaying` (Media, Player). R records what plays: BASSenc_MP3 directly on the playing channel (`src/eapi/mediarecordings.rb`, no callbacks, works on the phones). Bookmarks for episodes/Internet Archive files: `KlangtenBookmarks`. Global player keys: `src/eapi/globalkeys.rb` + `src/platforms/{windows,osx}/eapi/globalkeys.rb`. Phones: `elten_host_audio_focus_*`. BASS cannot seek beyond the downloaded part of an internet file stream (`BASS_CONFIG_NET_SEEK` did not help), so a far bookmark waits for the download. Tests: `test/test_media.rb`, `test/flows/test_media.rb`.
- **Main menu order** is Community → Media → Files → Programs → Tools. In `src/eapi/mainmenu.rb` every `@menu.submenu` call *inside* the Community block nests into it — top-level entries must be added after that block closes.
- **Removed**: premium, payments, auctions, sponsors, calendar, tasks. `holds_premiumpackage`/`requires_premiumpackage` always return true, so former premium features are available to everyone.
- **iOS** (`ios/`, `src/platforms/ios/`): the same Ruby core embedded in a Swift app. Gestures and the on-screen keyboard feed an injection queue that `EltenWindow`/`EltenKeyboard` read, so scene code is untouched; host services (speech, clipboard, microphone, locale, open URL) are C entry points (`elten_host_*`) reached through Fiddle. The program system is off there (App Store rules), and the updater reports itself unsupported. Build: `ios/Klangten/assemble.sh` (it *generates* `project.yml` — change the heredoc, not just the file). `ios/README.md` has the details.
- **Android** (`android/`): Gradle app embedding a self-built static CRuby (`android/scripts/build-*.sh`). It runs the core on the **iOS platform layer**: platform `android` also carries the `:ios` tag, and `EltenSystemHelpers.android?` marks the few differences. `host_bridge.c` exports the same `elten_host_*` functions as the iOS host. Open native libraries by name, never by path (they stay inside the APK). `docs/android.md` has the build, the findings and the next steps.
- **What's new (F10)** is Elten 2's classic overview (`src/scenes/whatsnew.rb`), counted from the active notifications per category; the notification history is on Control+F10 (`:notificationhistory`, added once to existing installs), Shift+F10 stays the context menu. **Voice threads** carry `audio_name` (recorded title) from the server; the thread list plays it and keeps the text title silent (`SpeechCommands::SilentTextCommand`). New threads in voice forums record their title with a second `OpusRecordButton`; `create_audio_thread(name_audio:)` sends both recordings in one body, title first, with `name_audio_size` (the text name then carries only tag prefixes).
- **Two update channels** (since 0.2 there is no RC or Beta): `stable` comes from the Klango server, `rolling` from the public GitHub releases (`src/eltenlink/klangten_github.rb`, settings page "Auto updater"). `get_updatesbranch` always sends `stable`, and the rolling channel is checked at startup and on demand only, never polled. **Android** always updates from GitHub (`android_update_check`, compares versions, hands the APK to the system installer); its signing key lives outside the repository and must never change (`docs/klangten-releases.md`, section Android).
- **Coexistence with Elten** must be preserved when touching packaging or platform code: data dir `…/sixdotsIT/klangten`, `klangten.ini`/`klangten.log`, window class `KLANGTENMAINWND`, autostart value `klangten`, temp dir `<temp>/klangten`, installer AppId, bundle id `it.sixdots.klangten`, NVDA add-on `KLANGTEN`.
- Add `Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.` to the header of every upstream file you change (GPL §5a); new files get a Klangten header.
- **Localisation**: English source strings via `_()`/`p_()`, German in `locale/de-DE/LC_MESSAGES/elten.po` recompiled with `msgfmt --check-format`. Never regenerate `locale/elten.pot` (see `docs/contributing.md`).

## Traps that already cost time

- The Windows CI checks the sources out with **CRLF** line endings (Git for Windows `core.autocrlf`). Any pattern that parses our own source files must accept `\r` — the program manifest end marker did not, so no built-in program loaded on Windows in 0.2.0 and YouTube and the whole Files menu disappeared (fixed in 0.2.1, `src/eapi/program.rb`).
- A new version needs **three** things besides the three version strings: `locale/en-GB|de-DE/changelog/<x_y_z>.md` **and** an entry in the version table of `src/scenes/changes.rb` (e.g. `["0.21", "<date>", Klangten::Config::PRODUCT_NAME]` → file `0_2_1.md`). 0.2 was released without that entry, so its changelog never showed.
- Klango maps global forums and personal boards to **synthetic group ids above 10⁹**. Never build arrays indexed by group/forum id (`src/scenes/forum.rb` uses hashes); an array froze the client for a minute on macOS and crashed it on Windows.
- MSVC 2022 rejects string literals over ~16 KB (C2026). The embedded Ruby bootstrap in `launcher/src/launcher.cpp` is therefore split into two adjacent raw literals — keep each piece under the limit.
- `confirm()` focuses "No" by default; for actions the user explicitly chose, pass `default_yes: true` (see the sound theme download).
- The app bundle's development region is Polish, so `[NSLocale currentLocale]` reports e.g. `pl_DE`. First-run language uses `preferredLanguages` in `src/platforms/osx/ri/systemhelpers.rb`.
- Never let the client reach `elten.link`; the updater additionally rejects installer URLs whose scheme, host or port differ from the configured API.
- BASS (`bin/*`) is proprietary and Elten's licence has no linking exception — see `THIRD-PARTY-NOTICES.md` before shipping binaries.
- On Klango, **revoking a notification marks its content read** (message notifications are the unread messages themselves, forum/blog ones Klango's unseen events). Never revoke a notification before the view it opens has loaded: What's new and the notification list did, so "new messages"/"new blog posts" came up empty and said there was nothing new. Views that settle their own notifications (conversation, thread, blog post, mentions) are listed in `NotificationGroups#notification_group_cleared_by_view?`.
- **Program names changed in 0.4** (`elten.exe` → `klangten.exe`, `elten-<arch>.exe` → `klangten-<arch>.exe`, `MacOS/elten` → `MacOS/Klangten`, `/opt/klangten/elten` → `/opt/klangten/klangten`). Older clients update through code that can no longer be changed: they run the *new* package by its fixed name and restart nothing by program name, except Linux (`/opt/klangten/elten`, kept as a starter script). So never rename `KlangtenSetup.exe`/`Klangten.dmg`/`Klangten.apk`/`klangten-linux.run`, keep the Inno `[Run]` entry without `skipifsilent` (it is the restart after a silent update), and keep the `[Code]` in `inst_elten.iss` that stops old processes by PID from `{app}` only and moves shortcuts and the autostart value. Details: `docs/klangten-releases.md`, "Executable names". A build tree from before 0.4 still holds `elten*.exe`; `cmake/windows_bundle.cmake` leaves them out of the package.
- Klangten must not be mentioned publicly on klango.online until the fork is published on GitHub; server-side names, file prefixes and user agents are deliberately neutral.
