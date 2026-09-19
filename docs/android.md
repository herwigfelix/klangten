# Klangten for Android

Status: **phase 2**. The APK embeds CRuby and runs the Klangten core: it speaks
through Android's TextToSpeech and is driven by the same touch gestures as on
iOS. First-run setup, login and the scenes still need to be walked through on
real devices. Distribution is planned as our own APK
(later possibly F-Droid, which BASS rules out as long as it is in the app), not
Google Play. TalkBack has to be switched off while Klangten runs (v1 decision):
Klangten speaks for itself, like on the desktop.

## Build

Needs the Android SDK with NDK r28 (`~/Library/Android/sdk`), Java 17, a host
Ruby 4.0 and network access. Everything below writes only into `android/vendor/`
and `android/build/` (both gitignored).

```sh
android/scripts/build-runtime.sh     # libffi, libyaml, OpenSSL, CRuby, fiddle for arm64-v8a (a few minutes)
android/scripts/build-gems.sh        # bigdecimal, zstd-ruby, nokogiri (+ libxml2/libxslt), pure-Ruby gems
android/scripts/build-codecs.sh      # libopus/ogg/vorbis/vorbisenc/speexdsp.so
android/scripts/fetch-bass.sh        # BASS + add-ons from un4seen.com
android/scripts/stage-assets.sh      # stdlib, gems, the Klangten core into build/assets; TeamConference into vendor/jnilibs
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb logcat -s Klangten Klangten-ruby Klangten-speech Klangten-input
```

Debug builds log what Klangten says (`Klangten-speech`) and the recognised
gestures (`Klangten-input`); release builds do not. Gestures can also be sent
without touching the screen, which is how multi-finger gestures are tested on the
emulator: `adb shell am start -n it.sixdots.klangten/.MainActivity --es gesture two_finger_swipe_up`.
`--es entry probe.rb` on a fresh start runs the phase 1 probe instead of the core.

`ABI=x86_64` (etc.) builds another runtime; `app/build.gradle` currently packs
only `arm64-v8a`. TeamConference comes from the public TeamConference repository
(`dist/mobile/android/jniLibs`, override with `TEAMCONFERENCE_JNILIBS`).

## How it fits together

- **Android reuses the iOS platform layer.** `android_boot.rb` sets the platform
  to `android`; `EltenBoot.platform_tags` then adds `:ios`, so every `:ios` file
  in `filelist` loads (touch gestures, host bridge, speech, clipboard) and every
  `:!ios` file stays out (program system, updater). The few real differences are
  `EltenSystemHelpers.android?` branches: libraries are opened by name, the
  bridge lives in `libklangten.so`.
- `app/src/main/cpp/host_bridge.c` exports the same `elten_host_*` functions as
  the iOS host and forwards them to `Host.java` (TextToSpeech, clipboard, URLs,
  microphone permission, locale, system keyboard). `GestureView.java` recognises
  the iOS gesture vocabulary (1–4 fingers, swipes, taps, double taps, long press)
  and feeds the input queue that `IOSTouchInput` drains. The Back key is Escape.
- `android_boot.rb` rebuilds the CA bundle from the system roots into
  `resources/ssl/cert.pem` at every start, where `src/eapi/tls.rb` reads it.
- `app/src/main/cpp/klangten_jni.c` → `libklangten.so`: the JNI entry point plus
  the whole static runtime (`libruby-static.a`, `extinit.o`/`encinit.o`, every
  extension archive, fiddle, OpenSSL, libyaml, libffi). It boots Ruby through
  `ruby_options()` like the `ruby` executable, because only that path registers
  the encodings, the static extensions and the prelude. fiddle is a bundled gem,
  not a default extension, so it is registered by hand with `ruby_init_ext`.
  stdout/stderr go to logcat (`Klangten-ruby`).
- `RubyRuntime.java` copies `assets/ruby` (stdlib, later the core) to
  `files/ruby` once per installed APK, because `require` needs real files.
  The Ruby thread gets a 64 MB stack.
- Native libraries stay **inside the APK** (`extractNativeLibs=false`). Open them
  **by name** (`Fiddle.dlopen("libbass.so")`), never by path: there is no file at
  `nativeLibraryDir`. BASS is loaded once from Java first (`System.loadLibrary`),
  so its `JNI_OnLoad` sees the Java VM.
- The STL is `c++_shared`: the TeamConference library needs `libc++_shared.so`.

## Findings (spike and phase 1, September 2026)

| Topic | Result |
|---|---|
| CRuby 4.0.7 | builds and runs in the app; 28 extensions linked statically incl. openssl, psych, socket, zlib, json |
| API level | minimum 26: Bionic has `nl_langinfo` only from 26 on |
| Bionic | no libcrypt, no usable fork/setuid: `ac_cv_*` overrides from the Termux recipe |
| `make install` | would write default gems into the **host** Ruby; the script collects the results itself |
| libffi 3.8 | sets `FFI_EXEC_STATIC_TRAMP`: Fiddle closures work without writable+executable memory |
| TLS | OpenSSL ignores `SSL_CERT_FILE` in app processes. Android keeps roots as single PEM files (`/system/etc/security/cacerts`, `/apex/com.android.conscrypt/cacerts`); add them to `OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE`, as `src/eapi/tls.rb` does with its bundle |
| RubyGems | the prelude does not define `Gem` in the embedded runtime; `require "rubygems"` works |
| BASS 2.4.18.3 | core + mix, enc, enc_mp3, opus, flac, midi, hls, webm, alac; **no** Android build of bass_fx, bass_aac, bass_ac3, basswma, bass_spx, bass_vst (`Configuration.usefx` has no effect there) |
| 16 KB pages | every library is aligned to `0x4000` (`-Wl,-z,max-page-size=16384`) |
| TeamConference | public build loads, `tc_join_group_room` present |
| nokogiri | links against our own libxml2 2.13.9/libxslt 1.1.43 (Android has none); its polyfill needs `HAVE_XMLCTXTSETOPTIONS`/`HAVE_XMLSWITCHENCODINGNAME` or it duplicates libxml2 symbols. libxml2 is built without iconv (Bionic has it only from API 28) |
| Codecs | libtool's versioned sonames cannot go into an APK; `build-codecs.sh` wraps the static libraries as plain `libX.so` |
| Emulator | the `klangten-spike` AVD is 320×640 px: `adb shell input swipe` coordinates beyond that silently miss |

## Next steps

1. Walk through first-run setup, login and the main scenes on a real device;
   fix what the iOS layer assumes about iOS (paths, file manager root, audio focus).
2. Hardware keyboard: map Android key events to the virtual keys the scenes read.
3. YouTube via NewPipeExtractor (see below).
4. Release signing, more ABIs, update path for side-loaded APKs.

## YouTube (research, September 2026)

- **NewPipeExtractor** (GPL-3.0-or-later, v0.26.5 of 2026-08-15, releases every
  few weeks) is a pure Java library: JitPack `com.github.TeamNewPipe:NewPipeExtractor:v0.26.5`,
  dependencies nanojson, jsoup, protobuf-lite and Rhino (signature/n-parameter).
  The host implements its `Downloader` (OkHttp) and calls `NewPipe.init`. With
  minSdk 26 it needs core-library desugaring (`desugar_jdk_libs_nio`) and R8 keep
  rules for Rhino.
- Streams currently come from the VISIONOS InnerTube client; ANDROID/IOS clients
  were dropped because they need PO tokens. Search and metadata are robust; audio
  streams (Opus/WebM, M4A) break whenever YouTube forces SABR on the client in use
  (2026: three months, 8 March to 9 June). "Sign in to confirm you're not a bot"
  is an IP block and can only be reported.
- Playback through BASS: set the VISIONOS user agent (`BASS_CONFIG_NET_AGENT` or
  headers appended to the URL), fetch the URL right before playing and again on
  HTTP 403 (URLs carry `expire=` and are bound to the IP). Long audio is safer
  through a small chunking proxy on 127.0.0.1.
- Plan: Java facade (`search`, `audioUrl` returning JSON) called over JNI from a
  Ruby port of `src/programs/youtube`; about 4–5 days to search plus playback.
- iOS cannot use it (J2ObjC/GraalVM/TeaVM do not fit Rhino); the realistic path
  there is YouTubeKit (Swift), optionally with its self-hostable remote fallback.
