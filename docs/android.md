# Klangten for Android

Status: **phase 1**. The APK embeds CRuby and runs a probe inside the app sandbox;
the Klangten core itself does not run yet. Distribution is planned as our own APK
(later possibly F-Droid, which BASS rules out as long as it is in the app), not
Google Play. TalkBack has to be switched off while Klangten runs (v1 decision):
Klangten speaks for itself, like on the desktop.

## Build

Needs the Android SDK with NDK r28 (`~/Library/Android/sdk`), Java 17, a host
Ruby 4.0 and network access. Everything below writes only into `android/vendor/`
and `android/build/` (both gitignored).

```sh
android/scripts/build-runtime.sh     # libffi, libyaml, OpenSSL, CRuby, fiddle for arm64-v8a (a few minutes)
android/scripts/fetch-bass.sh        # BASS + add-ons from un4seen.com
android/scripts/stage-assets.sh      # Ruby stdlib + probe into build/assets, TeamConference into vendor/jnilibs
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb logcat -s Klangten Klangten-ruby
```

`ABI=x86_64` (etc.) builds another runtime; `app/build.gradle` currently packs
only `arm64-v8a`. TeamConference comes from the public TeamConference repository
(`dist/mobile/android/jniLibs`, override with `TEAMCONFERENCE_JNILIBS`).

## How it fits together

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

## Next steps

1. Stage the Klangten core (`src/`, `filelist`) into the assets and boot it with
   an Android platform layer (`src/platforms/android/`): `elten.rb` would otherwise
   detect Android as Linux (`RUBY_PLATFORM` is `aarch64-linux-android`) and load
   the SDL2/speech-dispatcher layer.
2. Host services through JNI, like the `elten_host_*` bridge on iOS: speech
   (TextToSpeech), clipboard, microphone permission, locale, opening URLs.
3. Input: a full-screen view that turns gestures and the hardware keyboard into
   the injection queue the scenes already read.
4. Release signing, more ABIs, update path for side-loaded APKs.
