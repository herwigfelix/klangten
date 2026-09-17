# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; side-by-side notes; calendars, tasks and feed removed; network information without release metadata.

module EltenMCP
  module Documentation
    class << self
      def text
        <<~TEXT
          KLANGTEN LOCAL MCP

          Connection and trust
          --------------------
          This built-in program runs inside the Klangten desktop process and
          is disabled by default. Its safe network default is bind address
          127.0.0.1 with the single accepted client subnet 127.0.0.1/32. Enable
          it under Settings / Model Context Protocol and copy the generated
          client configuration from there. Its random bearer key is a password
          for the endpoint: never place it in a conversation, prompt, log or
          tool argument.

          Klangten MCP is independent of the MCP program of a normal Elten
          installation and can run at the same time: its default port is 37383
          (Elten uses 37373), its configuration and key live in Klangten's own
          data directory, it reports the MCP server name klangten, and client
          configuration entries are written only under the name klangten. An
          existing elten entry is never updated or removed.

          Connection details also offers explicit Add to Claude Code, Codex,
          Antigravity and Hermes actions. Their confirmation is deliberately
          short: it asks whether to add Klangten MCP and says that the configuration
          file will be detected automatically. Validation rules are not recited
          in that question; after confirmation, a failure reports its concrete
          reason. Each program's user configuration must already exist:
          ~/.claude.json for Claude Code; $CODEX_HOME/config.toml (normally
          ~/.codex/config.toml) for Codex; ~/.gemini/config/mcp_config.json for
          Antigravity; and ~/.hermes/config.yaml for Hermes. The Antigravity
          action uses its current serverUrl JSON format. Hermes uses the
          mcp_servers YAML mapping with url and headers. The installer never
          creates a missing file, invokes a client CLI, rewrites the whole
          configuration, repairs an irregular entry or guesses where content
          belongs.

          A new server is added only as the exact name klangten. An existing MCP
          server with that name (including a case variant), or with the same
          normalized HTTP address under any other name, stops the operation.
          The only update exception is an exact, structurally clean klangten HTTP
          entry at the current address whose Authorization value is a
          recognizable previous Klangten bearer key. In that case only the quoted
          header value is replaced. Unexpected fields, duplicate keys/tables,
          malformed JSON/TOML/YAML, YAML aliases/tags, nested or ambiguous JSON
          entries, symlinks and concurrent file changes all fail closed. Hermes
          is handled by a narrow source scanner built into the program, without
          requiring an optional YAML gem. JSON, TOML and YAML edits preserve
          unrelated source text instead of reserializing it. Claude Desktop is
          not the target of this file-based
          remote-server action; the Claude action is specifically for Claude
          Code.

          Advanced MCP network access is configured directly in the main Model
          Context Protocol settings category. It contains a high-risk checkbox,
          the bind IP literal and one single-line IPv4/IPv6 CIDR field. The
          fields are hidden while the checkbox is unchecked. Checking it opens
          a standard confirmation and reveals both fields only after acceptance. Enter multiple
          CIDRs separated by ordinary spaces; commas, semicolons,
          tabs and line breaks are rejected instead of being treated as extra
          input conventions. When the checkbox is unchecked, the entered fields
          are ignored and saving restores 127.0.0.1 with 127.0.0.1/32.
          Hostnames, empty lists, malformed CIDRs and mixed unusable address
          families fail validation. A connection's peer address is checked
          against the configured CIDRs before its bearer key or JSON is read.
          Host and Origin validation remains active. Use narrow private-network
          CIDRs and a firewall; never expose this unauthenticated HTTP transport
          directly to the Internet. Anyone in an accepted subnet who obtains the
          key can initialize an MCP client and request permissions.

          A wildcard bind is a listener setting, not a usable client destination.
          When bind_address is 0.0.0.0, connection details and generated client
          entries therefore advertise 127.0.0.1. For the IPv6 wildcard :: they
          advertise [::1]. This substitution changes only the suggested URL;
          the server still listens on the configured wildcard and still enforces
          the configured accepted CIDRs.

          The key permits a connection, not access to Klangten data. Basic tools
          are always available. By default every protected capability is
          approved manually for each MCP client and lasts only for the current
          Klangten session. Call mcp_permissions_get first, inspect tools/list,
          determine the complete access scope needed for the task, and make one
          reviewed request. For bounded forum/message work first request the
          minimal forum/scope and/or messages/scope levels together, run the
          corresponding discovery tools, analyze the identifiers, and then ask
          once for the complete selective or full access actually needed. Use
          mcp_permissions_request directly for justified domain-wide access or
          mcp_selective_permissions_request after discovery for bounded forum,
          message, note or blog scopes.

          A successful initialize response returns Mcp-Session-Id. Send that
          header on every later request. Grants are keyed by this random,
          unforgeable transport session; clientInfo is only a display label.
          Missing, invalid and expired session identifiers are rejected.

          Permission management is embedded in the main MCP settings category.
          Its synthetic native client list has the MCP clients header. If no clients
          have been observed, the list is empty and its native empty label says so;
          no placeholder client can be selected. Enter opens the selected client's
          combined general/selective editor. The client editor uses an
          ordinary ChoiceListBox for general levels and direct selective/revoke
          actions. Key rotation and global revocation remain direct actions in
          the same settings category; there is no separate top-level permission
          manager.

          Permission memory is disabled by default. Changing its checkbox opens
          a standard confirmation for the high-risk or destructive decision;
          rejecting it restores the previous state, while saving the main settings
          is the explicit decision. When enabled, reviewed general and selective grants are
          stored on disk and restored only for the same signed-in Klango account,
          current secret MCP key and clientInfo name/version. clientInfo remains
          self-declared, not cryptographic: anyone who steals the key can spoof
          the remembered name/version. Disabling memory erases stored profiles;
          rotating the key does too. Live transport sessions are still random
          and are revoked by account change, disable/restart or manual revoke.

          A default permission scheme can automatically grant chosen general
          levels to every newly initialized client. This bypasses individual
          permission confirmation. A separate checkbox opens a standard
          high-risk confirmation and reveals the individual native level fields
          in the main settings category only after acceptance.
          The setting is not offered unless every accepted client CIDR is wholly
          loopback. Expanding accepted CIDRs beyond loopback erases the scheme,
          and the configuration layer rejects attempts to set one in that mode.

          Both server/discover and initialize return a concise agent instruction
          plus the versioned _meta["klangten/onboarding"] object. On initialize it
          contains the session-header contract, current grants, every available
          capability and level, current launcher-source availability, the
          source/read boundary, safe source tool names, and recommended first
          calls. Treat this startup object as authoritative session context;
          klangten_sources_info remains the basic tool for refreshing availability.

          The non-developer contract boundary
          -----------------------------------
          Treat every documented MCP field as the public API. Never invent an
          Klangten server parameter, numeric role, numeric flag, positional row or
          encoded payload. The MCP program validates semantic input, constructs
          the private Klango server call itself, accepts only the expected response
          class and fields, and builds a new response object. It never forwards
          server JSON, an Klango server object or unrecognized fields. A future
          server contract change fails closed with a safe error.

          Raw response Hash objects are forbidden outside developer tools.
          Authentication tokens, login keys, passwords, email addresses,
          cookies and notification payloads are never output. Audio URLs and
          attachment handles are discarded. Numeric values that are meaningful
          only to the server are translated, for example forum membership 2 is
          returned as role "moderator", never as role 2.

          Server failures are translated too. Tools return a named kind such as
          network_unavailable, request_timed_out, request_cancelled,
          invalid_server_response or request_rejected, plus retryable. Native
          error codes, endpoint/module names and response bodies are not exposed.

          All non-developer domain responses contain operation and summary.
          Mutations also contain status "completed". Read summary before using
          the remaining fields. Input schemas use one variant per action and
          reject unknown fields. Read the tool description and its oneOf schema;
          do not reuse field names from another action.

          Permissions
          -----------
          Capabilities are independent: basic; diagnostics/read; account/read
          or write; forum/scope, read, write or moderate; messages/scope, read,
          write or moderate;
          blogs/read or write; notes/read or write; polls/read or write;
          notifications/read or write; settings/write;
          source/read; and developer/full. Developer/full is a global override only after a
          separate manual grant and only when Klangten runs in developer mode.

          Forum, messages, notes and blogs additionally support selective
          grants. They
          complement rather than replace the general levels and share the same
          session/optional-memory policy:

          - forum group, forum or thread at read, write or moderate;
          - message correspondent of type user, group or custom at read, write
            or moderate;
          - exact note at read or write;
          - exact blog or blog post at read or write;
          - note_creation, blog_creation or post_creation at write.
            post_creation names the destination blog; the other creation
            scopes have no resource ID.

          A forum group grant covers its current forums and threads. A forum
          grant covers its current threads. A thread and every message
          correspondent are exact scopes. A blog covers existing posts in that
          blog. Notes and post grants are exact.
          Creation is deliberately separate: access to an existing container
          never permits creating another note/blog or a post,
          and a creation grant does not automatically grant later access to the
          created object. mcp_permissions_get returns both general and selective
          grants.

          Before asking, plan the whole task. For broad searches, all
          correspondents, all notes or other domain-wide work,
          request the necessary general domain level. For bounded forum or
          message work, first make one general request for forum/scope and/or
          messages/scope. Only after that grant call forum_scope and/or
          messages_scope, analyze the returned identifiers and decide between
          one selective batch and the necessary full domain levels.
          notes_scope and blogs_scope remain basic discovery tools. Collect
          every resource and creation right that will be needed, then
          send one mcp_selective_permissions_request containing up to 100 rows
          with independently chosen levels. Do not interrupt the user with one
          request per item or wait for each authorization failure.

          Missing selective access fails closed and returns both possible plans:
          the suitable general request and the missing selective rows. Determine
          the remaining complete scope before requesting either option. General
          and selective requests each use one review dialog for their batch.
          Both are visible and manually addable/removable under the one Manage
          MCP permissions entry. They last for the current session unless the
          user explicitly enables high-risk permission memory.

          Basic information and diagnostics
          ---------------------------------
          klangten_info and klangten_status return named local client/runtime fields.
          klangten_network_info parses only public server time and adds the API
          address and the local Klangten version. Its background probe never runs
          Klangten UI callbacks, has a 15-second timeout, and a successful result
          is cached briefly. Other
          MCP domain calls use a context-free background client with a
          30-second timeout per network request; a multi-request operation may
          therefore take longer without blocking Klangten's UI thread.
          docs_get reads one bundled document; docs_search is a case-insensitive
          substring search returning document, line_number and surrounding
          context. log_tail accepts minimum_level debug, info, warning or error,
          not a number. Diagnostic reports and logs redact obvious credentials,
          but can still contain private operational text. configuration_inspect
          returns a short named non-secret list and excludes authentication, MCP
          and low-level network settings. Restart tools revoke live grants and
          erase remembered profiles; the separately configured loopback-only
          default scheme remains.

          Accounts
          --------
          account_read actions cover profile, visiting_card, status, signature,
          user_info, contacts, birthday_contacts, contacts_added_me, search,
          online, exists, banned, recently_registered, recently_active, honors
          and honor_users. User search returns exact usernames for later calls.
          profile returns username, full_name, gender as unspecified, female or
          male, birthdate as a named object or null, location and
          visible_to_others. visiting_card returns text or null. user_info uses
          ISO 8601 times or null and named relationship, activity and availability
          fields. Mail visibility and all mail/authentication data are discarded.
          account_write updates only explicit public fields, contacts, notices,
          the main honor and online monitors. update_profile accepts full_name,
          gender female/male, birthdate {year, month, day}, location and
          visible_to_others. It has no authentication operation. Klangten's aggregate
          client_state is not exposed wholesale because it crosses account,
          messages, forum and blogs permission boundaries.

          Forum
          -----
          forum_scope requires the minimal forum/scope grant, which is narrower
          than forum/read. It returns only group, forum and thread names/IDs in
          their hierarchy and never post content. The intended sequence is:
          request forum/scope, call forum_scope, analyze all needed IDs, then
          make one selective request or request the necessary full forum level.
          A forum/read, write or moderate grant also satisfies scope through
          ordinary level inheritance. For a
          general forum/read workflow, forum_read/action structure remains
          available and returns groups containing forums containing threads, with
          resolved names, unread counts, permissions and named membership:
          not_a_member, member, moderator, banned, membership_requested or
          invited. Search uses query plus search_in post_content, post_author or
          thread_title. include_audio_transcriptions applies only to post_content.
          user_posts uses next_before as its continuation cursor.
          posted_in_threads checks many thread IDs in one request. Moderation
          reads also expose trash_threads and trash_thread for recovery work.

          Opening forum_read/action thread can mark unread posts as read. The
          first call without acknowledge_read_state=true returns a warning and
          performs no read. Explain this side effect to the user when preserving
          unread state matters, then retry with acknowledgement. Forum post
          content_format is plain_text or markdown. File attachments and audio
          uploads are intentionally unavailable. Post results expose Klangten's
          existing date string as date; it is not a separate ISO timestamp.

          forum_write covers posting, editing, following, membership, read
          state, bookmarks, likes, mentions and reports. Use poll_ids to attach
          existing polls to a new thread. report_post may carry a semantic
          suggestion object; MCP translates it to Klangten's private flags and
          range fields. Ordinary delete_post uses the user's
          normal author rights; moderators should use the batch tool.

          forum_moderation_read returns reports, human-readable moderator
          history, forum trash and group_configuration. Group configuration reparses only
          known settings into profile, access, post_permissions and named
          featured-thread roles; unknown server fields are discarded.

          forum_moderate_batch accepts an actions array. Thread and post actions
          are move_threads, delete_threads, offer_threads, rename_thread,
          accept_thread_offer, refuse_thread_offers, move_posts, delete_posts,
          reorder_post, set_threads_closed, set_threads_pinned and
          set_posts_locked. Omitting before_post_id from reorder_post means move
          to the end. Tag creation accepts label plus aliases; the program, not
          the agent, creates the server tag list.

          For trash cleanup, use forum_moderation_read/action trash_threads
          with group_id, then trash_thread with thread_id for post IDs.
          forum_moderate_batch actions purge_threads and purge_posts permanently
          delete the selected thread_ids or post_ids; purging a thread also
          deletes all its posts. This cannot be undone. Each object needs one
          request within the shared 50-request limit. Use restore_threads or
          restore_posts for recovery. Trash listing maps threads to their parent
          group/forum for selective grants; reading a trash thread maps its posts.

          Group and forum administration includes create_group,
          update_group_motd, update_group_regulations, update_group_profile,
          create_forum, update_forum, set_forums_closed, move_forum,
          restore_threads, restore_posts, delete_forum_tag, invite_users,
          delete_group and delete_forum.
          create_group belongs to forum/moderate. visibility is private/public;
          join_policy is invitation_only, membership_request or open. Valid
          pairs are private+invitation_only, private+membership_request,
          public+membership_request and public+open. Forum content_mode is text,
          voice or mixed. Forum positions are one-based or the word end.

          Use semantic targets such as target_forum_id and named booleans such
          as closed. Report resolution is rejected or accepted. Member actions
          are grant_moderator,
          remove_moderator, resign_moderator, transfer_ownership,
          set_role_inheritance, ban, remove, unban, accept_membership_request,
          reject_membership_request or cancel_invitation. Group related work in
          one call: native bulk operations are coalesced. The complete request
          count is checked before the first mutation, capped at 50, and returned
          in the result. A ban may have expires_at. Accepted reports may set
          use_suggestion=true. Arbitrary group-settings writes,
          permission-policy changes and conference-channel changes remain excluded.

          Selective forum checks happen before network work. Targeted actions
          use their group_id, forum_id or thread_id. A group grant is inherited
          by its forums and threads, and a forum grant by its threads. Actions
          addressed only by post_id become selectable after the containing
          permitted thread has been read and its post IDs mapped. Global search,
          popular/user-wide listings, top-level group creation and any action
          that cannot be bound safely to a discovered scope require the
          corresponding general forum level.
          Refresh forum_scope after structural moderation changes such as
          creating, moving or deleting groups/forums. Newly created ordinary
          threads and posts are mapped immediately by their write actions.

          Private messages
          ----------------
          messages_scope requires the minimal messages/scope grant, which is
          narrower than messages/read. It returns only correspondent identifier,
          display name and participant_type user, group or custom; it never
          returns message text, subjects or last-message metadata. It combines
          recent participants with the user's current message groups. The intended
          sequence is: request messages/scope, call messages_scope, analyze all
          needed identifiers, then make one selective request or request the
          necessary full messages level. A messages/read, write or moderate
          grant also satisfies scope through ordinary level inheritance.

          messages_read progresses from participants to conversations to
          messages. Reading messages can update their read state and uses the
          same acknowledge_read_state flow as forum threads. Results expose
          booleans such as is_read, is_flagged and is_deletion_protected;
          attachments contain display names only, and audio exposes at most a
          transcription and has_audio. forwarded_from identifies the original
          sender when Klangten marks a message as forwarded.

          messages_write sends text and poll_ids, never local files or
          administrator messages. It also creates groups and updates their name
          or adds users, and action forward forwards one existing message to a
          destination correspondent. Forwarding spans its source and destination
          and therefore requires general messages/write; it is not accepted
          under one selective correspondent grant. update_group always requires
          the current/new name because Klangten replaces it.

          messages_moderate owns personal state-management and destructive
          actions: mark_all_read, set_flagged, set_deletion_protected,
          delete_message, delete_conversation, remove_participant, leave_group,
          mute_group and unmute_group. A messages/write grant alone cannot run
          them. messages/moderate is hierarchical and therefore also satisfies
          read and write. duration_seconds=0 mutes a group without automatic
          expiry.

          Selective message grants cover one exact correspondent. Conversation
          listing, reading, sending and participant/group actions can use them.
          After reading a permitted conversation, its message IDs are mapped so
          message-level flag/protection/delete actions can be checked against
          a selective moderate grant for the same correspondent. Global search
          and flagged-message listings require general messages/read;
          mark-all-read without a participant requires general
          messages/moderate; creation of a new group requires general
          messages/write because it has no existing correspondent scope.

          Blogs
          -----
          blogs_read exposes list, exists, details, categories, posts, post,
          managed, mentions, post_details, comments, followers, new_followers,
          followed_posts, post_followed, library, tags and owners. sort_by is
          recently_updated, frequently_updated, frequently_commented, followed
          or popular_with_contacts. Comment status is pending, approved or spam.
          Opening action post can change unread state and requires acknowledgement.
          Returned HTML is converted to readable text; audio/download URLs and
          raw WordPress option objects are not returned.

          blogs_write maps visibility public/private, comments_enabled,
          category_ids, tag_ids and publish_at to Klango server internally. It also
          handles categories, tags, coworkers, follows, mentions and comment
          moderation. Omit blog to use the signed-in user's blog where the
          action permits it.

          blogs_scope is always available for permission planning. action blogs
          returns only blog identifiers/names; action posts requires an exact
          blog and returns only post IDs/titles plus pagination state. A
          selective blog grant applies to that blog and its existing posts; a
          post grant uses resource_id {blog, post_id} and is exact. Creating a
          blog requires blog_creation/write. Creating a post requires
          post_creation/write whose resource_id is the exact destination blog.
          Broad list, managed, mention, follower/library and followed-post
          aggregations remain general because they span resources. With
          selective access, pass blog explicitly rather than relying on the
          signed-in-blog default. Post-only operations fail closed unless the
          blog/post pair is known; mention acknowledgement becomes selectable
          after blogs_read/action mentions maps its destination.

          Notifications
          -------------
          Klangten has no Elten activity feed, so there are no feed tools.
          notifications_read returns display text, normalized
          category, timestamps and is_read. For notifications declared by
          installed server applications, it asks the owning program to map the
          private payload and returns only application name, title and body.
          Application UUID, opaque payload, action, sound and other routing
          fields are discarded. notifications_write/action mark_read
          accepts notification_ids and marks them together in one request;
          mark_all_read handles all current notifications. Never loop one call
          per notification.

          Notes
          -----
          notes_read returns typed notes and note shares; notes_write creates,
          updates, renames, deletes and shares notes. Times are returned as
          ISO 8601. Klangten has no calendars or task projects.

          notes_scope is always available for permission planning. Its notes
          action returns only note IDs and titles, never note text. An exact
          selective note grant should use notes_read/action note; the full
          notes list remains general. Note IDs are positive. Creating a new
          note requires the separate note_creation write scope.

          Polls
          -----
          polls_read/action get returns questions with question_index, kind,
          option_index and maximum_choices. Kinds are single_choice,
          multiple_choice and text. Always read a poll before answering it.
          polls_write/action answer accepts an answers array such as
          {question_index: 0, selected_option_indexes: [1]} or
          {question_index: 1, text: "answer"}. The program validates indexes and
          constructs Klangten's private encoded answer lines; the agent never does.
          Poll creation accepts question objects {text, kind, options,
          maximum_choices}. Results resolve option indexes to text, counts and
          percentages and return text answers directly.

          Settings
          --------
          Call settings_read before settings_write. It returns each allowed
          setting's name, label, explanation, type, current_value, range or
          currently available choices, and restart_recommended. settings_write
          accepts only those exact names and semantic values. Unknown fields and
          unavailable language/voice identifiers fail validation. MCP enabled
          state, port, key and permissions; login/authentication; and low-level
          network transport settings are not changeable here.
          usage_reports is the explicit tristate unset, enabled or disabled.

          Bundled source reading
          ----------------------
          klangten_sources_info is a lightweight local availability check and does
          not enter the worker queue. When Klangten was started by its launcher, it reports an
          in-memory catalog of Klangten Ruby sources and bundled Ruby libraries.
          After source/read permission, klangten_sources_list returns exact names
          and klangten_source_read returns a bounded line range. The implementation
          derives an immutable allowlist only from $ELTEN_EMBEDDED_RB and reads
          through EltenEmbedded.read_rb. It accepts no base directory, performs
          no File read and has no filesystem fallback, so traversal and foreign
          files cannot be reached. It is unavailable outside the launcher.

          For development, current source definitions and call sites are more
          authoritative than prose documentation. Do not assume that the
          repository docs/ directory exists in an installed Klangten client or in
          this Ruby-only catalog. If bundled sources are unavailable and the
          agent is allowed to browse, use the matching revision of the
          upstream Elten sources at https://github.com/dawidpieper/elten3 and
          inspect src/ there; Klangten modifies these sources. GitHub
          documentation is useful context, but never a substitute for checking
          the implementation. If neither route is available, disclose that
          limitation instead of inventing a non-trivial API.

          Deliberate exclusions
          ---------------------
          Non-developer tools omit authentication, two-factor and recovery,
          email/password/login-key changes, account archives/exports,
          global administration, conference/VoIP control,
          local/binary attachments, arbitrary application databases, raw blog
          or group options, notification payloads, session revocation and URL
          brokers. These either expose security state, move opaque data, have
          disproportionate side effects or provide too little agent value.

          Developer access
          ----------------
          Developer/full is the sole exception to the semantic data boundary.
          It is equivalent to arbitrary in-process Ruby execution and can read
          tokens, messages and files, use the network, modify programs and act
          as the user. It is not sandboxed. Tools can inspect/create/edit source
          programs, check syntax, load/unload/reload/run/install/uninstall them,
          build eltenapp or eltsetup packages and evaluate Ruby in persistent
          bindings.

          File tools reject absolute paths, traversal and symbolic-link escapes,
          support base_hash concurrency, audit writes and keep backups. Soft
          reload cannot undo threads, native state or global monkey patches.
          The MCP program cannot unload itself while serving a request; edit it
          and restart Elten.

          Read docs_get(document=programming) before designing an application
          and docs_get(document=api_overview) to locate current controls,
          runners, timers, sound, server-table and other APIs. Read current
          bundled sources and call sites when they are available. New programs
          use program_main and owned interactions; feature-owned loop_update and
          Program#main are legacy compatibility patterns. program_create
          requires main_language and accepts supported_languages. Program
          listing, inspection and verification include localized-name/
          description language metadata, installation origin/type and a safe
          signature_verified boolean rather than certificate internals.

          program_build is unsigned unless both certificate_path and
          private_key_path are supplied. An external signature is emitted only
          after key matching and verification against the current Klangten trust
          root. Paths are accepted; key contents and passwords are not. Extra
          gem bundling remains the responsibility of Klangten's full setup builder.
          Build results include metadata_warnings from canonical language and
          locale preparation; review them before distribution.
          program_install accepts a local eltsetup and uses Klangten's canonical
          staging, rollback, registry and activation path. program_uninstall
          uses Klangten's canonical cleanup path; it preserves program data/cache
          unless remove_data=true is explicitly requested, and cannot uninstall
          the MCP program serving the request.

          Klangten is voice-driven and has no graphical interface. Its controls are
          spoken interaction objects, not graphical widgets.

          The model may generate and edit server_app declarations locally,
          including tables, protection and application-notification support.
          Notification payloads remain owned and mapped by the application.
          Server
          registration binds an application to the signed-in account, so before
          register or update it must inspect the exact account, ask whether this
          is the user's developer account which should own the application, and
          wait for an explicit answer. After yes, program_server_schema_apply
          may perform the write and verifies that the confirmed account still
          matches the signed-in account. After initial registration the model
          edits the returned UUID into source. For a test, secondary, wrong or
          uncertain account it must not apply; it explains how the user can sign
          in to the intended account and execute the command prepared by
          program_server_schema_prepare in Klangten's developer Console. The
          complete procedure is in programming.

          Protocol
          --------
          The endpoint is /mcp over Streamable HTTP. It binds to 127.0.0.1 and
          accepts only 127.0.0.1/32 by default; explicit high-risk user settings
          can choose another IP literal and a space-separated CIDR list. It supports the session-bound
          MCP 2026-07-28 protocol and a compatibility path for 2025-11-25
          initialize clients. JSON responses are used; GET/SSE streams and
          server-initiated requests are not implemented.
        TEXT
      end

      def document(name, bridge)
        case name.to_s
        when "mcp"
          text
        when "programming"
          ProgrammingGuide.text
        when "api_overview"
          APIOverview.text
        else
          bridge.documentation(name)
        end
      end
    end
  end
end
