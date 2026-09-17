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

- Files: `bin/osx/libteamconference_core.dylib` (macOS arm64) and `bin/windows-x64/teamconference_core.dll` (Windows x64), built in September 2026 from TeamConference (<https://github.com/herwigfelix/TeamConference>, directory `lib/`, crate `teamconference-core` 0.1.0, commit 75b7516). Loaded at run time by `src/eapi/teamconference.rb` for conferences and calls. Windows arm64/x86 and Linux have no build yet; there, conferences report "not available".
- Build: `cd lib && cargo build --release` (Rust stable). macOS: copy `target/release/libteamconference_core.dylib`, run `install_name_tool -id @rpath/libteamconference_core.dylib` on the copy and sign it. Windows (MSVC toolchain, CMake for libopus): `set CMAKE_POLICY_VERSION_MINIMUM=3.5` and `set RUSTFLAGS=-C target-feature=+crt-static` (no VCRUNTIME140 dependency), then `cargo build --release`; the crate needs `client/src/` of the same repository next to `lib/`. Other targets (for example `aarch64-pc-windows-msvc`, or Linux with ALSA headers) build the same way; place the result in `bin/<runtime>/` and extend `TeamConference::Library.file_name`. `KLANGTEN_TCLIB` overrides the path.
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

## Built-in former Elten programs

The programs in `src/programs/` are former Elten components (GPL-3.0, see `NOTICE.md`). They bring or load the following third-party components.

### Gems bundled by FileManager (`src/programs/filemanager/gems/`)

Only the `lib/` directories of these gems are included; their licence texts are not in the package and must be added to release packages. Licences as declared in the gem metadata on rubygems.org or in the project repository (checked September 2026):

| Gem | Version | Licence | Copyright / authors | Source |
| --- | --- | --- | --- | --- |
| pdf-reader | 2.15.1 | MIT | James Healy | <https://github.com/yob/pdf-reader> |
| afm | 1.0.0 | MIT | Jan Krutisch | <https://github.com/halfbyte/afm> |
| Ascii85 | 2.0.1 | MIT | Johannes Holzfuß | <https://github.com/DataWraith/ascii85gem> |
| hashery | 2.1.2 | BSD-2-Clause | Trans, Kirk Haines, Robert Klemme, Jan Molic, George Moschovitis, Jeena Paradies, Erik Veenstra | <https://github.com/rubyworks/hashery> |
| ruby-rc4 | 0.1.5 | MIT (licence file in the repository; no licence in the gem metadata) | Caige Nichols | <https://github.com/caiges/Ruby-RC4> |
| ttfunk | 1.8.0 | Ruby licence ("Nonstandard"), GPL-2.0-only or GPL-3.0-only, at the user's choice; used under GPL-3.0-only | Alexander Mankuta, Gregory Brown, Brad Ediger, Daniel Nelson, Jonathan Greenberg, James Healy, Cameron Dutro | <https://github.com/prawnpdf/ttfunk> |
| docx | 0.13.0 | MIT | Christopher Hunt, Marcus Ortiz, Higgins Dragon, Toms Mikoss, Sebastian Wittenkamp | <https://github.com/ruby-docx/docx> |
| gepub | 2.0.1 | BSD-3-Clause | KOJIMA Satoshi | <https://github.com/skoji/gepub> |
| ruby-rtf | 0.0.5 | MIT, Copyright (c) 2011 dan sinclair (licence file in the repository; no licence in the gem metadata) | dan sinclair | <https://github.com/dj2/ruby-rtf> |

FileManager also uses gems Klangten already ships (rubyzip, Nokogiri; see above). pdf-reader, afm, Ascii85, hashery, ruby-rc4 and ttfunk are dependencies of pdf-reader.

### FFmpeg (FFMPEGEncoders) — not shipped

- Klangten does **not** ship an FFmpeg binary (the original package contained `ffmpeg.exe`).
- **Windows:** on first use of an FFmpeg encoder, Klangten asks and then downloads FFmpeg 9.0.1 "essentials" by Gyan Doshi (a build linked from <https://ffmpeg.org/download.html>) from <https://github.com/GyanD/codexffmpeg/releases/download/9.0.1/ffmpeg-9.0.1-essentials_build.zip>, checks the SHA-256 checksum `fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9` and extracts `ffmpeg.exe` and the build's `LICENSE` into the program's data directory (`apps/data/builtin-ffmpeg/ffmpeg/`). The build is configured with `--enable-gpl --enable-version3`, so this FFmpeg is licensed under the **GNU General Public License, version 3**; it includes further libraries (for example LAME, libx264, libvpx) under GPL/LGPL-compatible licences listed by the build. FFmpeg runs as a separate process. Source code: <https://ffmpeg.org/download.html>, build scripts and component list: <https://www.gyan.dev/ffmpeg/builds/>. No 32-bit Windows build is offered.
- **macOS and Linux:** an FFmpeg installed by the user (for example Homebrew, apt) is used; its licence depends on that installation.

### yt-dlp and Deno (YouTube) — downloaded at run time

- **yt-dlp** (<https://github.com/yt-dlp/yt-dlp>): the YouTube program downloads the latest official stand-alone yt-dlp executable for the platform on first use and checks it against the release's `SHA2-256SUMS`. yt-dlp is released under **The Unlicense** (public domain dedication). The stand-alone executables are built with PyInstaller and contain the Python runtime (PSF licence) and further bundled libraries under their own licences (see yt-dlp's `THIRD_PARTY_LICENSES.txt`).
- **Deno** (<https://github.com/denoland/deno>), used by yt-dlp as JavaScript runtime: downloaded from the official GitHub releases on first use; **MIT** licence, with bundled components (V8 BSD-3-Clause and others) under their own licences.
- Both are stored in the program's data directory (`apps/data/builtin-youtube/`) and are not part of Klangten's distribution. "YouTube" is a trademark of Google LLC and is used only descriptively.
