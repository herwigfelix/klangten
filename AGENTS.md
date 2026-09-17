# AGENTS.md

Klangten is a GPLv3 fork of [Elten 3](https://github.com/dawidpieper/elten3) (Dawid Pieper) that connects to a Klango server instead of EltenLink. Development happens on `main`; `upstream-main` keeps the untouched upstream state this fork started from.

Read [`CLAUDE.md`](CLAUDE.md) first — it contains the build and run commands, the architecture notes that span several files, the Klangten-specific conventions and the traps that already cost time. `readme.md` describes the fork for users, `NOTICE.md` and `THIRD-PARTY-NOTICES.md` carry the licence statements, `docs/` holds the upstream and Klangten documentation.

Two boundaries matter in every change:

- **This repository is public and GPLv3.** Material with unclear rights (original Klango code, sounds or themes) and any server-side secrets must never end up here.
- **The server is a separate, private repository.** It implements the HTTP/JSON interface this client speaks. Elten code, comments, documentation or translations must never be copied into it.
