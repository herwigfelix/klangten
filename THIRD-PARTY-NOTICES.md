# Third-party notices

Klangten (a modified version of Elten 3) is licensed under the GNU General Public License, version 3. It ships with, downloads at build time or loads at run time the third-party components listed below. Each component remains under its own licence.

This inventory was compiled from the files in this repository (September 2026). Versions come from embedded version resources or strings in the binaries and are best effort. No licence files are stored next to the binaries in `bin/`; the licence texts referenced here must be added to release packages. Entries marked **to verify** still need to be checked.

## Native libraries in `bin/`

Platform abbreviations: w86/w64/warm = `windows-x86`/`windows-x64`/`windows-arm64`, l86/l64/larm = `linux-x86`/`linux-x64`/`linux-arm64`, osx = `osx`.

### BASS audio library family — proprietary

| Library | Author | Version (Windows) | Platforms |
| --- | --- | --- | --- |
| bass | Un4seen Developments | 2.4.18 | all |
| bassenc, bassenc_mp3, bassflac, basshls, bassmidi, bassmix, bassopus, basswebm | Un4seen Developments | 2.4.x | all |
| bassalac | Un4seen Developments | 2.4.1 | w86, w64, l86, l64, larm |
| basswma | Un4seen Developments | 2.4.5 | w86, w64 |
| bass_fx | JOBnik! (Arthur Aminov) | 2.4 | all |
| bass_aac, bass_ac3, bass_spx | MaresWEB / Sebastian Andersson | 2.4.x | Windows, Linux (bass_spx also osx) |
| bass_vst | Bjoern Petersen Software Design and Development | 2.4.1 | w86, w64, osx |

- **Licence:** proprietary freeware from Un4seen Developments (<https://www.un4seen.com/bass.html>). Free only for non-commercial use; commercial use (including sales or advertising revenue) needs a paid licence; redistribution only as part of an end-user product. The add-ons by other authors have their own terms (**to verify**).
- **GPL compatibility:** BASS is **not GPL-compatible**. Elten's licence contains no additional permission (GPL section 7) for linking with BASS. Klangten therefore needs either an explicit exception from the copyright holders of Elten (Dawid Pieper and the other contributors) for BASS, or a replacement of BASS with a GPL-compatible audio library (upstream plans a LINDAR backend, see `docs/roadmap.md`). Until this is resolved, binary distribution of Klangten with BASS is legally unclear.

### Steam Audio (Valve) — Apache License 2.0

- `phonon.dll` (w86, w64, warm; 4.8.1), `libphonon.so` (Linux; 4.4.0 strings), `libphonon.dylib` (osx; 4.4.0 strings).
- Licence: Apache-2.0, <https://github.com/ValveSoftware/steam-audio/blob/master/LICENSE.md>. The licence text and any NOTICE file of Steam Audio must accompany binary distributions.
- Embedded components found in the binaries: zlib (1.2.13 / 1.3.1, zlib licence, Copyright 1995-2024 Jean-loup Gailly and Mark Adler), libmysofa with `default.sofa` (BSD-3-Clause, **to verify**).

### AMD TrueAudioNext — MIT

- `windows-x64/TrueAudioNext.dll`, `windows-x64/GPUUtilities.dll` (optional Steam Audio add-on).
- Licence: MIT, "Copyright (c) 2016-2019 Advanced Micro Devices, Inc." (notice embedded in `TrueAudioNext.dll`). `GPUUtilities.dll` references OpenCL and AMF (**to verify**).

### Codecs and compression — BSD-style / public domain

| Component | Files | Version | Licence |
| --- | --- | --- | --- |
| Opus (Xiph.Org) | `opus.dll`, `libopus.so.0`, `libopus.dylib` | 1.6.1 (1.5.2 w86, 1.3.1 larm) | BSD-3-Clause |
| libogg (Xiph.Org) | `ogg.dll`, `libogg.so.0`, `libogg.dylib` | 1.3.6 | BSD-3-Clause |
| libvorbis / libvorbisenc (Xiph.Org) | `libvorbis.*`, `libvorbisenc.so.2` (l64, l86) | 1.3.7 | BSD-3-Clause |
| SpeexDSP (Xiph.Org) | `libspeexdsp.*` | 1.2.1 | BSD-3-Clause |
| Zstandard (Meta) | `libzstd.*` | 1.5.7 (1.5.0 w86, 1.5.4 larm) | BSD-3-Clause (dual GPL-2.0) |
| XZ Utils liblzma (Tukaani) | `liblzma.*` | 5.8.3 (5.4.1 larm) | 0BSD / public domain |
| SQLite | `libsqlite3-0.dll` (Windows) | 3.53.3 | public domain |

The BSD licences require that their copyright notices and licence texts are reproduced in binary distributions.

### NVDA controller — GPL

- `nvdaHelperRemote.dll` (w86 2019.2.1, w64 2025.3, warm 2026.1.1), "Copyright (C) 2006-20xx NVDA Contributors", NV Access.
- Licence: NVDA is "GNU GPL version 2 or later" with exceptions in current releases (<https://github.com/nvaccess/nvda/blob/master/copying.txt>); older releases were GPL-2.0-only. **To verify** for each shipped version, especially the 2019.2.1 build (w86), whether it is GPL-2.0-only and therefore incompatible with GPL-3.0. The corresponding NVDA source (<https://github.com/nvaccess/nvda>, matching release tag) must be offered with binary distributions.

### Used from the system, not shipped

- SDL2 (Linux, zlib licence), speech-dispatcher with espeak-ng/RHVoice (Linux), SAPI (Windows), macOS system frameworks.

## Ruby runtime and gems

- **Ruby** 4.0.6 (3.4.10 on Windows x86): Ruby licence / BSD-2-Clause. Built from source on Linux and macOS (`cmake/EltenRubyRuntime.cmake`).
- **RubyInstaller2** (Windows): BSD-3-Clause, with the `ruby_builtin_dlls` it ships (OpenSSL Apache-2.0, libffi MIT, libyaml MIT, GMP LGPL-3.0/GPL-2.0, zlib zlib licence and others; **to verify** per release). LGPL libraries must remain replaceable by the user.
- **MSYS2** packages used for the Windows build (gcc runtime, sqlite3, libxslt/libxml2, pkgconf): mixed licences (**to verify**).
- **Linux/macOS bundled system libraries** copied by `cmake/bundle_linux_libs.cmake` / `cmake/macos_bundle.cmake` (for example OpenSSL 3 Apache-2.0, libxcrypt LGPL-2.1, brotli MIT): depend on the build host (**to verify** per release).
- **CA certificate bundle** `ssl/cert.pem`, copied at build time from RubyInstaller or the build host's OpenSSL (typically the Mozilla CA list, MPL-2.0).

Gems from `Gemfile.lock`:

| Gem | Version | Licence |
| --- | --- | --- |
| base62 | 1.0.0 | MIT (**to verify**) |
| base64 | 0.3.0 | Ruby / BSD-2-Clause |
| bigdecimal | 3.3.1 | Ruby / BSD-2-Clause |
| fiddle | 1.1.8 | Ruby / BSD-2-Clause |
| http-2 | 1.1.3 | MIT |
| mini_portile2 | 2.8.9 | MIT |
| net-http | 0.9.1 | Ruby / BSD-2-Clause |
| nokogiri | 1.19.4 | MIT; bundles or links libxml2 (MIT), libxslt (MIT), gumbo (Apache-2.0) and, depending on the platform, libiconv (LGPL-2.1) |
| ostruct | 0.6.3 | Ruby / BSD-2-Clause |
| racc | 1.8.1 | Ruby / BSD-2-Clause |
| ruby-xz | 1.0.3 | MIT |
| rubyzip | 3.2.2 | BSD-2-Clause |
| sqlite3 | 2.9.5 | BSD-3-Clause (SQLite itself public domain) |
| uri | 1.1.1 | Ruby / BSD-2-Clause |
| win32ole | 1.9.2 (Windows) | Ruby / BSD-2-Clause |
| zstd-ruby | 2.0.6 | BSD-3-Clause (bundles Zstandard) |

## First-party parts of the repository

- `launcher/`, `ext/windows/EltenSapiBridge/`, `nvda/elten/` (NVDA add-on), `tools/`, `src/`: Copyright (C) 2014-2026 Dawid Pieper (launcher Linux platform code with Arkadiusz Koziol), GPL-3.0, with Klangten modifications.
- `audio/*.ogg` (98 interface sounds): part of the Elten repository, no separate licence file; origin not documented (**to verify**).
- `resources/langs.json`: ISO 639-1 language list, origin not stated (**to verify**).
- `resources/locations.json`: appears to be derived from the "world-cities" dataset based on GeoNames (CC-BY-4.0, attribution required; **to verify**).
- Translations in `locale/`: contributed by the translators named in the `.po` headers under the project licence.

## Components added or planned for Klangten

### TeamConference core library — MIT

- Files: `bin/osx/libteamconference_core.dylib` (macOS arm64) and `bin/windows-x64/teamconference_core.dll` (Windows x64), and on iOS the static library linked into the app, built in September 2026 from TeamConference (<https://github.com/herwigfelix/TeamConference>, directory `lib/`, crate `teamconference-core` 0.1.0, commit 2268265). Loaded at run time by `src/eapi/teamconference.rb` for conferences and calls. Windows arm64/x86, Linux and Android have no build in Klangten yet; there, conferences report "not available".
- Build: `cd lib && cargo build --release` (Rust stable). macOS: copy `target/release/libteamconference_core.dylib`, run `install_name_tool -id @rpath/libteamconference_core.dylib` on the copy and sign it. Windows (MSVC toolchain, CMake for libopus): `set CMAKE_POLICY_VERSION_MINIMUM=3.5` and `set RUSTFLAGS=-C target-feature=+crt-static` (no VCRUNTIME140 dependency), then `cargo build --release`; the crate needs `client/src/` of the same repository next to `lib/`. iOS: the repository's mobile build produces `TeamConferenceCore.xcframework`; `ios/scripts/fetch-teamconference.sh` splits it into `ios/Klangten/vendor/teamconference/`. Other targets (for example `aarch64-pc-windows-msvc`, or Linux with ALSA headers) build the same way; place the result in `bin/<runtime>/` and extend `TeamConference::Library.file_name`. `KLANGTEN_TCLIB` overrides the path.
- Licence of TeamConference:

```
MIT License

Copyright (c) 2026 herwigfelix

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- Statically linked into the library: libopus (Xiph.Org, BSD-3-Clause, built from source by `audiopus_sys`) and the Rust crates below, taken from `cargo metadata --filter-platform` for the two shipped targets (normal and build dependencies; `bindgen`, `clang-sys` and `cexpr` are only used while building). The licence texts are part of each crate's source package on crates.io and must accompany binary releases. Notes: the `symphonia-*` crates are MPL-2.0 (unmodified; source at <https://github.com/pdeljanov/Symphonia>); `webpki-roots` is CDLA-Permissive-2.0; `ring` and `aws-lc-sys`/`aws-lc-rs` contain BoringSSL/OpenSSL-derived code under ISC, Apache-2.0 and BSD-style licences; `unicode-ident` includes Unicode-3.0 data. Where a crate offers a choice ("OR"), it is used under the MIT or Apache-2.0 option.

| Crate | Version | Licence | Platforms |
| --- | --- | --- | --- |
| aho-corasick | 1.1.4 | Unlicense OR MIT | osx, w64 |
| arrayvec | 0.7.6 | MIT OR Apache-2.0 | osx, w64 |
| audiopus_sys | 0.2.2 | ISC | osx, w64 |
| autocfg | 1.5.1 | Apache-2.0 OR MIT | osx, w64 |
| aws-lc-rs | 1.17.0 | ISC AND (Apache-2.0 OR ISC) | osx, w64 |
| aws-lc-sys | 0.41.0 | ISC AND (Apache-2.0 OR ISC) AND Apache-2.0 AND MIT AND BSD-3-Clause AND (Apache-2.0 OR ISC OR MIT) AND (Apache-2.0 OR ISC OR MIT-0) | osx, w64 |
| base64 | 0.22.1 | MIT OR Apache-2.0 | osx, w64 |
| bindgen | 0.72.1 | BSD-3-Clause | osx |
| bitflags | 1.3.2 | MIT/Apache-2.0 | osx, w64 |
| bitflags | 2.13.0 | MIT OR Apache-2.0 | osx |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 | osx, w64 |
| bytemuck | 1.25.0 | Zlib OR Apache-2.0 OR MIT | osx, w64 |
| byteorder | 1.5.0 | Unlicense OR MIT | osx, w64 |
| bytes | 1.11.1 | MIT | osx, w64 |
| cc | 1.2.64 | MIT OR Apache-2.0 | osx, w64 |
| cexpr | 0.6.0 | Apache-2.0/MIT | osx |
| cfg-if | 1.0.4 | MIT OR Apache-2.0 | osx, w64 |
| chrono | 0.4.45 | MIT OR Apache-2.0 | osx, w64 |
| clang-sys | 1.8.1 | Apache-2.0 | osx |
| cmake | 0.1.58 | MIT OR Apache-2.0 | osx, w64 |
| core-foundation-sys | 0.8.7 | MIT OR Apache-2.0 | osx |
| coreaudio-rs | 0.11.3 | MIT/Apache-2.0 | osx |
| coreaudio-sys | 0.2.18 | MIT | osx |
| cpal | 0.15.3 | Apache-2.0 | osx, w64 |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 | osx, w64 |
| crossbeam-channel | 0.5.15 | MIT OR Apache-2.0 | osx, w64 |
| crossbeam-utils | 0.8.21 | MIT OR Apache-2.0 | osx, w64 |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 | osx, w64 |
| dasp_sample | 0.11.0 | MIT OR Apache-2.0 | osx, w64 |
| data-encoding | 2.11.0 | MIT | osx, w64 |
| digest | 0.10.7 | MIT OR Apache-2.0 | osx, w64 |
| dunce | 1.0.5 | CC0-1.0 OR MIT-0 OR Apache-2.0 | osx, w64 |
| either | 1.16.0 | MIT OR Apache-2.0 | osx |
| encoding_rs | 0.8.35 | (Apache-2.0 OR MIT) AND BSD-3-Clause | osx, w64 |
| errno | 0.3.14 | MIT OR Apache-2.0 | osx |
| extended | 0.1.0 | MIT | osx, w64 |
| find-msvc-tools | 0.1.9 | MIT OR Apache-2.0 | osx, w64 |
| fs_extra | 1.3.0 | MIT | osx, w64 |
| futures-core | 0.3.32 | MIT OR Apache-2.0 | osx, w64 |
| futures-macro | 0.3.32 | MIT OR Apache-2.0 | osx, w64 |
| futures-sink | 0.3.32 | MIT OR Apache-2.0 | osx, w64 |
| futures-task | 0.3.32 | MIT OR Apache-2.0 | osx, w64 |
| futures-util | 0.3.32 | MIT OR Apache-2.0 | osx, w64 |
| generic-array | 0.14.7 | MIT | osx, w64 |
| getrandom | 0.2.17 | MIT OR Apache-2.0 | osx, w64 |
| getrandom | 0.3.4 | MIT OR Apache-2.0 | w64 |
| glob | 0.3.3 | MIT OR Apache-2.0 | osx |
| http | 1.4.2 | MIT OR Apache-2.0 | osx, w64 |
| httparse | 1.10.1 | MIT OR Apache-2.0 | osx, w64 |
| iana-time-zone | 0.1.65 | MIT OR Apache-2.0 | osx |
| itertools | 0.13.0 | MIT OR Apache-2.0 | osx |
| itoa | 1.0.18 | MIT OR Apache-2.0 | osx, w64 |
| jobserver | 0.1.34 | MIT OR Apache-2.0 | osx, w64 |
| lazy_static | 1.5.0 | MIT OR Apache-2.0 | osx, w64 |
| libc | 0.2.186 | MIT OR Apache-2.0 | osx |
| libloading | 0.8.9 | ISC | osx |
| lock_api | 0.4.14 | MIT OR Apache-2.0 | osx, w64 |
| log | 0.4.32 | MIT OR Apache-2.0 | osx, w64 |
| mach2 | 0.4.3 | BSD-2-Clause OR MIT OR Apache-2.0 | osx |
| matchers | 0.2.0 | MIT | osx, w64 |
| memchr | 2.8.2 | Unlicense OR MIT | osx, w64 |
| minimal-lexical | 0.2.1 | MIT/Apache-2.0 | osx |
| mio | 1.2.1 | MIT | osx, w64 |
| nom | 7.1.3 | MIT | osx |
| nu-ansi-term | 0.50.3 | MIT | osx, w64 |
| num-traits | 0.2.19 | MIT OR Apache-2.0 | osx, w64 |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | osx, w64 |
| opus | 0.3.1 | MIT/Apache-2.0 | osx, w64 |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 | osx, w64 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 | osx, w64 |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT | osx, w64 |
| pkg-config | 0.3.33 | MIT OR Apache-2.0 | osx, w64 |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 | osx, w64 |
| proc-macro2 | 1.0.106 | MIT OR Apache-2.0 | osx, w64 |
| quote | 1.0.45 | MIT OR Apache-2.0 | osx, w64 |
| rand | 0.8.6 | MIT OR Apache-2.0 | osx, w64 |
| rand_chacha | 0.3.1 | MIT OR Apache-2.0 | osx, w64 |
| rand_core | 0.6.4 | MIT OR Apache-2.0 | osx, w64 |
| regex | 1.12.4 | MIT OR Apache-2.0 | osx |
| regex-automata | 0.4.14 | MIT OR Apache-2.0 | osx, w64 |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 | osx, w64 |
| ring | 0.17.14 | Apache-2.0 AND ISC | osx, w64 |
| rustc-hash | 2.1.2 | Apache-2.0 OR MIT | osx |
| rustls | 0.23.40 | Apache-2.0 OR ISC OR MIT | osx, w64 |
| rustls-pki-types | 1.14.1 | MIT OR Apache-2.0 | osx, w64 |
| rustls-webpki | 0.103.13 | ISC | osx, w64 |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 | osx, w64 |
| serde | 1.0.228 | MIT OR Apache-2.0 | osx, w64 |
| serde_core | 1.0.228 | MIT OR Apache-2.0 | osx, w64 |
| serde_derive | 1.0.228 | MIT OR Apache-2.0 | osx, w64 |
| serde_json | 1.0.150 | MIT OR Apache-2.0 | osx, w64 |
| sha1 | 0.10.6 | MIT OR Apache-2.0 | osx, w64 |
| sharded-slab | 0.1.7 | MIT | osx, w64 |
| shlex | 1.3.0 | MIT OR Apache-2.0 | osx |
| shlex | 2.0.1 | MIT OR Apache-2.0 | osx, w64 |
| signal-hook-registry | 1.4.8 | MIT OR Apache-2.0 | osx |
| slab | 0.4.12 | MIT | osx, w64 |
| smallvec | 1.15.2 | MIT OR Apache-2.0 | osx, w64 |
| socket2 | 0.6.4 | MIT OR Apache-2.0 | osx, w64 |
| subtle | 2.6.1 | BSD-3-Clause | osx, w64 |
| symphonia | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-bundle-flac | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-bundle-mp3 | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-codec-aac | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-codec-adpcm | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-codec-alac | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-codec-pcm | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-codec-vorbis | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-core | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-format-caf | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-format-isomp4 | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-format-mkv | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-format-ogg | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-format-riff | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-metadata | 0.5.5 | MPL-2.0 | osx, w64 |
| symphonia-utils-xiph | 0.5.5 | MPL-2.0 | osx, w64 |
| syn | 2.0.117 | MIT OR Apache-2.0 | osx, w64 |
| thiserror | 1.0.69 | MIT OR Apache-2.0 | osx, w64 |
| thiserror-impl | 1.0.69 | MIT OR Apache-2.0 | osx, w64 |
| thread_local | 1.1.10 | MIT OR Apache-2.0 | osx, w64 |
| tokio | 1.52.3 | MIT | osx, w64 |
| tokio-macros | 2.7.0 | MIT | osx, w64 |
| tokio-rustls | 0.26.4 | MIT OR Apache-2.0 | osx, w64 |
| tokio-tungstenite | 0.24.0 | MIT | osx, w64 |
| tracing | 0.1.44 | MIT | osx, w64 |
| tracing-attributes | 0.1.31 | MIT | osx, w64 |
| tracing-core | 0.1.36 | MIT | osx, w64 |
| tracing-log | 0.2.0 | MIT | osx, w64 |
| tracing-subscriber | 0.3.23 | MIT | osx, w64 |
| tungstenite | 0.24.0 | MIT OR Apache-2.0 | osx, w64 |
| typenum | 1.20.1 | MIT OR Apache-2.0 | osx, w64 |
| unicode-ident | 1.0.24 | (MIT OR Apache-2.0) AND Unicode-3.0 | osx, w64 |
| untrusted | 0.9.0 | ISC | osx, w64 |
| utf-8 | 0.7.6 | MIT OR Apache-2.0 | osx, w64 |
| version_check | 0.9.5 | MIT/Apache-2.0 | osx, w64 |
| webpki-roots | 0.26.11 | CDLA-Permissive-2.0 | osx, w64 |
| webpki-roots | 1.0.7 | CDLA-Permissive-2.0 | osx, w64 |
| windows | 0.54.0 | MIT OR Apache-2.0 | w64 |
| windows-core | 0.54.0 | MIT OR Apache-2.0 | w64 |
| windows-link | 0.2.1 | MIT OR Apache-2.0 | w64 |
| windows-result | 0.1.2 | MIT OR Apache-2.0 | w64 |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 | w64 |
| windows-targets | 0.52.6 | MIT OR Apache-2.0 | w64 |
| windows_x86_64_msvc | 0.52.6 | MIT OR Apache-2.0 | w64 |
| zerocopy | 0.8.52 | BSD-2-Clause OR Apache-2.0 OR MIT | osx, w64 |
| zeroize | 1.9.0 | Apache-2.0 OR MIT | osx, w64 |
| zmij | 1.0.21 | MIT | osx, w64 |


### Client for Mastodon accounts — Klangten code, no third-party components

- The client that replaces Elten's feed (`src/eapi/mastodon/client.rb`, `src/eapi/mastodon/service.rb`, `src/eapi/eltensrv/feeds.rb`, `src/scenes/mastodon_timeline.rb`) is original Klangten code, Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT), GPL-3.0. It was written after the public Mastodon API documentation (<https://docs.joinmastodon.org>) and contains no code from Mastodon, other Mastodon clients or Klango's kmastodon app.
- It uses only the Ruby standard library (`net/http`, `json`, `uri`, `cgi`, `securerandom`, `time`) and the components already listed above (OpenSSL, CA bundle). No additional gem or library is bundled.
- "Mastodon" is a trademark of Mastodon gGmbH. Klangten uses the name only descriptively ("Mastodon account", "for Mastodon"); Klangten is not affiliated with or endorsed by Mastodon gGmbH.

## Media features: tools downloaded or used at run time

YouTube, the file manager, the playlist and the encoders are Klangten's own code (see `NOTICE.md`). They bring or load the following third-party components.

### Document reader — Klangten code, no bundled gems

The document reader of the file manager (`src/eapi/document_text.rb`, including its PDF reader) is Klangten's own code. It bundles no third-party gems and uses only rubyzip and Nokogiri, listed above, and the Ruby standard library.

### FFmpeg (FFmpeg encoders) — not shipped

- Klangten does **not** ship an FFmpeg binary. It runs FFmpeg as a separate process (`src/eapi/audio/encoders/ffmpeg.rb`) only for the additional formats AAC, M4A, FLAC, WMA, MP4, MKV, MOV and AVI; playback never uses it.
- **Windows x64:** the first time the user chooses one of the FFmpeg formats (conversion, YouTube download, saving a stream), Klangten asks and then downloads FFmpeg 9.0.2 "essentials" by Gyan Doshi (a build linked from <https://ffmpeg.org/download.html>) from <https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip>, checks the SHA-256 checksum `60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba` and extracts only `ffmpeg.exe` and the build's `LICENSE` (plus a short `version.txt`) into `ffmpeg/` in Klangten's data directory. The build is configured with `--enable-gpl --enable-version3`, so this FFmpeg is licensed under the **GNU General Public License, version 3**; it includes further libraries (for example LAME, libx264, libvpx) under GPL/LGPL-compatible licences listed by the build. Source code: <https://ffmpeg.org/download.html>, build scripts and component list: <https://www.gyan.dev/ffmpeg/builds/>. No build is offered for 32-bit or ARM64 Windows.
- **macOS and Linux:** an FFmpeg installed by the user (for example Homebrew, MacPorts, apt) is used; Klangten never downloads one there. Its licence depends on that installation.
- **iOS and Android:** not available.

### MP3 encoding — BASSenc_MP3

- MP3 files are written with `bassenc_mp3` (with `bassenc`, both already listed under the BASS family above; LAME-based, by Un4seen Developments) through `src/eapi/audio/encoders/mp3.rb`, on every platform including iOS and Android. No other MP3 encoder is shipped.

### yt-dlp and Deno (YouTube) — downloaded at run time

- **yt-dlp** (<https://github.com/yt-dlp/yt-dlp>): Klangten's YouTube feature downloads the latest official yt-dlp release for the platform on first use (the "onedir" zip builds where available, which start much faster than the single-file executables) and checks it against the release's `SHA2-256SUMS`. yt-dlp, Deno and the YouTube data are stored below Klangten's data directory in `youtube/` (programs in `youtube/bin`). yt-dlp is released under **The Unlicense** (public domain dedication). The stand-alone executables are built with PyInstaller and contain the Python runtime (PSF licence) and further bundled libraries under their own licences (see yt-dlp's `THIRD_PARTY_LICENSES.txt`).
- **Deno** (<https://github.com/denoland/deno>), used by yt-dlp as JavaScript runtime: downloaded from the official GitHub releases on first use and checked against the release's `.sha256sum` file; **MIT** licence, with bundled components (V8 BSD-3-Clause and others) under their own licences.
- Both are stored in `youtube/` in Klangten's data directory (`File.join(Dirs.eltendata, "youtube")`) and are not part of Klangten's distribution. On Android, YouTube uses NewPipeExtractor (GPL-3.0-or-later, TeamNewPipe) inside the app instead (`docs/android.md`); iOS has no YouTube feature. "YouTube" is a trademark of Google LLC and is used only descriptively.

## Components added in Klangten 0.4

### Spotify library (`ext/klangten_spotify`) — Klangten code with librespot (MIT)

- **Files:** `bin/osx/libklangten_spotify.dylib` (macOS arm64), `bin/windows-x64/klangten_spotify.dll`, `bin/windows-x86/klangten_spotify.dll` and, built by hand, `bin/linux-x64/` or `bin/linux-arm64/libklangten_spotify.so`. They are **not checked in**: the release workflows build them from `ext/klangten_spotify` (`tools/build-spotify.sh`, `tools\build-spotify.bat`) right before packaging, so every release contains a library built from the source in the same commit. Loaded at run time by `src/eapi/spotify.rb`; without the file Klangten only hides Spotify. Not shipped on iOS and Android.
- **Licence of the library's own code** (`ext/klangten_spotify/src`): Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT), GPL-3.0, like the rest of Klangten.
- **librespot** 0.8.0 (<https://github.com/librespot-org/librespot>): the crates `librespot-core`, `-playback`, `-metadata`, `-oauth`, `-protocol` and `-audio`, MIT licence, "Copyright (c) 2015 Paul Lietar" and the librespot contributors. `librespot-core` is **vendored with two small changes** in `ext/klangten_spotify/vendor/librespot-core` (no `exit(1)` for an account without Premium; wall-clock liveness of the connection); the changes and the full diff against the crates.io package are in `vendor/librespot-core/PATCHES.md`, the licence text in `vendor/librespot-core/LICENSE`. The changes are licensed under the MIT licence as well.
- **Statically linked crates**, from `cargo metadata --filter-platform` for the four targets (osx = aarch64-apple-darwin, w64/w86 = x86_64/i686-pc-windows-msvc, l64 = x86_64-unknown-linux-gnu; normal and build dependencies, so a few entries such as `cc`, `vergen` or the `*-macro`/`*-derive` crates are only used while building). The licence texts are part of each crate's source package on crates.io and must accompany binary releases. Notes: the `symphonia` crates are MPL-2.0 (unmodified; source <https://github.com/pdeljanov/Symphonia>); `priority-queue` is used under its MPL-2.0 option; `webpki` 0.22.4 carries an ISC-style licence file; `webpki-roots` is CDLA-Permissive-2.0; `ring` contains BoringSSL/OpenSSL-derived code under ISC and Apache-2.0; `encoding_rs` contains BSD-3-Clause parts; the `icu_*`/`zerovec`-family crates carry Unicode-3.0 data. Where a crate offers a choice ("OR"), it is used under the MIT or Apache-2.0 option.
- **Spotify:** "Spotify" is a trademark of Spotify AB. Klangten uses the name only descriptively and is not affiliated with or endorsed by Spotify. The library signs in through Spotify's own web login (OAuth, librespot's public client id) and needs a Spotify Premium account; it neither caches nor records audio, and Klangten offers no way to save it.

| Crate | Version | Licence | Platforms |
| --- | --- | --- | --- |
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | osx, w64, w86, l64 |
| aes | 0.8.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| aho-corasick | 1.1.4 | Unlicense OR MIT | osx, w64, w86, l64 |
| allocator-api2 | 0.2.21 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| arrayvec | 0.7.8 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| async-trait | 0.1.91 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| atomic-waker | 1.1.2 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| autocfg | 1.5.1 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| base64 | 0.22.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| base64ct | 1.8.3 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| bitflags | 1.3.2 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| bitflags | 2.13.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| bytemuck | 1.25.1 | Zlib OR Apache-2.0 OR MIT | osx, w64, w86, l64 |
| byteorder | 1.5.0 | Unlicense OR MIT | osx, w64, w86, l64 |
| bytes | 1.12.1 | MIT | osx, w64, w86, l64 |
| cc | 1.2.67 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| cfg-if | 1.0.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| cfg_aliases | 0.2.1 | MIT | osx, w64, w86, l64 |
| chacha20 | 0.10.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| chrono | 0.4.45 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| cipher | 0.4.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| const-oid | 0.9.6 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| core-foundation | 0.10.1 | MIT OR Apache-2.0 | osx |
| core-foundation | 0.9.4 | MIT OR Apache-2.0 | osx |
| core-foundation-sys | 0.8.7 | MIT OR Apache-2.0 | osx |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| cpufeatures | 0.3.0 | MIT OR Apache-2.0 | w64, w86, l64 |
| crc32fast | 1.5.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| ctr | 0.9.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| darling | 0.20.11 | MIT | osx, w64, w86, l64 |
| darling_core | 0.20.11 | MIT | osx, w64, w86, l64 |
| darling_macro | 0.20.11 | MIT | osx, w64, w86, l64 |
| data-encoding | 2.11.0 | MIT | osx, w64, w86, l64 |
| der | 0.7.10 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| deranged | 0.5.8 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| derive_builder | 0.20.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| derive_builder_core | 0.20.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| derive_builder_macro | 0.20.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| digest | 0.10.7 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| displaydoc | 0.2.6 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| either | 1.16.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| encoding_rs | 0.8.35 | (Apache-2.0 OR MIT) AND BSD-3-Clause | osx, w64, w86, l64 |
| equivalent | 1.0.2 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| errno | 0.3.14 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| fastrand | 2.5.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| find-msvc-tools | 0.1.9 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| flate2 | 1.1.9 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| fnv | 1.0.7 | Apache-2.0 / MIT | osx, w64, w86, l64 |
| foldhash | 0.2.0 | Zlib | osx, w64, w86, l64 |
| form_urlencoded | 1.2.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-channel | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-core | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-io | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-sink | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-task | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| futures-timer | 3.0.4 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| futures-util | 0.3.32 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| generic-array | 0.14.7 | MIT | osx, w64, w86, l64 |
| getrandom | 0.2.17 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| getrandom | 0.3.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| getrandom | 0.4.3 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| governor | 0.10.4 | MIT | osx, w64, w86, l64 |
| h2 | 0.4.15 | MIT | osx, w64, w86, l64 |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| headers | 0.4.1 | MIT | osx, w64, w86, l64 |
| headers-core | 0.3.0 | MIT | osx, w64, w86, l64 |
| hmac | 0.12.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| home | 0.5.12 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| http | 1.4.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| http-body | 1.1.0 | MIT | osx, w64, w86, l64 |
| http-body-util | 0.1.4 | MIT | osx, w64, w86, l64 |
| httparse | 1.10.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| httpdate | 1.0.3 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| hyper | 1.10.1 | MIT | osx, w64, w86, l64 |
| hyper-proxy2 | 0.1.0 | MIT | osx, w64, w86, l64 |
| hyper-rustls | 0.26.0 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| hyper-rustls | 0.27.9 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| hyper-util | 0.1.20 | MIT | osx, w64, w86, l64 |
| iana-time-zone | 0.1.65 | MIT OR Apache-2.0 | osx, l64 |
| icu_collections | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_locale_core | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_normalizer | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_normalizer_data | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_properties | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_properties_data | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| icu_provider | 2.2.0 | Unicode-3.0 | osx, w64, w86, l64 |
| ident_case | 1.0.1 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| idna | 1.1.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| indexmap | 2.14.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| inout | 0.1.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| ipnet | 2.12.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| is-docker | 0.2.0 | MIT | l64 |
| is-wsl | 0.4.0 | MIT | l64 |
| itoa | 1.0.18 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| lazy_static | 1.5.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| libc | 0.2.186 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| libm | 0.2.16 | MIT | osx, w64, w86, l64 |
| librespot-audio | 0.8.0 | MIT | osx, w64, w86, l64 |
| librespot-core | 0.8.0 | MIT | osx, w64, w86, l64 |
| librespot-metadata | 0.8.0 | MIT | osx, w64, w86, l64 |
| librespot-oauth | 0.8.0 | MIT | osx, w64, w86, l64 |
| librespot-playback | 0.8.0 | MIT | osx, w64, w86, l64 |
| librespot-protocol | 0.8.0 | MIT | osx, w64, w86, l64 |
| linux-raw-sys | 0.12.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | l64 |
| linux-raw-sys | 0.4.15 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | l64 |
| litemap | 0.8.2 | Unicode-3.0 | osx, w64, w86, l64 |
| lock_api | 0.4.14 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| log | 0.4.33 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| lru-slab | 0.1.2 | MIT OR Apache-2.0 OR Zlib | osx, w64, w86, l64 |
| memchr | 2.8.3 | Unlicense OR MIT | osx, w64, w86, l64 |
| mime | 0.3.17 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| miniz_oxide | 0.8.9 | MIT OR Zlib OR Apache-2.0 | osx, w64, w86, l64 |
| mio | 1.2.2 | MIT | osx, w64, w86, l64 |
| nonzero_ext | 0.3.0 | Apache-2.0 | osx, w64, w86, l64 |
| ntapi | 0.4.3 | Apache-2.0 OR MIT | w64, w86 |
| num-bigint | 0.4.8 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num-bigint-dig | 0.8.6 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| num-conv | 0.2.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num-derive | 0.4.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num-integer | 0.1.46 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num-iter | 0.1.46 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num-traits | 0.2.19 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| num_threads | 0.1.7 | MIT OR Apache-2.0 | osx, l64 |
| oauth2 | 5.0.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| objc2-core-foundation | 0.3.2 | Zlib OR Apache-2.0 OR MIT | osx |
| objc2-io-kit | 0.3.2 | Zlib OR Apache-2.0 OR MIT | osx |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| open | 5.4.0 | MIT | osx, w64, w86, l64 |
| openssl-probe | 0.1.6 | MIT/Apache-2.0 | l64 |
| openssl-probe | 0.2.1 | MIT OR Apache-2.0 | l64 |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| pbkdf2 | 0.12.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| pem-rfc7468 | 0.7.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| pkcs1 | 0.7.5 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| pkcs8 | 0.10.2 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| portable-atomic | 1.14.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| potential_utf | 0.1.5 | Unicode-3.0 | osx, w64, w86, l64 |
| powerfmt | 0.2.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| priority-queue | 2.7.0 | LGPL-3.0-or-later OR MPL-2.0 | osx, w64, w86, l64 |
| proc-macro2 | 1.0.106 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| protobuf | 3.7.2 | MIT | osx, w64, w86, l64 |
| protobuf-codegen | 3.7.2 | MIT | osx, w64, w86, l64 |
| protobuf-json-mapping | 3.7.2 | MIT | osx, w64, w86, l64 |
| protobuf-parse | 3.7.2 | MIT | osx, w64, w86, l64 |
| protobuf-support | 3.7.2 | MIT | osx, w64, w86, l64 |
| quick-xml | 0.38.4 | MIT | osx, w64, w86, l64 |
| quinn | 0.11.11 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| quinn-proto | 0.11.16 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| quinn-udp | 0.5.15 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| quote | 1.0.46 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand | 0.10.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand | 0.8.7 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand | 0.9.5 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_chacha | 0.3.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_chacha | 0.9.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_core | 0.10.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_core | 0.6.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_core | 0.9.5 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_distr | 0.5.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rand_pcg | 0.10.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| regex | 1.13.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| regex-automata | 0.4.15 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| reqwest | 0.12.28 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| ring | 0.17.14 | Apache-2.0 AND ISC | osx, w64, w86, l64 |
| rsa | 0.9.10 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| rustix | 0.38.44 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | osx, w64, w86, l64 |
| rustix | 1.1.4 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | osx, l64 |
| rustls | 0.22.4 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| rustls | 0.23.42 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| rustls-native-certs | 0.7.3 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| rustls-native-certs | 0.8.4 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| rustls-pemfile | 2.2.0 | Apache-2.0 OR ISC OR MIT | osx, w64, w86, l64 |
| rustls-pki-types | 1.15.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| rustls-webpki | 0.102.8 | ISC | osx, w64, w86, l64 |
| rustls-webpki | 0.103.13 | ISC | osx, w64, w86, l64 |
| rustversion | 1.0.23 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 | osx, w64, w86, l64 |
| schannel | 0.1.29 | MIT | w64, w86 |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| security-framework | 2.11.1 | MIT OR Apache-2.0 | osx |
| security-framework | 3.7.0 | MIT OR Apache-2.0 | osx |
| security-framework-sys | 2.17.0 | MIT OR Apache-2.0 | osx |
| serde | 1.0.228 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| serde_core | 1.0.228 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| serde_derive | 1.0.228 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| serde_json | 1.0.150 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| serde_path_to_error | 0.1.20 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| serde_urlencoded | 0.7.1 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| sha1 | 0.10.7 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| shannon | 0.2.0 | MIT | osx, w64, w86, l64 |
| shell-words | 1.1.1 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| shlex | 2.0.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| signature | 2.2.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| simd-adler32 | 0.3.9 | MIT | osx, w64, w86, l64 |
| slab | 0.4.12 | MIT | osx, w64, w86, l64 |
| smallvec | 1.15.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| socket2 | 0.6.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| spin | 0.9.9 | MIT | osx, w64, w86, l64 |
| spinning_top | 0.3.0 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| spki | 0.7.3 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| strsim | 0.11.1 | MIT | osx, w64, w86, l64 |
| subtle | 2.6.1 | BSD-3-Clause | osx, w64, w86, l64 |
| symphonia | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-bundle-flac | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-bundle-mp3 | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-codec-vorbis | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-core | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-format-ogg | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-metadata | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| symphonia-utils-xiph | 0.5.5 | MPL-2.0 | osx, w64, w86, l64 |
| syn | 2.0.118 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| syn | 3.0.2 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| sync_wrapper | 1.0.2 | Apache-2.0 | osx, w64, w86, l64 |
| synstructure | 0.13.2 | MIT | osx, w64, w86, l64 |
| sysinfo | 0.36.1 | MIT | osx, w64, w86, l64 |
| system-configuration | 0.7.0 | MIT OR Apache-2.0 | osx |
| system-configuration-sys | 0.6.0 | MIT OR Apache-2.0 | osx |
| tempfile | 3.27.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| thiserror | 1.0.69 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| thiserror | 2.0.18 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| thiserror-impl | 1.0.69 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| thiserror-impl | 2.0.18 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| time | 0.3.53 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| time-core | 0.1.9 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| time-macros | 0.2.31 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| tinystr | 0.8.3 | Unicode-3.0 | osx, w64, w86, l64 |
| tinyvec | 1.12.0 | Zlib OR Apache-2.0 OR MIT | osx, w64, w86, l64 |
| tinyvec_macros | 0.1.1 | MIT OR Apache-2.0 OR Zlib | osx, w64, w86, l64 |
| tokio | 1.52.3 | MIT | osx, w64, w86, l64 |
| tokio-macros | 2.7.1 | MIT | osx, w64, w86, l64 |
| tokio-rustls | 0.25.0 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| tokio-rustls | 0.26.4 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| tokio-stream | 0.1.18 | MIT | osx, w64, w86, l64 |
| tokio-tungstenite | 0.28.0 | MIT | osx, w64, w86, l64 |
| tokio-util | 0.7.18 | MIT | osx, w64, w86, l64 |
| tower | 0.5.3 | MIT | osx, w64, w86, l64 |
| tower-http | 0.6.11 | MIT | osx, w64, w86, l64 |
| tower-layer | 0.3.3 | MIT | osx, w64, w86, l64 |
| tower-service | 0.3.3 | MIT | osx, w64, w86, l64 |
| tracing | 0.1.44 | MIT | osx, w64, w86, l64 |
| tracing-core | 0.1.36 | MIT | osx, w64, w86, l64 |
| try-lock | 0.2.5 | MIT | osx, w64, w86, l64 |
| tungstenite | 0.28.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| typenum | 1.20.1 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| unicode-ident | 1.0.24 | (MIT OR Apache-2.0) AND Unicode-3.0 | osx, w64, w86, l64 |
| untrusted | 0.9.0 | ISC | osx, w64, w86, l64 |
| url | 2.5.8 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| utf-8 | 0.7.6 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| utf8_iter | 1.0.4 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| uuid | 1.24.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| vergen | 9.0.6 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| vergen-gitcl | 1.0.8 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| vergen-lib | 0.1.6 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| version_check | 0.9.5 | MIT/Apache-2.0 | osx, w64, w86, l64 |
| want | 0.3.1 | MIT | osx, w64, w86, l64 |
| web-time | 1.1.0 | MIT OR Apache-2.0 | osx, w64, w86, l64 |
| webpki | 0.22.4 | (see crate) | osx, w64, w86, l64 |
| webpki-roots | 1.0.8 | CDLA-Permissive-2.0 | osx, w64, w86, l64 |
| which | 4.4.2 | MIT | osx, w64, w86, l64 |
| winapi | 0.3.9 | MIT/Apache-2.0 | w64, w86 |
| windows | 0.61.3 | MIT OR Apache-2.0 | w64, w86 |
| windows-collections | 0.2.0 | MIT OR Apache-2.0 | w64, w86 |
| windows-core | 0.61.2 | MIT OR Apache-2.0 | w64, w86 |
| windows-future | 0.2.1 | MIT OR Apache-2.0 | w64, w86 |
| windows-implement | 0.60.2 | MIT OR Apache-2.0 | w64, w86 |
| windows-interface | 0.59.3 | MIT OR Apache-2.0 | w64, w86 |
| windows-link | 0.1.3 | MIT OR Apache-2.0 | w64, w86 |
| windows-link | 0.2.1 | MIT OR Apache-2.0 | w64, w86 |
| windows-numerics | 0.2.0 | MIT OR Apache-2.0 | w64, w86 |
| windows-registry | 0.6.1 | MIT OR Apache-2.0 | w64, w86 |
| windows-result | 0.3.4 | MIT OR Apache-2.0 | w64, w86 |
| windows-result | 0.4.1 | MIT OR Apache-2.0 | w64, w86 |
| windows-strings | 0.4.2 | MIT OR Apache-2.0 | w64, w86 |
| windows-strings | 0.5.1 | MIT OR Apache-2.0 | w64, w86 |
| windows-sys | 0.59.0 | MIT OR Apache-2.0 | w64, w86 |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 | w64, w86 |
| windows-targets | 0.52.6 | MIT OR Apache-2.0 | w64, w86 |
| windows-threading | 0.1.0 | MIT OR Apache-2.0 | w64, w86 |
| windows_i686_msvc | 0.52.6 | MIT OR Apache-2.0 | w86 |
| windows_x86_64_msvc | 0.52.6 | MIT OR Apache-2.0 | w64 |
| writeable | 0.6.3 | Unicode-3.0 | osx, w64, w86, l64 |
| yoke | 0.8.3 | Unicode-3.0 | osx, w64, w86, l64 |
| yoke-derive | 0.8.2 | Unicode-3.0 | osx, w64, w86, l64 |
| zerocopy | 0.8.54 | BSD-2-Clause OR Apache-2.0 OR MIT | osx, w64, w86, l64 |
| zerocopy-derive | 0.8.54 | BSD-2-Clause OR Apache-2.0 OR MIT | osx, w64, w86, l64 |
| zerofrom | 0.1.8 | Unicode-3.0 | osx, w64, w86, l64 |
| zerofrom-derive | 0.1.7 | Unicode-3.0 | osx, w64, w86, l64 |
| zeroize | 1.9.0 | Apache-2.0 OR MIT | osx, w64, w86, l64 |
| zerotrie | 0.2.4 | Unicode-3.0 | osx, w64, w86, l64 |
| zerovec | 0.11.6 | Unicode-3.0 | osx, w64, w86, l64 |
| zerovec-derive | 0.11.3 | Unicode-3.0 | osx, w64, w86, l64 |
| zmij | 1.0.23 | MIT | osx, w64, w86, l64 |


### PRISM — Mozilla Public License 2.0

- **File:** `bin/windows-x64/prism.dll`, the unmodified release binary of PRISM v0.18.2 by Ethin Probst (`dynamic/release/bin/prism.dll` from `prism-windows-x64.zip` of <https://github.com/ethindp/prism/releases/tag/v0.18.2>, SHA-256 `cb9712e11af9ebe96457dbf8f5daad4a6c359ae1f59cdf2663282b3a9cc9759c`). Loaded at run time by `src/platforms/windows/eapi/prism.rb` for the voice "Screen reader" (JAWS, NVDA, Narrator, System Access, ZDSR and others). Only Windows x64 has a build; on x86 and ARM64 the voice is not offered.
- **Licence:** MPL-2.0. The source code of this exact version is available at <https://github.com/ethindp/prism/tree/v0.18.2>; Klangten does not modify it. PRISM's NOTICE and the licence texts of PRISM and of the code it contains are stored in `docs/third-party/prism/` and must accompany binary releases: simdutf (Apache-2.0), the NVDA controller client RPC definitions (originally LGPL-2.1, relicensed to PRISM under MPL-2.0 by permission; the LGPL text is kept for attribution), moderncom (MIT), dr_wav (public domain / MIT-0), concurrentqueue (simplified BSD), {fmt} (MIT), Highway (Apache-2.0 or BSD-3-Clause), Djinni (Apache-2.0, Android only) and NVGT code (zlib-style licence).
- **GPL compatibility:** MPL-2.0 permits combining with GPL-3.0 software (MPL-2.0 section 3.3); the DLL stays a separate file under its own licence.
