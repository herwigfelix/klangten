# Klangten start options: another Klango server, another data directory

Klangten can run against a Klango server other than klango.online and keep all
its files somewhere else, with the same start options Klango 4 uses. The code
lives in `src/eltenlink/klangten_config.rb` (server and API address) and
`src/eltenlink/klangten_startup.rb` (`Klangten::Startup`, `Klangten::ServerTrust`,
`Klangten::ServerLock`); `elten.rb` applies the options before anything else is
loaded. Tests: `ruby test/klangten_startup_test.rb`.

## The options

| Option | Environment variable | Meaning |
| --- | --- | --- |
| `--overwrite-config-path DIR` | `KLANGTEN_CONFIG_DIR` | replaces the data directory `…/sixdotsIT/klangten` - `klangten.ini`, `local.json`, the log, caches, sound themes, programs, FFmpeg and YouTube helpers. Wins over `/datadir` and portable mode. |
| `--overwrite-recordings-path DIR` | `KLANGTEN_RECORDINGS_DIR` | where recordings, downloads and documents go: `Dirs.documents`, `Dirs.music` and `Dirs.downloads` all point there (file dialogs, save locations, playlists, YouTube downloads). |
| `--srv-host-base-url URL` | `KLANGO_SRV_HOST_BASE_URL` | base address of another Klango server, e.g. `https://example.org`. |

Spellings: `--name value`, `--name=value` and `name=value` (the Klango variable
form); names are case-insensitive, a value may be quoted. Unknown arguments are
left alone. An option replaces the same value in the environment; without the
option, a value already in the environment is used.

Relative paths are relative to the program: the folder of the launcher
executable (`elten.exe`, `/opt/klangten/elten`), on macOS the folder that holds
`Klangten.app`, and in a source run the source tree. Both directories are made
absolute and created at startup.

`KLANGTEN_API_URL` stays the developer switch: it wins over everything above,
is never confirmed and also receives the update and error report requests (so a
local release test keeps working).

## Keeping the options

The options act through the environment, so every process Klangten starts
inherits them. In addition:

- **Restart** (developer mode on and off) reuses the original command line.
- **Autostart** (Windows registry `Run` entry) gets the options appended.
- **Updater**: on macOS the updated app is started with `open -a … --args <options>`,
  on Linux `/opt/klangten/elten <options>`; on Windows the installer (started by
  Klangten) starts Klangten again and both inherit the environment.

## Which address is used for what

The Klangten API of a server is its `ten.` host:

| `--srv-host-base-url` | Klangten API |
| --- | --- |
| `https://example.org`, `example.org` | `https://ten.example.org` |
| `ten.example.org` | unchanged |
| `www.`, `web.` or `chat.example.org` | `https://ten.example.org` |
| `http://127.0.0.1:5100`, `http://localhost:5100`, `http://[::1]:5100`, single-label hosts | unchanged - they cannot carry a subdomain; a local development server (`python -m klango.klangten`) answers the API directly |

Without a scheme `https` is assumed; a path is dropped. An unusable value falls
back to the official server.

Server content follows the chosen server: everything under the API, audio and
attachment links (the server sends them), blog domains (`<name>.<host>`, sent by
the server), conference host and token (`GET /api/v1/conference/token`), the
fallback address of the server terms, the Telegram bot of two-factor
authentication (taken from the link the server sends) and the administrator
contact (the server's web address).

What belongs to the software always comes from the **official** server
(`Klangten::Config.software_api_base_url`, `EltenLink::Client.software`), without
the session of the chosen server: the update check (startup and the periodic
check), installer metadata and download, extras such as the sound font, error
reports and the warm-up of the audio URL loader. The rolling channel and Android
updates come from GitHub as before. The project website and source links stay
fixed.

## The warning

Before the first network request (`Scene_Loading`, after the interface language
and the voice are set up) Klangten asks once per server:

> Warning: Klangten is about to connect to %{server}. This is not the official
> Klango server. … Do you really want to connect to it?

"No" is focused and quits Klangten. "Yes" stores the server in
`trusted_servers.txt` in the **standard** data directory of this computer
account (`%APPDATA%\sixdotsIT\klangten`, `~/Library/Application Support/sixdotsIT/klangten`,
`~/.local/share/sixdotsIT/klangten`), never in a directory chosen with
`--overwrite-config-path` or in portable mode. The consent is a decision of the
person at this computer, not a property of a data folder: a prepared folder on a
USB stick or a shared drive must not bring its own "yes" and so skip the
warning. Klangten keeps no settings for all accounts of a computer (that would
need administrator rights), so this is the widest place it has. The file holds
one normalized address (`https://example.org`) per line.

## Licence lock

A Klango server outside klango.online needs a licence; without one it locks
itself and answers every Klangten request with HTTP 503 and a short plain text
(a German and an English line and a reason in brackets, `klango/license.py` in
the server repository). Klangten recognises exactly that (503, `text/plain`, not
JSON or HTML), records it in `Klangten::ServerLock` and:

- on the loading screen says "The server … cannot be used:" followed by the
  server's line for the interface language (German line for German, otherwise
  the English one) instead of "Error", then continues offline;
- at login reads the same text (error code `server.license_locked`);
- later, when a request runs into the lock, reads it once from the main loop.

Any other answer of the server ends the lock.

## Testing locally

```sh
# Klango server (private repository), Klangten API on 127.0.0.1:5100
KLANGO_DB=/tmp/k.sqlite3 .venv/bin/python -m klango.klangten --port 5100

# Klangten from source against it, with its own data and recordings folders
./run.sh -- --srv-host-base-url http://127.0.0.1:5100 \
  --overwrite-config-path /tmp/kdata --overwrite-recordings-path /tmp/krec
```

A locked server: run the server's `create_dispatcher` with the test
configuration `TESTING=True, KLANGO_LICENSE_ENFORCE=True`, an empty
`KLANGO_LICENSE_KEY`, `KLANGO_LICENSE_SIGNING_KEY` pointing to a file that does
not exist and `KLANGO_TEN_HOSTS=127.0.0.1` (so `127.0.0.1` reaches the Klangten
API). Never use the real signing key for this.
