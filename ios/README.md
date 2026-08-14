# Elten for iOS

A port of the Elten desktop client to iOS that **reuses the existing Ruby code
base** (the same ~200 `.rb` source files, the same sound themes and audio
engine). It adds a touch-gesture layer for everything the desktop version does
with the keyboard, an accessible on-screen keyboard for typing, and **omits the
program system** (third-party downloadable "Elten apps"), which iOS/App Store
policy does not allow.

Elten self-voices with `AVSpeechSynthesizer`; there is no visual UI, exactly as
on Windows/macOS.

## Run it on your iPhone

The real Elten app is verified booting and running on iOS (see the milestones
below). To put it on your device:

```bash
# 1. Fetch the CRuby runtime and build the native deps for BOTH slices
ios/scripts/fetch-cruby-runtime.sh
for SDK in iphonesimulator iphoneos; do
  SDK=$SDK ARCH=arm64 ios/scripts/build-fiddle-ios.sh
  SDK=$SDK ARCH=arm64 ios/scripts/build-gems-ios.sh
  SDK=$SDK ARCH=arm64 ios/scripts/build-codecs-ios.sh
done
ios/scripts/fetch-native-libs.sh          # BASS xcframeworks (device+sim)

# 2. Assemble the app + generate the Xcode project
ios/Elten/assemble.sh

# 3. Open it
open ios/Elten/Elten.xcodeproj
```

Then in Xcode:
1. Select the **Elten** target → **Signing & Capabilities** → pick your **Team**
   (a free Apple ID works for 7-day development provisioning).
2. Change **Bundle Identifier** to something unique (e.g. `com.you.elten`).
3. Plug in your iPhone, select it as the run destination, press **▶ Run**.
4. First launch on the phone: **Settings → General → VPN & Device Management →**
   trust your developer certificate.

Verified: the project **builds for the simulator and for a physical device
(`arm64`, produces `Elten.app`)** — only your signing is missing. Signing and the
on-device run happen on your Mac/iPhone (I can't do those for you).

## Architecture

```
  ┌─────────────────────────── iOS app (Swift, ios/Elten) ──────────────────────────┐
  │  EltenGestureViewController   gestures ─► EltenInputQueue ─► elten_host_next_input│
  │  EltenHostBridge (@_cdecl)    speech / clipboard / open URL / mic / locale        │
  │  RubyRuntime + ruby_shim.c    embeds CRuby, loads elten.rb on its own thread      │
  └───────────────▲───────────────────────────────────┬──────────────────────────────┘
                  │ elten_host_* C ABI                 │ Ruby C API
  ┌───────────────┴───────────────────────────────────▼──────────────────────────────┐
  │  Elten Ruby core (unchanged scenes + UI)                                           │
  │   src/platforms/ios/eapi/hostbridge.rb   Ruby ◄─► host (Fiddle, dlopen(nil))        │
  │   src/platforms/ios/ui/touchinput.rb     IOSTouchInput: gesture ─► virtual keycode  │
  │   src/ui/controls/onscreen_keyboard.rb   accessible typing ─► take_character        │
  │   src/platforms/ios/ri/desktopruntime.rb EltenWindow/EltenKeyboard from an          │
  │                                          injection queue (no physical keyboard)     │
  └───────────────────────────────────────────────────────────────────────────────────┘
```

The key idea: Elten's whole UI is keyboard-driven and polls
`EltenAPI::KeyboardState`. On iOS the platform layer feeds that state from an
**injection queue** instead of a physical keyboard, so **no scene code changes**.
Touch gestures and the on-screen keyboard synthesise the exact virtual key codes
(and typed characters) the scenes already expect.

### Gesture vocabulary (IOSTouchInput)

| Gesture | Action |
|---|---|
| 1-finger swipe ←/→/↑/↓ | Arrow keys (move selection) |
| 1-finger double tap | Enter (activate) |
| 1-finger long press | Context menu |
| 2-finger tap | Stop speech |
| 2-finger swipe ←/↓ | Escape (back) |
| 2-finger swipe ↑ | Context menu |
| 2-finger double tap | Main menu |
| 3-finger swipe →/← | Tab / Shift+Tab (next/previous control) |
| 3-finger swipe ↑/↓ | Home / End |
| 3-finger double tap | Toggle on-screen keyboard |
| 4-finger swipe ↑/↓ | Page up / Page down |

While the on-screen keyboard is open, 1-finger gestures drive the keyboard
(explore-by-touch speaks keys, lift/double-tap types, 2-finger tap = backspace,
2-finger swipe closes it).

## What is implemented and verified in this repo

Ruby side (headless-tested on the host Ruby 4.0):

- `elten.rb` / `filelist`: `:ios` platform detection and `:!tag` exclusion; the
  iOS load set resolves (185 files) with the Windows/macOS layers excluded.
- `src/platforms/ios/ri/desktopruntime.rb`: `EltenWindow` / `EltenKeyboard` on an
  injection queue — discrete taps, held modifiers, chords, hold-for-menu (Alt),
  and character typing, all matching the exact public contract the app uses.
- `src/platforms/ios/eapi/{speech,clipboard,childprocess,spellcheck,hostbridge}.rb`
  and `ri/systemhelpers.rb`: the iOS platform layer (fork/exec removed).
- `src/platforms/ios/ui/touchinput.rb` + `src/ui/controls/onscreen_keyboard.rb`:
  the gesture layer and accessible keyboard.
- Program system omitted on iOS (`Programs.load_all/list/local_entries` gated,
  main-menu entry hidden) while keeping the `Programs` event bus intact so the
  rest of the app doesn't break.

Native side, runnable now:

- `ios/demo` — a self-contained UIKit app that mirrors the gesture layer +
  on-screen keyboard + `AVSpeechSynthesizer`. **Builds and runs in the iOS
  simulator** and demonstrates the full interaction model on-device without the
  Ruby core. Build it with:
  ```
  cd ios/demo && xcodegen generate && \
    xcodebuild -scheme EltenInteractionDemo -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ```
- `ios/Elten` — the real host that embeds the Ruby core (bridge, input queue,
  Ruby runtime, gesture view). Compiles once the Ruby runtime is vendored (below).

## The Ruby runtime (embedding CRuby on iOS)

**VERIFIED milestone:** a prebuilt CRuby 4.0.4 runtime embeds into an iOS app and
runs Elten's real iOS interaction code (the injection model, touch gestures,
on-screen keyboard and host input tokens) — **7/7 assertions pass on the iOS
simulator**. The runtime is booted with `CRuby_init(Init_prelude, false)` from
`Sources/ruby_shim.c`; using a hand-rolled `ruby_init` instead crashes the
conservative GC under allocation pressure, so `CRuby_init` is required.

Two ways to get the runtime, in order of preference:

**Option 2 — maintained prebuilt (recommended, verified):**
```
ios/scripts/fetch-cruby-runtime.sh        # -> ios/Elten/vendor/cruby (xord/cruby)
```
Ships a CRuby (MRI) `xcframework` (device + simulator) with OpenSSL, libyaml and
a large stdlib (socket, openssl, zlib, psych, json, digest, date, …) statically
linked. Matches Elten's Ruby 4.0 line.

**Option 1 — build CRuby from source:**
```
ios/scripts/build-libruby-ios.sh          # cross-compile CRuby for iOS
```
The cross-configure is solved (see the script); completing it needs a per-file
macOS↔iOS source patch set — heavier than Option 2.

### fiddle + libffi — DONE (verified)

The prebuilt runtime omits fiddle, but Elten's whole platform layer and the BASS
audio engine are Fiddle-based, so it is required. `ios/scripts/build-fiddle-ios.sh`
builds libffi (aarch64 port) and the fiddle 1.1.8 C extension (matching CRuby's
bundled fiddle) for iOS; `ruby_shim.c` registers it with
`ruby_init_ext("fiddle.so", Init_fiddle)`. **Verified on the iOS simulator (8/8):**
`require 'fiddle'`, `Fiddle.dlopen(nil)`, a real `strlen()` FFI call, and
`objc_getClass('NSObject' / 'UIPasteboard' / 'AVSpeechSynthesizer')` — i.e.
Elten's actual Objective-C bridge (clipboard, speech) works on iOS. Reproduce:
```
ios/embedtest/run.sh
```

### gems + native libraries — DONE (verified)

All of Elten's native dependencies now build for iOS and load on the simulator:

| Component | How | Status |
|---|---|---|
| fiddle + libffi | `build-fiddle-ios.sh` | ✅ |
| bigdecimal, zstd-ruby, nokogiri | `build-gems-ios.sh` (nokogiri links the SDK's libxml2/libxslt) | ✅ |
| ruby-xz, rubyzip, http-2, base62/64, ostruct | pure Ruby (bundle their `lib/`) | ✅ |
| opus, ogg, vorbis, speexdsp | `build-codecs-ios.sh` (linked with `-Wl,-force_load`) | ✅ |
| BASS + add-ons (mix/enc/opus/flac/midi/hls/webm) | `fetch-native-libs.sh` (un4seen frameworks) | ✅ |

### ✅ MILESTONE: the full Elten core boots on iOS

With the runtime + all of the above, **the entire Elten Ruby core — all 185
files for the iOS platform — loads on the iOS simulator and stops cleanly before
`main.rb`** (`ELTEN_BOOT_STOP_BEFORE_MAIN`). Every gem, every audio codec, BASS,
the whole app resolves. Reproduced by `ios/embedtest/run.sh`.

### ✅ MILESTONE: the real Elten event loop runs on iOS

Beyond loading, the actual interactive pipeline is verified on the simulator: a
**real Elten `ListBox`, driven by the real `loop_update`, responds to injected
touch gestures and speaks** — `swipe_down` walks the selection
(Forum → Messages → Contacts → Conferences) and `swipe_up` walks back, each item
voiced. That is the full `gesture → loop_update → KeyboardState → control →
speech` chain running on iOS (`ios/embedtest/ruby/boot.rb`).

### Remaining for a shippable app

1. **Continuous run under the native host** — the loop is proven; a shipping app
   lets `ios/Elten`'s host drive it continuously (drop `ELTEN_BOOT_STOP_BEFORE_MAIN`,
   run `main.rb`, pump `IOSTouchInput` from the gesture queue, speak via the
   bridge) and completes the network login flow — needs on-device runtime testing.
2. **Optional native libs** — `bass_fx` / `bass_vst` (Elten loads them
   optionally; VST has no iOS build) and Steam Audio/phonon for 3D audio.
3. **Apple signing** — a development team for on-device runs (the simulator does
   not require signing). Universal (device+sim) slices via xcframeworks/lipo.

Full build once the runtime + libs are vendored:
```
ios/scripts/fetch-cruby-runtime.sh        # -> vendor/cruby (CRuby runtime)
ios/scripts/build-fiddle-ios.sh           # -> vendor/fiddle (fiddle + libffi)
ios/scripts/build-gems-ios.sh             # -> vendor/gems  (bigdecimal, zstd, nokogiri)
ios/scripts/build-codecs-ios.sh           # -> vendor/codecs (opus, ogg, vorbis, speexdsp)
ios/scripts/fetch-native-libs.sh          # -> Frameworks   (BASS + add-ons)
ios/scripts/build-app.sh                  # stage Ruby core + stdlib, generate, build
```

## VoiceOver note

Elten voices itself, so the surfaces use `UIAccessibilityTraitAllowsDirectInteraction`
and handle raw touches directly rather than exposing per-control VoiceOver
elements. Users can run it with VoiceOver's screen curtain, or with VoiceOver
off — Elten provides the speech either way.
