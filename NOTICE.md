# Klangten – notice

Klangten is a modified version of **Elten 3**, the desktop client originally developed by Dawid Pieper for the EltenLink network. Klangten talks to a Klango server (default `https://ten.klango.online`) instead of EltenLink.

Klangten is **not an official product** of Dawid Pieper, the Prowadnica Foundation or EltenLink, and it is not endorsed, supported or reviewed by them. Please do not send questions about Klangten to the Elten or EltenLink maintainers.

## Licence

Klangten, like Elten, is free software distributed under the **GNU General Public License, version 3** (GPL-3.0-only, no "or later" clause). The full licence text is in [`license`](license); it is unchanged.

- Elten: Copyright (C) 2014-2026 Dawid Pieper and the Elten contributors.
- Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).

Upstream source code: <https://github.com/dawidpieper/elten3>.

## Original copyright holders

Elten 3 is the work of Dawid Pieper and the people who contributed to it. According to the Git history (`git shortlog -sn`) of the imported upstream sources, contributions came from:

| Contributor | Commits |
| --- | ---: |
| Dawid Pieper | 424 |
| Night Purrer | 36 |
| budyn1211 | 22 |
| Karl Eick | 11 |
| Arkadiusz (Arkadiusz Koziol) | 9 |
| papierek1997 | 9 |
| Danil | 5 |
| Ar-Anaviel | 4 |
| Julita | 4 |
| fla-rion | 2 |
| Mikołaj Hołysz | 1 |
| dangero2000 | 1 |
| Żywek | 1 |

Translations were contributed by the translators named in the headers of `locale/*/LC_MESSAGES/elten.po` (among them Karl Eick, Luis Carlos González Morales, Julita Bartosiak, Zvonimir Stanecic, Garrett Brown, Florian Ionașcu, Danil Kostenkov, Burak Yüksek and Dawid Pieper). All of their rights remain unaffected.

## Modifications (GPL-3.0 section 5a)

Klangten modifies Elten as follows. Every changed source file carries a "Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten" line in its header; new files carry a Klangten header. The Git history of the `klangten` branch records the details.

- **Server and configuration:** a central configuration module (`src/eltenlink/klangten_config.rb`) with the Klango API URL (overridable through `KLANGTEN_API_URL`), product identity and feature switches. All EltenLink host names were removed from the program code.
- **Transport:** plain JSON over TLS with certificate verification for every HTTPS connection. Elten's payload encryption, server key verification, realtime HTTP/2 stream and launcher stamp are not used. EltenLink's public keys and program signing root were removed.
- **Side-by-side installation:** own data directory (`sixdotsIT/klangten`), temp directory, log and configuration file names, Windows window class, autostart value, NVDA add-on identity, installer AppId and directories, macOS bundle identifier and Linux install path.
- **Branding:** the user interface shows "Klangten" for "Elten" and "Klango" for "EltenLink" through a display-time substitution in the translation lookup (`src/eapi/dictionary.rb`), plus changed window titles, version screen and user agent.
- **Start-up flow:** fork notice at the licence agreement and in the welcome wizard; EltenLink-only steps (launcher stamp, SMS two-factor authentication, premium and donation pages, EltenLink links) removed or disabled. The built-in updater takes releases from the Klango server or, in the rolling channel, from the fork's public GitHub releases (installer names `KlangtenSetup.exe`, `Klangten.dmg`, `klangten-linux.run`, architecture sent with update requests, download locations restricted to the configured API or to GitHub; on macOS the app replaces itself from the disk image) and can be disabled with `KLANGTEN_UPDATES=0`.
- **Conferences and calls:** Elten's own VoIP engine (`conferencecore`, `voip`), conference resources, the program relay protocol and the REST call endpoints were replaced by TeamConference, the conference system of Klango (MIT, see `THIRD-PARTY-NOTICES.md`): `src/eapi/teamconference.rb`, `src/eapi/conference.rb`, `src/scenes/conference.rb`, `src/ui/calls.rb`. Positional audio, cards, dice, whisper, recording, VST effects and shoutcast streaming are not available; the call history is kept locally.
- **Removed sections:** premium packages, payments, auctions, sponsors, calendar and tasks were removed; every former premium feature (formatting, translation and spell checking, audio options, forum and message conveniences, conference extras) is available to everyone.

## Former Elten program included under GPLv3

Klangten includes one program that was previously distributed for Elten through the EltenLink program repository. According to the project owner it is a former Elten component and is licensed under the GNU General Public License, version 3, Copyright (C) Dawid Pieper. It is built into Klangten (not installed from a program store): its unpacked sources are in `src/programs/`, and it is loaded as a trusted built-in program by `src/eapi/program_builtins.rb`. Its program UUID is unchanged; its data lives in Klangten's own data directory (`apps/data/builtin-<name>`).

| Program | Original program UUID | Author as stated in the package | Location in Klangten | Klangten changes |
| --- | --- | --- | --- | --- |
| MCP | `bf4dbbd4-cadc-4ab2-8738-7340677de1e2` | Dawid Pieper (GPLv3 headers in the code) | `src/programs/mcp/` | rebranded "Klangten MCP" (server name `klangten`, tools `klangten_*`, resources `klangten://`); default port 37383 instead of 37373 and client configuration entries named `klangten`, so it can run next to an Elten MCP without touching its `elten` entries; the organizer permission became a notes permission; calendar, task, feed, sponsor, premium and updater parts were removed together with those Klangten features; user-facing texts name Klangten and the Klango server |

Changed files of MCP keep their original headers plus a Klangten modification line. The "Elten media catalog" program is not used; Klangten's media catalog (`src/scenes/mediacatalog.rb`, `src/eltenlink/media.rb`) is new code using the Klango catalog API.

## YouTube, file manager, playlist and encoders: Klangten's own implementations

Earlier Klangten versions shipped three further programs from the Elten program catalogue (YouTube, FileManager and FFMPEGEncoders). Their packages carried no licence, so they were removed. YouTube, the file manager, the playlist and the FFmpeg and MP3 encoding are Klangten's own implementations, written in 2026 without using the former Elten programs' code:

- YouTube: `src/eapi/youtube.rb`, `src/scenes/youtube.rb` (search, playback and downloads through yt-dlp and Deno, which are downloaded on first use; on Android through the host's NewPipeExtractor)
- file manager, playlist and document reader: `src/scenes/filemanager.rb`, `src/scenes/playlist.rb`, `src/eapi/playlist.rb`, `src/eapi/document_text.rb`
- encoders: `src/eapi/audio/encoders/mp3.rb` (MP3 through BASSenc_MP3 on every platform), `src/eapi/audio/encoders/ffmpeg.rb` (AAC, M4A, FLAC, WMA and video containers through an external FFmpeg)

The UUIDs of the removed programs stay blocked (`Programs::BuiltIns::REPLACED_UUIDS`), so an old installed copy is never loaded next to the new features.

## Trademarks and names

"Elten" and "EltenLink" are names of Dawid Pieper's project and of the network operated by the Prowadnica Foundation. In Klangten they are used **only descriptively**, to state where the software comes from ("based on Elten", "modified version of Elten"). No Elten or EltenLink logos are used as a mark of Klangten. "Klango" names the server Klangten connects to. All other names belong to their respective owners.

## Third-party components

Libraries, runtimes and data shipped with or used by Klangten are listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

## No warranty

Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
