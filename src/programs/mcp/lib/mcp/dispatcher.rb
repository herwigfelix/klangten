# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: server name klangten, rebranded instructions; calendars, tasks and feed removed.

require "json"

module EltenMCP
  DeferredDispatch = Struct.new(:callable, keyword_init: true)

  class Dispatcher
    CURRENT_PROTOCOL_VERSION = "2026-07-28"
    LEGACY_PROTOCOL_VERSION = "2025-11-25"
    SUPPORTED_PROTOCOL_VERSIONS = [CURRENT_PROTOCOL_VERSION, LEGACY_PROTOCOL_VERSION].freeze
    MAX_SESSIONS = 64
    ONBOARDING_META_KEY = "klangten/onboarding"
    ONBOARDING_VERSION = "1.2"

    def initialize(authorization, registry, resources, prompts, source_catalog = nil)
      @authorization = authorization
      @registry = registry
      @resources = resources
      @prompts = prompts
      @source_catalog = source_catalog
      @sessions = {}
      @sessions_mutex = Mutex.new
    end

    def clear_sessions
      @sessions_mutex.synchronize { @sessions.clear }
      true
    end

    def dispatch(payload, header_version = nil, context = {}, defer_worker: true, authorized: false)
      raise InvalidRequestError if !payload.is_a?(Hash)
      raise InvalidRequestError, "jsonrpc must be 2.0" if payload["jsonrpc"] != "2.0"
      method = payload["method"].to_s
      raise InvalidRequestError, "method is required" if method == ""
      params = payload["params"]
      params = {} if params == nil
      raise InvalidParamsError if !params.is_a?(Hash)
      version = protocol_version(method, params, header_version)
      validate_session!(method, context)
      if defer_worker && method == "tools/call"
        tool = @registry.find(params["name"].to_s)
        raise InvalidParamsError, "Unknown tool: #{params["name"]}" if tool == nil
        if tool.execution == :worker
          client = client_info(context)
          @registry.validate_arguments(tool, params["arguments"] || {})
          @authorization.ensure_tool_permission(tool, params["arguments"] || {}, client)
          return DeferredDispatch.new(:callable => proc { dispatch(payload, header_version, context, defer_worker: false, authorized: true) })
        end
      end
      result = route(method, params, version, context, authorized)
      return result if result.is_a?(DeferredDispatch)
      result = decorate_result(result, version)
      return nil if !payload.key?("id")
      { "jsonrpc" => "2.0", "id" => payload["id"], "result" => result }
    rescue EltenMCP::Error => e
      raise if !payload.is_a?(Hash) || !payload.key?("id")
      error = { "code" => e.code, "message" => e.message }
      error["data"] = e.data if e.data != nil
      { "jsonrpc" => "2.0", "id" => payload["id"], "error" => error }
    rescue Exception => e
      Log.error("MCP dispatch failed for #{method}: #{e.class}: #{e.message}, #{Array(e.backtrace).first(20)}") if defined?(Log)
      raise if !payload.is_a?(Hash) || !payload.key?("id")
      { "jsonrpc" => "2.0", "id" => payload["id"], "error" => { "code" => -32603, "message" => "Internal MCP server error" } }
    end

    private

    def route(method, params, version, context, authorized)
      case method
      when "server/discover"
        discover_result
      when "initialize"
        initialize_result(params, context)
      when "notifications/initialized", "notifications/cancelled"
        {}
      when "ping"
        {}
      when "tools/list"
        client = client_info(context)
        @authorization.observe(client)
        list_result("tools", @registry.list(:developer_mode => @authorization.developer_mode?), version)
      when "tools/call"
        tool_call(params, context, authorized)
      when "resources/list"
        client = client_info(context)
        @authorization.observe(client)
        list_result("resources", @resources.list(@authorization.developer_mode?), version)
      when "resources/templates/list"
        list_result("resourceTemplates", [], version)
      when "resources/read"
        resource_read(params, version, context)
      when "prompts/list"
        client = client_info(context)
        @authorization.observe(client)
        list_result("prompts", @prompts.list(@authorization.developer_mode?), version)
      when "prompts/get"
        prompt_get(params, context)
      else
        raise MethodNotFoundError, method
      end
    end

    def discover_result
      onboarding = onboarding_metadata
      {
        "resultType" => "complete",
        "supportedVersions" => SUPPORTED_PROTOCOL_VERSIONS,
        "capabilities" => capabilities,
        "_meta" => {
          "io.modelcontextprotocol/serverInfo" => server_info,
          ONBOARDING_META_KEY => onboarding
        },
        "instructions" => instructions(onboarding),
        "ttlMs" => 300_000,
        "cacheScope" => "private"
      }
    end

    def initialize_result(params, context)
      info = params["clientInfo"]
      info = { "name" => "unknown MCP client", "version" => "" } if !info.is_a?(Hash)
      session_id = context[:new_session_id].to_s
      raise AuthorizationError, "Cannot establish an MCP session" if !valid_session_id?(session_id)
      stored = { "name" => info["name"].to_s[0, 100], "version" => info["version"].to_s[0, 50] }.freeze
      @sessions_mutex.synchronize do
        @sessions.shift while @sessions.size >= MAX_SESSIONS
        @sessions[session_id] = stored
      end
      requested = params["protocolVersion"].to_s
      selected = SUPPORTED_PROTOCOL_VERSIONS.include?(requested) ? requested : LEGACY_PROTOCOL_VERSION
      client = stored.merge("_session_id" => session_id)
      onboarding = onboarding_metadata(client)
      {
        "protocolVersion" => selected,
        "capabilities" => capabilities,
        "serverInfo" => server_info,
        "instructions" => instructions(onboarding),
        "_meta" => { ONBOARDING_META_KEY => onboarding }
      }
    end

    def capabilities
      {
        "tools" => { "listChanged" => false },
        "resources" => { "subscribe" => false, "listChanged" => false },
        "prompts" => { "listChanged" => false },
        "experimental" => {
          ONBOARDING_META_KEY => { "version" => ONBOARDING_VERSION }
        }
      }
    end

    def server_info
      version = defined?(Elten) && Elten.respond_to?(:version) ? Elten.version.to_s : "3"
      # Klangten: own server name, so MCP clients never confuse it with a normal Elten MCP server.
      { "name" => "klangten", "title" => "Klangten local MCP", "version" => version }
    end

    def instructions(onboarding = nil)
      onboarding ||= onboarding_metadata
      sources = onboarding["sources"]
      policy = onboarding["permission_policy"] || {}
      network = policy["network"] || {}
      persistence_instruction = if policy["remember_permissions"] == true
        "Permission memory is enabled: reviewed general and selective grants can be restored for the same signed-in Klango account, current secret key and self-declared client name/version; that client identity text is not cryptographic and can be spoofed by anyone who obtains the key."
      else
        "Permission memory is disabled, so reviewed client grants end with the Klangten security session."
      end
      network_instruction = "The listener is bound to #{network["bind_address"]}; accepted client subnets are #{Array(network["accepted_subnets"]).join(", ")}. #{network["loopback_only"] == true ? "Acceptance is loopback-only." : "Acceptance extends beyond loopback; the user explicitly acknowledged this high-risk mode and automatic default permissions are unavailable."}"
      source_instruction = if sources["available"]
        "Launcher-bundled Ruby sources are available (#{sources["source_count"]} allowlisted files): for application work treat them as authoritative, request source/read when inspection is needed, then call klangten_sources_list and klangten_source_read."
      else
        "Launcher-bundled Ruby sources are unavailable in this process; do not attempt filesystem paths or claim source access. Do not assume docs/ exists. If browsing is permitted, inspect the matching upstream Elten source revision at https://github.com/dawidpieper/elten3 and remember that Klangten modifies it; otherwise state that current source could not be verified."
      end
      grants = onboarding.dig("permissions", "grants") || {}
      grant_instruction = grants.map { |aspect, level| "#{aspect}/#{level}" }.join(", ")
      selective = Array(onboarding.dig("permissions", "selective_grants"))
      selective_instruction = selective.empty? ? "none" : selective.map { |grant| "#{grant["aspect"]}/#{grant["resource_type"]}:#{grant["resource_id"]}=#{grant["level"]}" }.join(", ")
      definitions = onboarding.dig("permissions", "capabilities") || {}
      permission_instruction = definitions.map do |aspect, definition|
        levels = Array(definition["levels"]).join("|")
        "#{aspect}/#{levels}#{definition["always"] ? " (automatic)" : ""}"
      end.join(", ")
      "You control the local Klangten desktop client (a modified Elten 3 client connected to a Klango server) through a strict MCP contract. First preserve the Mcp-Session-Id response header from initialize and send it unchanged on every later request; clientInfo is only a display label and never authorizes access. Next call mcp_permissions_get, read docs_get(document=mcp), inspect tools/list schemas, and determine the complete access scope needed for the task before asking. For bounded forum/message work, first make one mcp_permissions_request for forum/scope and/or messages/scope. After that grant, call forum_scope/messages_scope, analyze all returned IDs, and then make one bulk selective request or one justified request for the necessary full domain levels. notes_scope and blogs_scope remain basic discovery tools. Never request one item at a time: collect every group, forum, thread, correspondent, note, blog, post and creation right needed, assign its required level, then submit one batch. Current general grants: #{grant_instruction}. Current selective grants: #{selective_instruction}. Capability levels available in this Klangten mode: #{permission_instruction}. General grants remain available and should be used when planned work genuinely spans a domain. Forum/messages scope is strictly below read; read, write and moderate inherit scope, while scope alone exposes no protected content tool. Blog grants cover their existing posts; note/post grants are exact. Creation never follows from access to an existing object: request note_creation, blog_creation or post_creation explicitly. For private messages, write covers sending and group creation/update; forwarding additionally requires general messages/write because it spans source and destination; moderate is additionally required for marking read, flags, deletion protection, deletion, participant-history removal, leaving and muting. Basic is automatic. #{persistence_instruction} Key rotation erases remembered client profiles; account changes, MCP disable/restart and transport-session expiry still revoke live sessions. #{network_instruction} #{source_instruction} Use only documented tool actions and semantic fields from each oneOf schema; never invent Klango server parameters, numeric roles or flags, positional rows, encoded payloads, or raw server calls. Non-developer tools return reconstructed typed data and never expose server JSON, authentication tokens, passwords, login keys, email addresses, attachment handles, audio URLs or opaque notification payloads. Reading a forum thread, private-message content or blog post can update read state: explain this before setting acknowledge_read_state when preserving unread state may matter. Batch related work, especially forum_moderate_batch, messages_moderate and notifications_write/mark_read. Request developer/full only for an explicit development task: it is arbitrary in-process code execution, is available only in Klangten developer mode, and is not sandboxed. For application development, read docs_get(document=programming) and docs_get(document=api_overview), read the complete affected program and current Klangten sources/call sites, and remember that Klangten is voice-driven with no graphical interface. Use program_main with Form#wait, Tasks.run or Runner, and treat feature-owned loop_update plus Program#main as legacy. Choose signal for small transient hints. LiveSessions is an advanced API for message exchange, chat contexts and games that do not require immediate UDP communication. Communication is an advanced low-level API for control over realtime binary transmission, including reliable/unreliable delivery and UDP. Read api_overview for the capability map, then inspect the corresponding source. The agent may generate and edit local server_app declarations, including tables, protection and application-notification support. Before register or update, inspect and ask whether the exact signed-in account is the user's developer account that should own the application. After an explicit yes, program_server_schema_apply may perform the write with account matching; otherwise explain the manual Console path. The complete machine-readable startup contract is in _meta[\"#{ONBOARDING_META_KEY}\"]."
    end

    def onboarding_metadata(client = nil)
      policy = @authorization.policy
      permissions = if client == nil
        {
          "grants" => { "basic" => "read" },
          "selective_grants" => [],
          "selective_capabilities" => @authorization.selective_definitions,
          "developer_override" => false,
          "capabilities" => @authorization.definitions,
          "session_bound" => policy["remember_permissions"] != true,
          "transport_session_bound" => true
        }
      else
        @authorization.summary_for(client).merge(
          "session_bound" => policy["remember_permissions"] != true,
          "transport_session_bound" => true
        )
      end
      {
        "version" => ONBOARDING_VERSION,
        "purpose" => "Operate the local Klangten client through documented, typed MCP tools.",
        "session" => {
          "required_after_initialize" => true,
          "response_header" => "Mcp-Session-Id",
          "request_header" => "Mcp-Session-Id",
          "client_info_is_authority" => false,
          "grants_survive_restart" => policy["remember_permissions"] == true,
          "remembered_identity_is_cryptographic" => false
        },
        "permissions" => permissions,
        "permission_policy" => policy,
        "permission_strategy" => {
          "plan_complete_scope_before_requesting" => true,
          "general_tool" => "mcp_permissions_request",
          "general_when" => "Use a domain-wide level when the task genuinely spans that domain or cannot be safely bound to existing resources.",
          "selective_tool" => "mcp_selective_permissions_request",
          "selective_discovery_tools" => ["forum_scope", "messages_scope", "notes_scope", "blogs_scope"],
          "selective_discovery_permissions" => {
            "forum_scope" => { "aspect" => "forum", "level" => "scope" },
            "messages_scope" => { "aspect" => "messages", "level" => "scope" },
            "notes_scope" => { "aspect" => "basic", "level" => "read" },
            "blogs_scope" => { "aspect" => "basic", "level" => "read" }
          },
          "scope_workflow" => "For bounded forum/messages work: request all needed scope grants in one general batch, discover and analyze identifiers, then request one complete selective batch or the justified full domain levels.",
          "selective_when" => "Use one batch of exact groups, forums, threads, correspondents, notes, blogs, posts and creation rights for bounded work.",
          "selective_inheritance" => {
            "blog" => "covers existing posts in that blog",
            "exact" => ["note", "post", "message correspondent"],
            "creation_is_separate" => true
          },
          "maximum_selective_rows_per_batch" => SelectivePermissions::MAX_REQUESTS,
          "avoid_piecemeal_prompts" => true,
          "message_level_semantics" => {
            "scope" => "List only selectable correspondents and their identifiers/types; no conversation or message content.",
            "read" => "Read participant, conversation and message data; opening message content may update read state after acknowledgement.",
            "write" => "Includes read and permits sending messages plus creating or updating message groups. Forwarding spans a source message and destination and requires the general messages/write grant.",
            "moderate" => "Includes read/write and additionally permits mark-all-read, flags, deletion protection, deletion, participant-history removal, leaving groups and mute state."
          },
          "settings_management" => "One regular voice-driven Form collects clients, general and selective grants, remembering, loopback-only defaults and revocation. High-risk checkboxes open standard confirmations and reveal dependent settings only after acceptance.",
          "remembering_risk" => "Remembered profiles trust the signed-in account, current secret key and self-declared client name/version; anyone with the key can spoof that text.",
          "default_scheme_constraint" => "Automatic default permissions can be configured only while every accepted client subnet is loopback; expanding acceptance beyond loopback erases the scheme."
        },
        "sources" => source_metadata,
        "developer_workflow" => {
          "documents" => ["programming", "api_overview"],
          "documents_are_orientation_not_authority" => true,
          "repository_docs_directory_required" => false,
          "source_priority" => "Read current definitions and call sites before using every non-trivial application API.",
          "github_source_fallback" => "https://github.com/dawidpieper/elten3 (upstream Elten; Klangten modifies these sources)",
          "read_complete_program_first" => true,
          "inspect_current_sources_and_call_sites" => true,
          "preferred_entrypoint" => "program_main",
          "interaction_owners" => ["Form#wait", "ListBox#wait_for_item", "TableBox#wait_for_item", "ChoiceListBox#wait_for_choice", "EltenAPI::Tasks.run", "Runner#run"],
          "legacy_patterns" => ["feature-owned loop_update loops", "Program#main", "manual control polling for contained forms"],
          "application_signals" => {
            "send" => "Program#signal(user, packet)",
            "receive" => "Override Program#signaled(sender, packet).",
            "delivery_boundary" => "Current source dispatches only to the active Program $scene with a matching appid.",
            "use_for" => "Small transient hints followed by authoritative-state refresh.",
            "never_use_as" => ["durable storage", "offline inbox", "reliable queue", "sole authoritative game state"],
            "separate_local_events" => "Program.on(event) observes only the fixed host events actually emitted by Programs.emit_event call sites."
          },
          "realtime_communication_choices" => {
            "signal" => {
              "recommended_for" => "Quick and simple informing of an active peer, followed by authoritative-state refresh.",
              "transport" => "Small server-routed application packet; current dispatch is bound to the active matching Program scene.",
              "not_for" => ["durable storage", "offline inbox", "reliable queue"]
            },
            "live_sessions" => {
              "recommended_for" => "Advanced API for message exchange, chat contexts and games that do not require immediate UDP communication.",
              "transport" => "Ordered JSON over Klangten's shared transport; handlers must tolerate at-least-once delivery.",
              "capabilities" => ["session discovery and joining by code", "private messages addressed to a user within the session", "session message history and replay", "server-generated random results", "shared value pools with public/private draws and reveal", "invitation replacement and session lifecycle management"],
              "configuration" => "History, pools and private messages require explicit configuration in Endpoint#create/connect (defaults: stack_entries: 0, pool_count: 0, private_messages: false).",
              "message_metadata" => "Use with_metadata: true and MessageMetadata to distinguish ordinary public participant messages (regular?), private messages, server random results and pool events; message privacy is independent of session visibility.",
              "not_for" => ["UDP or unreliable datagrams"],
              "source" => "src/eapi/live_sessions.rb"
            },
            "communication" => {
              "recommended_for" => "Advanced low-level API for control over realtime binary transmission, including reliable/unreliable delivery and UDP.",
              "transport" => "Dedicated TCP/TLS and UDP relay sockets on a separate port.",
              "capabilities" => ["reliable and unreliable binary delivery", "delivery state", "encryption", "public and private sessions"],
              "source" => "src/eapi/communication.rb"
            }
          },
          "server_schema" => {
            "mandatory_human_question_template" => "Is the currently signed-in Klango account \"<signed_in_account>\" your own developer account, and should it permanently own this application?",
            "never_infer_answer" => true,
            "local_schema_generation_and_editing_allowed" => true,
            "declaration_includes" => ["tables", "table protection", "application notification support"],
            "confirmed_developer_account" => "program_server_schema_apply may register or update only with the exact inspected account and the explicit confirmation token. Persist a returned registration UUID in source.",
            "test_or_secondary_account" => "Do not apply. Explain how to sign in to the intended developer account and execute the prepared command personally in Klangten's developer Console.",
            "mcp_server_writes_allowed_after_explicit_account_confirmation" => true,
            "tools" => ["program_server_schema_inspect", "program_server_schema_prepare", "program_server_schema_apply"]
          }
        },
        "recommended_first_calls" => [
          { "tool" => "mcp_permissions_get", "arguments" => {}, "purpose" => "Read current grants and available capability levels." },
          { "tool" => "docs_get", "arguments" => { "document" => "mcp" }, "purpose" => "Read the complete operating and safety contract." },
          { "method" => "tools/list", "arguments" => {}, "purpose" => "Read exact action variants and oneOf input schemas before calling a domain tool." },
          { "tool" => "klangten_sources_info", "arguments" => {}, "purpose" => "Confirm launcher source availability without requesting source/read." },
          { "tool" => "mcp_permissions_request",
            "arguments_template" => { "requests" => [{ "aspect" => "<capability>", "level" => "<available_level>" }] },
            "purpose" => "For broad work, replace placeholders with every general capability needed and request them in one reviewed batch." },
          { "tool" => "mcp_permissions_request",
            "arguments_template" => { "requests" => [{ "aspect" => "forum", "level" => "scope" }, { "aspect" => "messages", "level" => "scope" }] },
            "purpose" => "For bounded forum/message work, keep only the discovery domains needed, request their minimal scope levels together, then analyze forum_scope/messages_scope before the final permission request." },
          { "tool" => "mcp_selective_permissions_request",
            "arguments_template" => { "requests" => [{ "aspect" => "forum|messages|notes|blogs", "resource_type" => "<scope type>", "resource_id" => "<omit where the creation schema requires no ID>", "level" => "<required level>" }] },
            "purpose" => "For bounded work, first discover and collect the complete resource and creation scope, then request all rows together." }
        ],
        "rules" => [
          "Use only documented semantic fields; never construct private Klango server calls or encodings.",
          "Treat read-state acknowledgement as a user-visible side effect.",
          "Batch related mutations when a batch action is available.",
          "Plan all permissions before protected work. Choose justified general access or one complete selective batch; never prompt item by item.",
          "forum_scope requires forum/scope and messages_scope requires messages/scope. Request needed scope levels together, discover and analyze IDs, then request one complete selective batch or justified full levels. notes_scope and blogs_scope remain basic.",
          "Access to an existing note/blog/post never grants creation. Request the matching creation scope explicitly.",
          "Read permission_policy: remembered grants and automatic defaults may already be active. Never imply that all grants are session-only when permission memory is enabled.",
          "Automatic default permissions are forbidden when accepted client subnets extend beyond loopback.",
          "Never request developer/full for ordinary Klangten operations.",
          "For application work, use programming and api_overview for orientation, but treat current source definitions and call sites as authoritative; never require a local docs/ directory and use the matching GitHub source revision when permitted and necessary.",
          "For realtime application hints, inspect Program#signal/#signaled and active-scene dispatch; keep durable state in server tables and do not confuse remote signals with Program.on host events.",
          "Choose signal for small transient hints. LiveSessions is an advanced API for message exchange, chat contexts and games that do not require immediate UDP communication. Communication is an advanced low-level API for control over realtime binary transmission, including reliable/unreliable delivery and UDP. Read api_overview for the capability map, then inspect the corresponding source.",
          "Klangten is voice-driven and has no graphical interface; never design around visual presentation.",
          "Generate and edit local schemas as needed. Register or update only after the user confirms the exact signed-in developer account; otherwise provide the manual Console procedure."
        ]
      }
    end

    def source_metadata
      info = @source_catalog == nil ? {} : @source_catalog.info
      categories = info["categories"].is_a?(Hash) ? info["categories"] : {}
      {
        "available" => info["available"] == true,
        "launched_by_launcher" => info["launched_by_launcher"] == true,
        "source_count" => [info["source_count"].to_i, 0].max,
        "categories" => {
          "klangten" => [categories["klangten"].to_i, 0].max,
          "bundled_library" => [categories["bundled_library"].to_i, 0].max
        },
        "filesystem_access" => false,
        "permission" => { "aspect" => "source", "level" => "read" },
        "tools" => {
          "availability" => "klangten_sources_info",
          "list" => "klangten_sources_list",
          "read" => "klangten_source_read"
        }
      }
    rescue Exception => e
      Log.error("Cannot inspect bundled-source availability for MCP onboarding: #{e.class}: #{e.message}") if defined?(Log)
      {
        "available" => false,
        "launched_by_launcher" => false,
        "source_count" => 0,
        "categories" => { "klangten" => 0, "bundled_library" => 0 },
        "filesystem_access" => false,
        "permission" => { "aspect" => "source", "level" => "read" },
        "tools" => { "availability" => "klangten_sources_info", "list" => "klangten_sources_list", "read" => "klangten_source_read" }
      }
    end

    def list_result(key, values, version)
      result = { key => values }
      if version == CURRENT_PROTOCOL_VERSION
        result["resultType"] = "complete"
        result["ttlMs"] = 30_000
        result["cacheScope"] = "private"
      end
      result
    end

    def tool_call(params, context, authorized = false)
      name = params["name"].to_s
      tool = @registry.find(name)
      raise InvalidParamsError, "Unknown tool: #{name}" if tool == nil
      client = client_info(context)
      @authorization.ensure_tool_permission(tool, params["arguments"] || {}, client) if !authorized
      Log.info("MCP tool call: #{name}") if defined?(Log)
      result = @registry.call(tool, params["arguments"] || {}, client)
      result = { "value" => result } if !result.is_a?(Hash)
      is_error = result.delete("__is_error") == true
      text = JSON.pretty_generate(result)
      { "content" => [{ "type" => "text", "text" => text }], "structuredContent" => result, "isError" => is_error }
    rescue EltenMCP::Error => e
      developer_tool = tool != nil && tool.permission[:aspect] == :developer
      data = e.data
      if data != nil && !developer_tool
        begin
          data = KnownData.encode(data)
        rescue Exception
          data = nil
        end
      end
      result = { "error" => e.message, "data" => data }.compact
      { "content" => [{ "type" => "text", "text" => JSON.pretty_generate(result) }], "structuredContent" => result, "isError" => true }
    rescue Exception => e
      Log.error("MCP tool #{name} failed: #{e.class}: #{e.message}, #{Array(e.backtrace).first(20)}") if defined?(Log)
      developer_tool = tool != nil && tool.permission[:aspect] == :developer
      result = { "error" => developer_tool ? "#{e.class}: #{e.message}" : "Internal MCP tool error" }
      { "content" => [{ "type" => "text", "text" => JSON.pretty_generate(result) }], "structuredContent" => result, "isError" => true }
    end

    def resource_read(params, version, context)
      uri = params["uri"].to_s
      raise InvalidParamsError, "uri is required" if uri == ""
      @authorization.ensure_permission(@resources.permission_for(uri), client_info(context))
      required, text = @resources.read(uri)
      @authorization.ensure_permission(required, client_info(context))
      result = { "contents" => [{ "uri" => uri, "mimeType" => @resources.mime_type(uri), "text" => text }] }
      if version == CURRENT_PROTOCOL_VERSION
        result["ttlMs"] = 5_000
        result["cacheScope"] = "private"
      end
      result
    end

    def prompt_get(params, context)
      name = params["name"].to_s
      raise InvalidParamsError, "name is required" if name == ""
      required, result = @prompts.get(name, params["arguments"] || {})
      @authorization.ensure_permission(required, client_info(context))
      result
    end

    def client_info(context)
      session_id = context[:session_id].to_s
      info = @sessions_mutex.synchronize { @sessions[session_id] }
      raise AuthorizationError, "Unknown or expired MCP session" if info == nil
      info.merge("_session_id" => session_id)
    end

    def validate_session!(method, context)
      return true if method == "server/discover" || method == "initialize"
      client_info(context)
      true
    end

    def valid_session_id?(value)
      value.bytesize == 64 && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def protocol_version(method, params, header_version)
      meta = params["_meta"].is_a?(Hash) ? params["_meta"] : {}
      value = meta["io.modelcontextprotocol/protocolVersion"] || header_version
      value = params["protocolVersion"] if method == "initialize"
      SUPPORTED_PROTOCOL_VERSIONS.include?(value.to_s) ? value.to_s : LEGACY_PROTOCOL_VERSION
    end

    def decorate_result(result, version)
      return result if version != CURRENT_PROTOCOL_VERSION || !result.is_a?(Hash)
      result["resultType"] ||= "complete"
      meta = result["_meta"].is_a?(Hash) ? result["_meta"] : {}
      meta["io.modelcontextprotocol/serverInfo"] ||= server_info
      result["_meta"] = meta
      result
    end
  end
end
