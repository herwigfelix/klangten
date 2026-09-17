# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  # A compact routing map, not a substitute for source inspection. Its purpose
  # is to tell an agent which capabilities exist and where details live.
  module APIOverview
    def self.text
      <<~'TEXT'
        Klangten application API: quick scope map
        ======================================

        Klangten is a voice-driven, self-voicing, keyboard-driven, audio-first
        environment with no graphical interface. Controls own speech, Braille,
        focus, sound markers and input semantics; they are spoken interaction
        objects, not graphical widgets or accessibility wrappers over a visual
        UI. Read the bundled programming guide and this map for orientation,
        then read the current source and a current call site. Source is the
        authority. Do not assume that a repository docs/ directory exists in an
        installed client or launcher source catalog. When embedded sources are
        unavailable and browsing is permitted, consult the matching revision of
        the upstream Elten sources at https://github.com/dawidpieper/elten3
        (Klangten modifies them); its docs are useful orientation,
        but they do not replace checking the implementation. This map names
        surfaces and source areas without pretending to be a complete reference.

        Application runtime and lifecycle
        ---------------------------------
        src/eapi/program.rb contains manifest/package parsing, per-UUID runtime
        namespaces, application-aware require, asset/data/cache paths, atomic
        JSON/text/binary helpers, required assets, managed resources, sound
        pools, Program class/instance delegates, program_main lifecycle, events,
        quick actions, signals, server applications, tables, resources and
        Leaderboard. src/eapi/extensions.rb and program_settings.rb cover
        background extensions and application settings. Source programs require
        developer mode; packaged applications are verified and isolated by
        namespace, not sandboxed.

        Controls and short interactions
        -------------------------------
        src/ui/form.rb and src/ui/controls/ provide Form/FormBase/FormTimer and:

        - EditBox, ListBox, TableBox, GridBox and ChoiceListBox;
        - Button, CheckBox, Static and FormField;
        - Menu, Tree, FilesTree, Map, CalendarGrid and DateButton;
        - Player and OpusRecordButton.

        Look for wait, wait_for_item and wait_for_choice before writing a loop.
        List/table controls support item states, selection, empty labels and
        per-item audio; GridBox supports action bindings and bulk cell updates.
        bind_context and Menu attach secondary actions. add_tip makes a justified
        non-standard gesture discoverable.

        src/ui/dialogs.rb and form.rb expose alert, confirm, selector,
        select_action, input_text/input_user, display_text, display_list,
        display_table, prompt and dialog lifecycle helpers. Prefer these for
        small conventional flows.

        Runners, timers and work
        ------------------------
        src/eapi/runner.rb provides Runner#run, stop, after, every, schedule,
        next_tick, on_tick, key lifecycle callbacks, named press/hold actions,
        phased action handlers, guards, cooldowns, timed flags, monotonic
        stopwatches, hold gestures, responsive Runner.wait and managed-resource
        cleanup.

        src/eapi/tasks.rb provides finite worker execution with cancellation
        tokens, timeout, delayed progress UI, progress updates and progress.ui
        callbacks on the interaction owner. FormTimer belongs to a form.
        Extension#tick is a short main-pump callback, not a worker or modal UI.
        Do not create feature-owned loop_update loops unless maintaining a
        bounded legacy flow which cannot yet use a current owner.

        Speech, input and navigation
        ----------------------------
        src/eapi/speech.rb, speechoutput.rb, keyboard.rb and src/ui/input.rb
        contain speech/indexing, keyboard actions and platform-normalised input.
        src/ui/loop.rb owns the global application frame. $scene replaces a
        top-level destination; insert_scene temporarily inserts a scene and can
        restore the interrupted one. Both navigation mechanisms remain current.

        Choosing application communication
        ----------------------------------
        Program#signal/#signaled is recommended for quick, simple informing:
        a small transient hint to another user of the same application, such as
        asking an active peer to refresh authoritative state. Current dispatch
        in src/ui/loop.rb reaches only the active matching Program scene. It is
        not durable storage, an offline inbox or a reliable queue. Keep the
        callback short and validate sender, packet type/version and bounds. See
        src/eapi/program.rb, src/eapi/notifications.rb, src/eltenlink/apps.rb
        and the dispatch call site in src/ui/loop.rb.

        EltenAPI::LiveSessions is an advanced API for message exchange, chat
        contexts and games that do not require immediate UDP communication.
        It provides ordered JSON messages over Klangten's shared transport.
        Handlers must tolerate at-least-once delivery. Program#live_sessions
        supplies the owned endpoint. In src/eapi/live_sessions.rb, look for:

        - Endpoint#discover_sessions, find_by_code and DiscoveredSession for
          public/private sessions, created/invited sessions and joining by code;
        - Session#send_private for messages addressed to one user in a session;
          message privacy is independent of session visibility;
        - Session#stack_push, stack_read and on_stack_message for session
          message history and replay; stack_trim/stack_clear manage history;
        - Session#send_random and stack_push_random for server-generated
          results delivered as messages or history entries; MessageMetadata
          identifies their origin;
        - Session#create_pool, Pool and PoolDraw for shared value pools,
          public/private draws and later reveal, such as dealing cards.

        Endpoint#create/connect defaults to stack_entries: 0, pool_count: 0
        and private_messages: false; enable the required features explicitly.
        Inspect that source for configuration and limits.

        Use callback option with_metadata: true to distinguish message kinds.
        Message#regular? and MessageMetadata#regular? identify ordinary public
        participant messages. Inspect MessageMetadata#private?, visibility,
        recipient_user, server_random? and server_pool? for private messages,
        server-generated random results and pool events.

        The API handles invitation replacement, recovery, retries, cancellation
        of supported operations, diagnostics and deliberate session departure
        and closing. Inspect this source and its src/eltenlink/apps.rb adapters
        for lifecycle, history retention, gaps, limits and method contracts.

        EltenAPI::Communication is an advanced low-level API for control over
        realtime binary transmission, including reliable/unreliable delivery
        and UDP. Program#communication supplies an owned endpoint using
        dedicated TCP/TLS and UDP relay sockets on a separate port. It covers
        delivery state, encryption, public/private sessions, state recovery
        and error reporting. Read src/eapi/communication.rb and current call
        sites for transport, timing, delivery and lifecycle contracts.

        Program.on(event) is a different, local host-event observer. The current
        source emits a small fixed vocabulary around speech and player actions;
        it is not a general event bus. Search Programs.emit_event call sites and
        register only an event actually emitted by the installed revision.

        Sound: normal and advanced
        --------------------------
        src/eapi/audio/sound.rb exposes Sound from files, memory/Internet streams
        and PCM push streams; play/pause/stop/wait/close; position, length,
        chapters and metadata; connection/download state; volume, pan,
        frequency, tempo and pitch; attributes and timed slides; fades and
        events; effect chains, latency and effect playback timelines; spatial
        position and spatial_position_slide. Since Elten API 3.0.3, Sound and
        OutputAudioDevice also expose output-device discovery and routing of
        individual sounds; inspect this source for device selection and changes.

        Program helpers create/play packaged sound assets and manage a SoundPool.
        The Audio API also provides a higher-level source/processing model for
        managing sound data, including joining, resampling, cutting/segmenting,
        channel/sample conversion, effects and export. This map intentionally
        omits method-level instructions; inspect src/eapi/audio/source.rb,
        processing.rb, format.rb and renderer.rb before building a pipeline.
        src/eapi/audio/fx/audio3d.rb supplies HRTF spatial processing.
        fx/effects.rb supplies native echo, reverb, chorus, flanger, phaser,
        distortion, compressor, auto-wah, peak EQ, biquad filter, dynamic
        amplification and rotation. recorder.rb, encoders/, opus.rb, speexdsp.rb,
        audioeditor.rb and mediaextractors.rb cover recording, PCM processing,
        codecs/containers, editing and media discovery. steamaudio.rb and bass.rb
        are lower-level implementation surfaces; use higher-level Sound/Program
        helpers where possible.

        Local state, assets and native material
        ---------------------------------------
        asset_path is packaged read-only content; data_path is persistent;
        cache_path is disposable. Runtime helpers read/write/update JSON and
        text/binary data atomically inside assigned roots. Audio/, locale/,
        required_assets and exact-platform native entries are indexed during
        packaging. manage/release and runtime registries make lifetime explicit.

        EltenLink and server application data
        -------------------------------------
        src/eltenlink/ contains typed domain modules for accounts, users,
        contacts, forums, messages, blogs, notifications, notes, polls, calls,
        sound themes and other services of the Klango server. Pass one EltenLink client into domain
        operations; do not
        construct private URLs/envelopes in feature code.

        src/eltenlink/apps.rb supplies:

        - Apps.register/update/info/schema/delete;
        - AppTable select/insert/upsert/update/delete with semantic hashes;
          Elten API 3.0.3 also provides extended queries (projection, grouping,
          aggregates and joins), bulk operations and row sharing with users or
          contacts. Inspect AppTable in this source for supported options;
        - AppResources list/info/upload/delete/download_url;
        - application signals and remote package metadata.

        Current EltenLink message models also expose message forwarding origin,
        group discovery and a forwarding operation. Notification listing can
        include notifications declared by installed server applications; use
        Programs.notification_app_uuids and Programs.map_app_notification so
        application payloads stay behind the program's presentation mapping.
        Locate the exact contracts in src/eltenlink/messages.rb and
        notifications.rb.

        Prefer Program.server_app, server_table, server_resources,
        update_server_schema! and Leaderboard. The agent may generate and edit
        declarations locally. A server_app declaration can also opt into
        application notifications; inspect its current definition and Program
        notification hooks rather than inventing payload or action formats.
        Initial registration and schema update are
        account-binding server writes: read programming, inspect the exact
        signed-in account and obtain the mandatory user confirmation before
        using program_server_schema_apply.

        Settings, integration and background services
        ----------------------------------------------
        Program extensions use a named start/tick/settings/stop lifecycle.
        Extension ticks execute on the host pump and must stay short; finite or
        blocking work belongs in Tasks.run. Their settings builder supports
        boolean, integer, text, choice, multi-choice and action definitions with
        bound getters/setters. Program#register_quickaction exposes a translated,
        stable command in Klangten's user-configurable quick-action system instead
        of inventing a hidden shortcut. Unload unregisters runtime-owned
        extensions and quick actions.

        Packaged locale/*.mo catalogs participate in program translation
        context. Use _, p_, n_ and np_ as appropriate for every spoken label,
        announcement and setting; inspect src/eapi/dictionary.rb for context and
        plural semantics. Do not hard-code user-facing speech merely because no
        graphical interface exists.

        Program manifests declare main_language and supported_languages, and
        may supply localized names/descriptions in the manifest or locale
        metadata files. Package preparation normalizes this metadata and emits
        useful warnings. See src/eapi/program_package_metadata.rb and current
        package-builder call sites; do not infer language support only from the
        current UI language.

        Other shared areas
        ------------------
        src/eapi/resources.rb, html.rb, http.rb, external.rb, dictionary.rb,
        documents.rb, invisibleinterface.rb, notifications.rb, quickactions.rb,
        conference*.rb and common/ cover packaged resources, readable HTML,
        generic downloads, external processes/URLs, language services,
        notifications, voice/conference facilities and shared helpers.
        Platform-specific implementations are under src/platforms/. Do not
        depend on a low-level or platform surface just because it is globally
        visible; find the stable higher-level entry point first.

        Tasks cancellation tokens can register on_cancel callbacks and are
        accepted by current HTTP/download and supported child-process paths.
        Pass the same token through the whole finite operation.
        Resources::Registry releases managed objects in reverse order and
        supports custom disposer blocks; prefer Program or Runner manage over an
        ad-hoc ensure forest.

        Bundled Ruby dependencies
        -------------------------
        Elten 3.0 directly supplies base62 1.0.x, base64 0.3.x,
        bigdecimal 3.3.x, fiddle 1.1.x, http-2 1.1.x, net-http 0.9.x,
        nokogiri 1.19.x, ostruct 0.6.x, ruby-xz 1.0.x, rubyzip 3.2.x,
        sqlite3 2.9.x and zstd-ruby 2.0.x. win32ole 1.9.x is Windows-only.
        Do not declare host gems in manifest.gems. Additional declared gems are
        handled only by the full setup builder and may narrow platform support.

        Efficient source route
        ----------------------
        Call klangten_sources_info, request source/read only when needed, then:

        - klangten_sources_list(prefix="src/ui/controls") for controls;
        - klangten_sources_list(prefix="src/eapi/audio") for sound playback and
          Audio source/processing pipelines;
        - klangten_sources_list(query="class Runner") for runners/timers;
        - klangten_sources_list(query="def signaled") and then src/ui/loop.rb plus
          src/eapi/notifications.rb for application-signal send/receive;
        - klangten_sources_list(prefix="src/eapi/live_sessions.rb") for advanced
          message exchange, chat and games without immediate UDP communication;
        - klangten_sources_list(prefix="src/eapi/communication.rb") for the
          advanced low-level TCP/TLS and UDP communication API;
        - klangten_sources_list(query="Programs.emit_event") for the exact local
          host-event vocabulary;
        - klangten_sources_list(prefix="src/eapi/extensions.rb") for background
          lifecycle/settings and src/eapi/quickactions.rb for user commands;
        - klangten_sources_list(prefix="src/eltenlink") for server domains;
        - klangten_source_read with bounded line ranges for definitions and call
          sites.

        Read implementation before choosing parameters, especially for audio
        buffering/timing, concurrency, native code, server schemas, signing and
        package installation.
      TEXT
    end
  end
end
