# Testing Klangten

[Back to the project README](../readme.md). See also [Elten 3 architecture](architecture.md) and [Contributing to Elten 3](contributing.md).

Klangten is a self-voicing, keyboard-driven program, so the only honest way to check a feature is to use it: press keys and listen. The test harness in `test/support/` does exactly that, automatically. A test starts the **real** Klangten - the same scenes, forms, controls, menus and the same input path (`EltenAPI::KeyboardState.update`, `EltenWindow.take_character`) - but without a window, without sound and without waiting, and then checks what a user would have **heard**.

```sh
ruby test/run.rb                              # everything (seconds, not minutes)
ruby test/run.rb test/flows/test_login.rb     # one file
ruby test/run.rb -n /voice/                   # minitest options pass through
rake test                                     # the same through rake (TEST=file for one file)
KLANGTEN_SERVER_DIR=<checkout>/klango_server ruby test/run.rb   # with the online tests
```

`test/run.rb` uses `test/Gemfile` (the application's gems plus minitest) and installs nothing into the top-level bundle, which the release build packs into the Ruby runtime. Run `BUNDLE_GEMFILE=test/Gemfile bundle install` once if gems are missing.

The suite runs on macOS and Linux; GitHub Actions runs it on both (`.github/workflows/tests.yml`). Windows is not supported: the test platform layer replaces the macOS/Linux window and speech files only.

## How it works

| Part | In a test |
| --- | --- |
| Process | Every test method runs in a Ruby process of its own (`isolation.rb`): Klangten keeps its state in globals, class variables and singletons, so two tests can never share one. Loading the core takes about half a second; the tests of a file run in parallel. |
| Loading | `elten.rb` with its normal filelist. A small hook in `elten.rb` lets the harness swap the platform's window, speech and clipboard files for the doubles in `test/support/klangten_test/platform/` (`KlangtenTestBoot.source_for`) and start `src/main.rb` itself. Everything else is the shipped code. |
| Frames | Each `loop_update` stops at its start (in the test window's `begin_input_frame`) until the test releases exactly one frame. The test and Klangten run in lockstep, so every run is the same. |
| Time | Virtual. Scene threads read a virtual clock through `Time.now` and `Process.clock_gettime(CLOCK_MONOTONIC)`, and their `sleep` advances it instead of waiting - one frame is the 10 ms `loop_update` sleeps. `delay`, timers, key repeat, speech length and recording length behave as in real life, at any speed. While work started by the interface is running (an HTTP request, a `Tasks.run` worker) the clock stands still, so no timeout or "please wait" screen depends on how fast the machine is. |
| Speech | `KlangtenTestSpeech` (platform/speech.rb) is the only voice. Every utterance goes into the transcript; speaking takes virtual time in proportion to the text, the next key interrupts it, and indexed sequences fire their embedded sounds when the "voice" reaches them. |
| Sound | Theme sounds go into the transcript under their name (`play_sound` is wrapped). BASS itself runs on its "no sound" device: streams are created and decoded normally, nothing reaches a sound card, so machines without one (CI) work. |
| Microphone | `EltenRecorderRuntime::InputRecording` is replaced by a generated signal (`microphone.rb`) delivered in virtual time; the encoders, the Ogg writer and the upload are the real code. |
| Background threads | Roles in `runtime.rb`: scene threads (virtual time), service loops that run in step with the frames (`$thr2`, the notification service), work started by the interface (the clock waits for it) and real background services (NVDA poll, MCP, TeamConference worker). |
| Network | Closed. Every Ruby TCP connection must go to the loopback interface, BASS URL streams and the conference library are checked by the same rule (`net_guard.rb`); anything else fails as an unreachable network would and is listed in `app.blocked_connections`. |
| Data | Each test has an empty data directory (`klangten.ini`: English, Windows keyboard scheme, licence accepted, no welcome wizard), its own `HOME`, temp and XDG directories. The installation on the machine stays invisible and untouched. |

## Writing a test

```ruby
require_relative "../test_helper"

class ExampleTest < KlangtenTest::FlowTest
  def test_offline_start_menu
    k = klangten              # a Klangten with the network closed
    k.boot
    k.expect("Log in", since: 0)
    k.press("down")
    k.expect("Register")
  end

  def test_something_online
    server.create_user("hans") # the real Klango server; skipped where unavailable
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Messages")
    k.expect("Messages: Empty list")
  end
end
```

Flow tests live in `test/flows/test_<area>.rb`, tests of the harness itself in `test/harness/`. Shared fixtures go into a file without the `test_` prefix (for example `test/flows/forum_world.rb`). Test files are loaded in the minitest process too, so constants of Klangten (`Scene_Main`, `Bass`) may only appear inside test methods.

`klangten(server: nil, language: "en-GB", keyboard_scheme: :windows, settings: {}, wall_start: nil)` takes:

- `language` - the interface language. Tests check the English source strings (the msgids) by default, so a changed translation does not break them; pass `"de-DE"` to test the German texts.
- `keyboard_scheme` - `:windows` (Control as main modifier) on every machine, so tests behave the same on macOS and Linux; `:macos` for the Command shortcuts.
- `settings` - more `klangten.ini` values, e.g. `{ "Interface" => { "TypingEcho" => "words" } }`.
- `wall_start` - a fixed start time for the wall clock (`Time.now`), for tests about dates; by default it starts at the real time.

## Starting Klangten

```ruby
k.boot                        # src/main.rb: loading screen, start menu or auto-login
k.boot_logged_in("hans")      # an auto-login key is stored first: ends in the main window
k.start { selector(["A", "B"], header: "Pick") }  # one control or dialog as the scene
k.result                      # value of the start block, once it has finished
k.finished?                   # Klangten (main.rb or the block) has ended
```

`boot*` and `start` run until Klangten waits for input (see `settle`). `start` does the part of the loading screen that controls need (configuration, locale, sound theme, BASS) and then runs the block on Klangten's scene thread. A crash on the scene thread fails the test with its backtrace and the last things heard.

## Driving it

```ruby
k.press("down")                      # key down, held one frame, released; then settle
k.press("right", "right", "enter")
k.press("ctrl+n") / k.press("shift+tab") / k.press("<c-s-i>") / k.press("alt+f4")
k.press("alt")                       # the menu bar opens on the release
k.type("Hallo Welt")                 # character by character, key event plus character
k.hold("down"); k.run_for(1); k.release("down")   # key repeat
k.menu("Community", "Forum")         # menu bar: right on the top level, down below, Enter on the last
k.move_to("Send")                    # Tab until "Send" is heard; key: "down" for lists
k.close_window                       # quit shortcut (Alt+F4 / Cmd+Q); quit: false = close button only
k.run_for(2)                         # 2 virtual seconds
k.wait_for("New message")            # run until this has been heard
k.settle                             # run until Klangten is quiet and waits for input
k.step(5)                            # exactly five frames
k.call { insert_scene(Scene_Notes.new) }   # code on the scene thread, for entry points without a key
```

Key names: `down up left right enter esc tab space backspace delete insert home end pgup pgdown apps f1`..`f12`, letters and digits, punctuation on the US layout, modifiers `ctrl shift alt cmd` (combined with `+`, or `<c-…>`, `<s-…>`, `<a-…>`, `<m-…>`). Control is reported as `VK_CONTROL` plus `VK_LCONTROL`, the way the desktop layers do.

`settle` is reached when nothing is spoken, no `delay` runs, no work started by the interface is running, and nothing new has been heard for 0.3 virtual seconds. `press(..., settle: false)` and `type(..., settle: false)` leave it to the test, for example to press a key while something is still being said.

## Checking

```ruby
k.expect("Messages")          # substring, case-insensitive, since the last key
k.expect_not("Error")
k.expect_sound("menu_open")   # theme sound name (file name in audio/ without .ogg)
k.spoken / k.sounds           # lists since the mark (the last press/type)
k.spoken(since: 0)            # everything; k.mark sets the mark by hand
k.last_spoken / k.all_spoken
puts k.transcript             # readable, with virtual timestamps
k.clipboard.text              # the test's clipboard (the machine's stays untouched)
k.uploads                     # binary API uploads byte for byte: method, path, params, body
k.opus_encoders               # [{application: 2049, channels: 2, bitrate: 64000}, ...]
k.microphone.recordings       # what the fake microphone recorded (seconds)
k.message_boxes               # native message boxes (answered with the first button)
k.opened_urls                 # URLs Klangten tried to open in a browser
k.blocked_connections         # connections the network guard refused
k.log                         # the test's klangten.log
k.scene                       # $scene
```

Every `press` and `type` (each character) sets the mark, so `expect` after a key checks what **that** key caused. `expect`, `expect_not` and `expect_sound` count as minitest assertions; a failure lists what was heard instead.

## The Klango server

The server is a separate, private project; this repository contains only the code that starts it. Online tests need its checkout:

```sh
export KLANGTEN_SERVER_DIR=<checkout>/klango_server     # with a .venv (python -m klango.klangten)
export KLANGTEN_SERVER_PYTHON=/path/to/python           # optional, default <dir>/.venv/bin/python
```

`server` (in a FlowTest) starts `python -m klango.klangten --port <free port>` with an empty database in the test directory, and skips the test where the server is not configured - as on the public CI.

```ruby
server.create_user("hans", "anna")          # password KlangtenTest::PASSWORD, terms accepted
server.create_user("root", admin: true)
server.api("POST", "/api/v1/forum/groups", { name: "G", public: 1, open: 1 }, as: "anna")
server.sql("SELECT author, body FROM posts WHERE thread_id = ?", 1)   # rows of the server database
server.requests                             # [["POST", "/api/v1/session?...", 200], ...]
server.autologin_token("hans")              # what boot_logged_in stores
server.url / server.db_path / server.storage_dir / server.log
```

Prefer `server.api` (the JSON API Klangten itself speaks, as the user who would do it) for test data, and `server.sql` for checking what arrived. Test files must not copy server code.

## Local web content: FakeWeb

```ruby
web = fake_web                                     # a web server on a free loopback port
url = web.file("/song.mp3", bytes, mime: "audio/mpeg")   # with Range support
web.text("/page.html", "<h1>Hi</h1>", mime: "text/html")
web.json("/feed", { "items" => [] })
web.error("/missing", 404)
web.redirect("/old", "/new")
web.dynamic("/echo") { |req| [200, { "Content-Type" => "text/plain" }, req.body] }
web.url("/song.mp3")                               # http://127.0.0.1:<port>/song.mp3
web.requests                                       # method, path, query, headers, body
```

Both Ruby HTTP and BASS URL streams reach it. `KlangtenTest::Media.wav(seconds:, hz:)` makes a WAV file to serve; `KlangtenTest::Media.ogg_opus(bytes)` reads an Ogg Opus file (channels, `seconds`, `kbps`, `modes` - packets per SILK/hybrid/CELT mode -, `frame_ms`).

## The microphone

`k.microphone.signal = :music` (default: a chord with overtones plus noise, which keeps a variable-bitrate encoder busy across the band), `:tone` (440 Hz), `:silence` or a lambda `->(t) { value }`. The signal is deterministic, and it is delivered in virtual time: `run_for(3)` while recording records three seconds. `test/flows/test_forum_voice.rb` shows the whole path from the record button to the server.

## Never a real sound card

The harness forbids everything that could open a real audio device (`forbid_real_audio_devices` in `hooks.rb`): BASS plays only on its "no sound" device and never records, the conference library (TeamConference, which opens CoreAudio/WASAPI by itself through cpal) is not loaded at all, and Chrome does not start. In October 2026 test runs on a developer's Mac that still loaded the conference library drove coreaudiod into an overload loop; the machine's audio hung until it was switched off. Keep it that way: a new native library that can touch an audio device needs the same treatment before any test loads it, and prefer running the suite on Linux (CI or a VM) rather than on a machine someone is listening to.

## Rules for new code and new tests

- **Every new or changed feature gets a flow test** in `test/flows/test_<area>.rb`: the way in (keys), what is heard, what arrives on the server.
- No `sleep` in tests, no real network addresses, no reliance on the machine's installation.
- Time in Klangten: measure it with `Time.now` or `Process.clock_gettime(Process::CLOCK_MONOTONIC)` on the scene thread (both are virtual in tests) and wait with `loop_update`, `delay` or a `Runner` timer, not with a busy loop around another clock.
- Long-running threads: work with an end (requests, `Tasks.run`) needs nothing - the harness waits for threads started by the interface. A **service that runs for the whole session** must be registered in `test/support/klangten_test/hooks.rb` (`wrap_background_services`), otherwise `settle` reports it as never-ending work ("Busy because: work thread ..."). A service loop the interface waits for by time (like the notification service) becomes a ticker there.
- Native libraries that open connections themselves (BASS URL streams, TeamConference) are checked in `hooks.rb`; a new one needs the same check.
- A new platform file that opens a window, speaks or touches the clipboard needs an entry in `KlangtenTestBoot::REPLACE` (`test/support/klangten_test/boot.rb`).

## Limits

- Windows is not covered (the test platform layer stands in for the macOS and Linux files only).
- NVDA, SAPI, VoiceOver and the screen reader paths are not exercised; the speech double reports itself as a voice with index support.
- Audio is decoded but never played: tests can check that a stream opened and how long it is, not how it sounds. The recorder's real input (BASS recording, microphone permission) is replaced.
- TeamConference loads its real library, but conferences are not tested yet: the library may only connect to loopback, and the test server hands out no conference token (`KLANGO_CONF_SECRET` is cleared for it).
- The harness wraps a few methods by name (`play_sound`, `delay`, `thr1`/`thr2`, `NotificationService.start`/`worker_loop`, `Programs.load_all`, `Bass.raw_create_url_stream`, `EltenLink::Client#api_binary_payload` and others in `hooks.rb`). If one is renamed, every test fails with a message naming it.

## When a test fails

- The failure shows what was heard; `puts k.transcript` shows everything with virtual timestamps.
- `KLANGTEN_TEST_VERBOSE=1` prints what each test process wrote; `KLANGTEN_TEST_KEEP=1` keeps the test directories (data directory with `klangten.log`, server database and `server.log`).
- "Klangten does not settle" lists why: speech still running, a `delay`, or work threads with their backtraces.
- "Klangten is stuck in one frame" means the scene thread did not reach its next `loop_update` within 20 real seconds; the report has the backtrace of every thread.
- `KLANGTEN_TEST_TIMEOUT` (default 300) limits one test process in real seconds.
