# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  # Model-facing guidance for producing current Klangten applications. It is kept
  # separate from MCP's operating contract so an agent can load it as one
  # focused resource before designing or changing a program.
  module ProgrammingGuide
    def self.text
      <<~'TEXT'
        Writing an Klangten application
        ============================

        Purpose and mandatory preparation
        ---------------------------------
        Treat this as the default design contract for new Klangten applications.
        Elten 3.0 application APIs are experimental and actively evolving. Do
        not invent an API from memory and do not treat an old client scene as a
        template.

        Before writing code:

        1. Read the complete program: its full manifest and every source file,
           not only the files named in the request. For a new program, inspect
           all of its starter files.
        2. Read this bundled guide and api_overview for orientation. docs_search
           may add useful context, but never assume that a filesystem docs/
           directory is installed or exposed to the agent.
        3. Call klangten_sources_info. When launcher sources are available, request
           source/read and use klangten_sources_list plus klangten_source_read to read
           the current implementation and at least one current call site for
           every non-trivial API you plan to use. Useful starting paths are
           src/eapi/program.rb, src/eapi/runner.rb, src/eapi/tasks.rb,
           src/ui/form.rb, src/ui/controls/, src/ui/dialogs.rb,
           src/eapi/audio/ and src/eltenlink/apps.rb. This source inspection is
           more important than prose documentation.
        4. If launcher sources are unavailable and browsing is permitted, use
           the upstream Elten sources at https://github.com/dawidpieper/elten3
           and select the revision closest to the installed client; Klangten
           modifies them, so expect differences. Repository docs can help orientation, but
           read definitions and call sites in src/ before committing to an API.
           If neither source route is available, state the limitation and avoid
           inventing non-trivial calls.
        5. Inspect a current, small application with the same interaction shape
           when one is installed. Skeet is the reference for a real-time,
           voice-driven program: it separates rules, session, sound, server
           scores and UI; declares tables and required assets; uses
           program_main, Runner, managed audio and the Leaderboard wrapper.
        6. Decide ownership before implementation: Form#wait for a contained
           form, Tasks.run for finite work, Runner for a non-form timed
           interaction, and $scene or insert_scene only for a real top-level
           navigation boundary.

        Voice-driven design
        -------------------
        Klangten is voice-driven, self-voicing, keyboard-driven and audio-first.
        It has no graphical interface at all. Its controls and forms are spoken
        interaction objects, not graphical widgets with an accessibility layer.
        Do not describe layouts, state or navigation as visual, and never assume
        that anything is visible. Speech, Braille, focus, timing, cancellation
        and sound are the native interaction model, not a compatibility pass:

        - Put the distinguishing information first in labels and announcements.
          Repeated introductions make list navigation slow.
        - Prefer existing controls and sounds. They preserve speech, Braille,
          markers, boundaries, hotkeys, focus and user settings.
        - Give every form a clear purpose and normal Enter/Escape behaviour.
          Restore focus after nested interactions.
        - Use a concise spoken message when a sound alone cannot communicate the
          meaning reliably. Avoid narrating information already obvious from a
          familiar sound.
        - Do not expose raw server rows, UUIDs, flags or protocol vocabulary in
          ordinary UI. Translate them into decisions meaningful to the user.
        - If a justified gesture is not discoverable from an existing
          convention, attach a short translated control.add_tip describing the
          gesture and effect.
        - Test empty data, unavailable sound/network, invalid input, slow work,
          cancellation, Escape, returning focus and program finalisation.

        Current architecture; legacy boundaries
        ---------------------------------------
        CURRENT:

        - Program#program_main is the normal entry point. Returning or raising
          finalises the instance and its managed resources through Core.
        - Form#wait owns a form. ListBox#wait_for_item,
          TableBox#wait_for_item and ChoiceListBox#wait_for_choice own simple
          browsers and selectors.
        - EltenAPI::Tasks.run owns finite cancellable background work. UI stays
          on the owner thread; use progress.ui for a necessary owner-thread
          callback.
        - Runner owns games and other non-form loops with actions, timers,
          cooldowns, stopwatches and managed resources.
        - $scene and insert_scene remain supported for top-level navigation.
          They are not deprecated.
        - Program class/instance helpers own paths, JSON transactions, assets,
          sounds, resources, server declarations, leaderboards and settings.
        - Program#signal/#signaled provide transient user-to-user application
          hints; Program.on observes a separate fixed set of local host events.
        - EltenAPI::LiveSessions is an advanced API for message exchange, chat
          contexts and games that do not require immediate UDP communication.
          EltenAPI::Communication is an advanced low-level API for control over
          realtime binary transmission, including reliable/unreliable and UDP.
        - Program extensions provide a host-owned background lifecycle and typed
          settings; register_quickaction integrates user-invokable commands.

        LEGACY / COMPATIBILITY ONLY:

        - A feature-owned loop which calls loop_update and control.update is
          deprecated. loop_update itself is essential framework infrastructure;
          do not call it from a worker and do not replace it with sleep.
        - Program#main is a compatibility entry point. If maintaining it, call
          finish in ensure. New programs define program_main.
        - Large scene classes which manually poll keys for a contained form,
          duplicated selector/dialogue code, and direct writes to global menu
          collections are historical patterns, not examples for new programs.
        - Direct EltenAPI::HTTPClient calls for ordinary Klangten social features,
          private wire encodings and direct manipulation of server payloads are
          not application-level contracts. Prefer Program helpers and current
          EltenLink domain modules.
        - Do not mechanically rewrite unrelated working legacy scenes. Apply
          modern ownership to new programs and to workflows already being
          substantively redesigned.

        Program layout and manifest
        ---------------------------
        Keep __app.rb small: one Elten3AppInfo JSON block, require_relative
        statements, stable declarations and the Program subclass. Put domain
        rules, persistence, server access, audio and UI in focused files under
        lib/<program>/.

        Keep id stable for every release. It controls identity, namespace and
        persistent storage. Set main, main_language and supported_languages
        explicitly, increment version and build_id deliberately, declare the
        narrowest truthful platforms, and list only assets whose absence makes
        startup impossible. Localized names and descriptions can live in
        manifest mappings or locale metadata files; package preparation
        normalizes them and reports warnings. Klangten creates the EltenPrograms
        namespace; never define it yourself. main_class is resolved within that
        namespace.

        Use asset_path only for packaged read-only files, data_path/read_json/
        write_json/update_json for durable state, and cache_path for disposable
        material. Prefer update_json whenever a write depends on current JSON;
        it serialises the read-modify-replace transaction for that data file.
        Validate the parsed structure before changing it. Never store durable
        state in the application source directory or cache.

        Let ownership clean up resources. Program instance manage gives a
        resource one launch's lifetime; the class method gives it the loaded
        runtime's lifetime. Prefer the narrower scope. Runner#manage is suitable
        when the resource belongs exactly to one run. Override close only for
        remaining instance-specific cleanup.

        UI, work and timing
        -------------------
        Use alert, confirm, selector, select_action, input_text, display_text,
        display_list and display_table for short conventional interactions.
        Use Form with EditBox, ListBox, TableBox, GridBox, ChoiceListBox,
        Button, CheckBox, Tree, CalendarGrid, Player and the other controls for
        richer interactions. Assign accept_button and cancel_button, connect
        events with on/bind_context, and end Form#wait with form.resume.

        Tasks.run performs finite work on a worker. Check the cancellation token
        inside loops, use token.sleep for cancellable delays, pass the token to
        supported network/download/child-process APIs, report progress, and
        never mutate a form or $scene from the worker.

        Runner provides named press/hold actions, action phases and guards,
        on_key_down/on_key_released, after/every/schedule, next_tick, Cooldown,
        TimedFlag, Stopwatch, hold_gesture and deterministic cleanup. Prefer
        named actions over raw key checks scattered through on_tick. Use
        Runner.wait or Sound#wait for responsive waits instead of sleep.

        Communication choices, host events, extensions and quick actions
        ---------------------------------------------------------------
        Use signal(user, packet) for quick and simple informing: a small,
        transient packet routed to another user of the same application.
        Override signaled(sender, packet) on the Program instance to receive it.
        Current Klangten dispatches it only while that Program is the active $scene
        and the appid matches. It is therefore unsuitable as a database, offline
        mailbox, reliable queue or sole game state. Put durable or authoritative
        state in a declared server table; use a signal only to prompt a fast
        refresh or communicate ephemeral interaction.

        Treat sender and packet as untrusted input. Use a versioned Hash with
        string keys; allowlist the type; validate lengths, identifiers and
        numeric bounds; make repeated packets harmless; and keep signaled short.
        The sending helper requires a String user and accepts a top-level String,
        Array, Hash, Integer, boolean or nil. Check src/eapi/program.rb,
        src/eltenlink/apps.rb, src/eapi/notifications.rb and src/ui/loop.rb before
        relying on delivery behaviour.

        EltenAPI::LiveSessions is an advanced API for message exchange, chat
        contexts and games that do not require immediate UDP communication.
        EltenAPI::Communication is an advanced low-level API for control over
        realtime binary transmission, including reliable/unreliable delivery
        and UDP. Prefer Program#live_sessions and Program#communication for
        owned endpoints. Read api_overview for the capability map, then inspect
        src/eapi/live_sessions.rb or src/eapi/communication.rb and current call
        sites for the selected API's contracts.

        Program.on(event) is unrelated to remote signals. It observes only host
        events which current source actually passes to Programs.emit_event, such
        as selected speech/player actions. Never invent an event name; inspect
        all current emit_event call sites. Keep these observers tiny because they
        run in the host interaction path.

        Use class extension(name) for background integration that must live with
        the loaded program. Give it start, a short non-blocking tick with a
        justified interval, optional typed settings, and stop cleanup. Use
        Tasks.run for finite blocking work instead of doing it in tick. Register
        a stable, translated quick action when a feature deserves a user-visible
        command; do not create an undocumented global key hook.

        Localisation and cancellable integration
        ----------------------------------------
        Translate every spoken label, setting and announcement. Packaged
        locale/*.mo files are loaded into the program translation context; use
        _, p_, n_ or np_ according to the current dictionary implementation.
        Preserve context and plural rules rather than concatenating fragments.

        Pass a Tasks cancellation token into every supported network, download
        and child-process layer used by one operation. Use on_cancel only for
        prompt interruption/cleanup and unregister callbacks when ownership
        ends. Prefer current EltenLink domain clients for Klangten services; reserve
        low-level HTTP for genuine external services with explicit timeouts,
        validation and cancellation.

        Sound
        -----
        Declare indispensable sounds in required_assets. Prefer the Program
        helpers:

        - play_sound_from_asset for managed one-shots;
        - create_sound_from_asset plus manage for direct lifetime control;
        - create_spatial_sound_from_asset for moving 3D sound;
        - sound_pool to cap simultaneous voices.

        Sound supports status, wait, play/pause/stop/close, volume/pan/
        frequency/tempo/pitch, attribute slides, fade_in/fade_out, events,
        effects, spatial position and position slides, effect latency and
        playback timelines, Internet download state and writable PCM streams.
        The Audio source API additionally supports operations such as joining,
        resampling, segmenting/cutting, format/channel conversion, processing
        and export. Read source.rb, processing.rb, format.rb and renderer.rb
        before composing a pipeline; buffer formats and ownership remain
        explicit.
        Advanced effects include Audio3DEffect and native echo, reverb, chorus,
        flanger, phaser, distortion, compressor, auto-wah, equaliser, filters,
        dynamic amplification and rotation. Read the current sound/effect source
        before using advanced buffering or timing: latency and ownership matter.

        Server tables: identity and mandatory account check
        ---------------------------------------------------
        Declare the schema once with server_app and keep table access behind a
        small repository or Leaderboard object. Do not register or update a
        schema automatically from activate, init or program_main.

        The agent may generate a schema, edit its server_app declaration and
        refactor table access itself. These local source changes do not bind an
        account. BEFORE ANY server registration or schema update, however, the
        agent MUST call program_server_schema_inspect, quote the returned
        signed_in_account in this question, and wait for an answer:

        "Is the currently signed-in Klango account \"<signed_in_account>\" your
        own developer account, and should it permanently own this application?"

        Never infer the answer from developer mode, a username, a previous
        request, a test succeeding, or the fact that the user asked for an
        application. Registration binds the server application to the currently
        signed-in account.

        If the user explicitly confirms that exact account, the agent may call
        program_server_schema_apply with the same confirmed_account and
        account_confirmation=confirmed_own_developer_account. For initial
        registration it must then edit server_app(uuid: "...") itself with the
        returned UUID, reload the program and inspect the declaration again.
        Later table changes use action=update.

        If the answer is no or uncertain, or this is a test, secondary or wrong
        account, DO NOT call the apply tool, program_eval, ruby_eval or direct
        EltenLink registration/update. Explain that the user should sign in to
        the intended developer account, load the source program and personally
        use Klangten's developer Console (Main menu -> Console):

          program = Programs.list.find { |klass|
            klass.app_runtime && klass.app_runtime.entry_id == "program_folder"
          }
          uuid = program.register_server_app!
          puts uuid

        The user then copies that UUID into server_app(uuid: "...") in source,
        reloads the program, and for later declared-schema changes runs:

          program.update_server_schema!

        program_server_schema_prepare produces that fallback command without
        contacting the server. program_server_schema_apply is the direct wrapper
        and enforces the explicit token plus an exact match between the
        user-confirmed account and the account still signed in at execution.
        Initial registration returns a UUID which must be persisted in source
        immediately; the in-process value alone is not a release artifact.

        For ordinary rows, use server_table(name).select/insert/upsert/update/
        delete. Use semantic hashes and let EltenLink stamp requests. For a
        score table, prefer leaderboard: it supplies ordered top/submit,
        availability state, logging and bounded retry cooldowns without
        resending a mutation in the background.

        A server_app declaration can enable application notifications. The
        program maps the private notification object to a user-facing
        NotificationPresentation and owns any action handling; external code
        should not interpret its payload. Inspect the declaration and Program
        notification hooks in the current source before enabling this feature.

        Gems, builds, signing and installation
        --------------------------------------
        Elten 3.0 supplies these direct application dependencies. Require them
        normally and do not repeat them in manifest.gems:

        base62 1.0.x, base64 0.3.x, bigdecimal 3.3.x, fiddle 1.1.x,
        http-2 1.1.x, net-http 0.9.x, nokogiri 1.19.x, ostruct 0.6.x,
        ruby-xz 1.0.x, rubyzip 3.2.x, sqlite3 2.9.x and zstd-ruby 2.0.x.
        win32ole 1.9.x is Windows-only. Fiddle itself is portable; a binding to
        a platform library is not.

        Declare only additional gems in manifest.gems. The full canonical
        tools/build-eltsetup.rb bundles installed Ruby sources and available
        native builds for those gems. Narrow platforms and test every declared
        target. MCP's in-process program_build deliberately rejects declared
        gems; it builds eltenapp or eltsetup without extra gem bundling.

        program_build creates unsigned packages by default. Supplying both
        certificate_path and private_key_path signs the eltenapp payload and
        verifies its certificate, key match, signature and current Klangten trust
        chain. Never paste a key, password or PEM contents into a prompt; pass
        local paths only. Keep keys outside source and packages. A signature
        authenticates bytes, not safety and not official publisher approval.
        The build result also reports metadata_warnings from canonical manifest
        and locale preparation; review them before distributing a package.

        Use program_install only for a local .eltsetup the user actually asked
        to install. It follows Klangten's canonical staging, rollback, registry and
        activation path and loads the installed program. program_load loads an
        already installed/source entry; program_reload is only a soft reload and
        cannot undo threads or monkey patches. program_uninstall uses Klangten's
        canonical cleanup path and preserves program data/cache unless
        remove_data=true is explicitly requested. MCP cannot update, unload,
        reload or uninstall itself while serving the request.

        Verification checklist
        ----------------------
        - Re-read the final diff and manifest; no invented API or stray file.
        - Run program_syntax_check for every Ruby file.
        - Test source in developer mode: launch, normal use, errors,
          cancellation, empty/unavailable services, Escape and return focus.
        - Verify resources close after program_main and after exceptional exit.
        - Verify local data transactions and corrupt/missing defaults.
        - For server features, test an unavailable service without retrying
          mutations invisibly. Never use a test account for final registration.
        - Build the actual eltsetup, install through the actual setup path, and
          verify program state/signature. Test unload and restart behaviour.
        - Keep UUID stable and update version/build_id for a published build.
        - Do not claim untested platforms, native payloads or certificate trust.

        Template 1: contained voice-driven program
        ------------------------------------------
        __app.rb:

          =begin Elten3AppInfo
          {
            "id": "REPLACE-WITH-STABLE-UUID",
            "name": "Example",
            "version": "0.1.0",
            "build_id": 1,
            "EltenAPIVersion": "3.0.3",
            "author": "Author",
            "main_language": "en",
            "supported_languages": ["en"],
            "main": "__app.rb",
            "main_class": "ProgramExample",
            "platforms": ["all"],
            "menu": { "main": "Example" },
            "description": "A concise voice-driven Klangten application."
          }
          =end Elten3AppInfo

          require_relative "lib/example/ui"

          class ProgramExample < Program
            def program_main
              Example::UI.new(self).main
            end
          end

        lib/example/ui.rb:

          module Example
            class UI
              def initialize(program)
                @program = program
              end

              def main
                name = EditBox.new(_("Name"), :text => "")
                save = Button.new(_("Save"))
                cancel = Button.new(_("Cancel"))
                form = Form.new([name, save, cancel], :quiet => true)
                form.accept_button = save
                form.cancel_button = cancel
                save.on(:press) do
                  if name.text.strip == ""
                    alert(_("Enter a name."))
                    next
                  end
                  @program.update_json("state.json", :default => {}) do |state|
                    state["name"] = name.text
                  end
                  form.resume
                end
                cancel.on(:press) { form.resume }
                form.wait
              end
            end
          end

        Template 2: finite cancellable work
        -----------------------------------
          result = EltenAPI::Tasks.run(
            :title => _("Importing items"),
            :timeout => 60
          ) do |progress, token|
            items.each_with_index do |item, index|
              token.raise_if_cancelled!
              import(item, :cancellation_token => token)
              progress.update(index + 1, :total => items.size, :message => item.name)
            end
            :complete
          end

        Template 3: Runner, managed spatial sound and server table
        ----------------------------------------------------------
        Declaration in the Program subclass (registration is a separate,
        deliberate human-approved step):

          SERVER_TABLES = {
            "scores" => {
              "visibility" => "public",
              "columns" => {
                "points" => "integer",
                "level" => "integer"
              },
              "permissions" => %w[select insert],
              "indexes" => [["points", "level"]],
              "limits" => { "max_select_limit" => 25 }
            }
          }.freeze

          server_app(:uuid => nil, :tables => SERVER_TABLES, :protected => true)

        Focused score adapter:

          class Scores
            def initialize(program)
              @leaderboard = program.leaderboard(
                "scores",
                :order => [["points", "desc"], ["level", "desc"]],
                :log_label => "Example scores"
              )
            end

            def top
              @leaderboard.top(:limit => 25)
            end

            def submit(points, level)
              @leaderboard.submit("points" => points.to_i, "level" => level.to_i)
            end
          end

        Non-form interaction:

          sound = manage(create_spatial_sound_from_asset(
            "target",
            :position => [-1.0, 0.2, 0.5],
            :loop => true,
            :effect_buffer => :interactive
          ))
          runner = Runner.new(:frame_interval => 0.01)
          runner.action(:fire, :press => :key_space)
          runner.on_action(:fire, :cooldown => Runner::Cooldown.new(0.25)) do |current, _time|
            current.stop(:fired)
          end
          runner.on_key(:key_escape) { |current, _time| current.stop(:cancelled) }
          runner.every(0.02) { update_sound_position(sound) }
          sound.play
          result = runner.run

        Read Skeet and the current Runner/Sound implementations before turning
        this skeleton into real timing or spatial logic.

        Template 4: transient application signal
        ----------------------------------------
        Keep authoritative state in a server table. A signal only asks the
        active peer to refresh it:

          SIGNAL_VERSION = 1
          SIGNAL_TYPES = %w[state_changed invitation_cancelled].freeze

          def notify_state_changed(user, revision)
            signal(user.to_s, {
              "version" => SIGNAL_VERSION,
              "type" => "state_changed",
              "revision" => revision.to_i
            })
          end

          def signaled(sender, packet)
            return unless packet.is_a?(Hash)
            return unless packet["version"] == SIGNAL_VERSION
            return unless SIGNAL_TYPES.include?(packet["type"])
            return unless sender.is_a?(String) && sender.bytesize <= 200

            revision = Integer(packet["revision"], :exception => false)
            return if packet["type"] == "state_changed" &&
                      (revision == nil || revision.negative?)

            # Queue only validated, minimal data. Let the owning Form or Runner
            # consume it and refresh authoritative table state on its own path.
            (@pending_signals ||= []) << [sender, packet["type"], revision]
          end

        Read the current signal dispatch source before adding acknowledgements,
        ordering assumptions, retries or gameplay timing.
      TEXT
    end
  end
end
