# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded tool names and texts; note scopes; Klangten documents; network information without release metadata.

require "digest"
require "json"
require "stringio"
require "time"

module EltenMCP
  class ToolCatalog
    # Klangten: EltenLink's privacy policy and the Elten 2.4 migration notice do not apply.
    DOCUMENTS = %w[mcp programming api_overview readme license rules].freeze
    WORKER_TOOLS = %w[
      klangten_network_info docs_get docs_search programs_list programs_inspect log_tail programs_verify
      program_create program_files_list program_file_read program_file_write program_file_apply_edits
      program_file_move program_file_delete program_build program_syntax_check
      klangten_sources_list klangten_source_read
    ].freeze
    NETWORK_INFO_REQUEST_TIMEOUT = 15.0
    NETWORK_INFO_CACHE_TTL = 15.0
    NETWORK_INFO_FAILURE_CACHE_TTL = 3.0

    def initialize(registry, bridge, workspace, authorization, source_catalog = nil)
      @registry = registry
      @bridge = bridge
      @workspace = workspace
      @authorization = authorization
      @source_catalog = source_catalog || SourceCatalog.new
      @package_builder = PackageBuilder.new(workspace)
      @program_installer = ProgramInstaller.new(workspace)
      @network_info_mutex = Mutex.new
      @network_info_cache = nil
      @eval_binding = TOPLEVEL_BINDING
      @program_bindings = {}
    end

    def register_all
      register_information_tools
      register_diagnostic_tools
      DomainTools.new(@registry, @bridge, @authorization).register_all
      register_developer_tools
    end

    private

    def register_information_tools
      register("klangten_info", "Klangten information", "Return the client version, runtime, platform and MCP mode without secrets.", :basic) { |_args| klangten_info }
      register("klangten_status", "Klangten status", "Return current scene, login state, loaded program count and MCP status without the session token.", :basic) { |_args| klangten_status }
      register("klangten_network_info", "Klangten network information", "Return a parsed model containing only public server time, reachability, the API address and the local Klangten version; session data is excluded.", :basic) { |_args| klangten_network_info }
      register("docs_get", "Read Klangten documentation", "Read one bundled Klangten document.", :basic, object({ "document" => string_enum(DOCUMENTS) }, ["document"])) do |args|
        document = args["document"]
        tool_response("read_document", "Returned bundled Klangten document '#{document}'.",
          "document" => document, "text" => document_text(document))
      end
      register("docs_search", "Search Klangten documentation", "Search bundled Klangten documents and return matching lines with context.", :basic, object({ "query" => string_schema, "limit" => integer_schema(1, 100) }, ["query"])) do |args|
        docs_search(args["query"], args["limit"] || 30)
      end
      register("mcp_permissions_get", "Get MCP permissions", "Return general capability definitions, domain-wide grants, all selective definitions and the current selective scope list for this MCP client. Basic access is always enabled; no secret is returned.", :basic) do |_args, client|
        permission_snapshot(client, "inspect_permissions")
      end
      permission_variants = Authorization::CAPABILITIES.filter_map do |aspect, definition|
        next if aspect == :developer && !@authorization.developer_mode?
        object({
          "aspect" => string_enum([aspect.to_s]),
          "level" => string_enum(Array(definition[:levels]).map(&:to_s))
        }, ["aspect", "level"])
      end
      request_schema = object({
        "requests" => {
          "type" => "array", "minItems" => 1, "maxItems" => 10,
          "items" => { "oneOf" => permission_variants }
        }
      }, ["requests"])
      register("mcp_permissions_request", "Request general MCP permissions", "Request several capabilities in one reviewed batch. For bounded forum or message work, first request the minimal scope level, run the matching discovery tool, analyze all required resources, and then make one bulk selective request. Request read/write/moderate directly when the task genuinely spans the domain.", :basic, request_schema, mutating_annotations) do |args, client|
        @authorization.request_many(client, args["requests"])
        permission_snapshot(client, "request_permissions")
      end
      selective_request_schema = object({
        "requests" => {
          "type" => "array", "minItems" => 1, "maxItems" => SelectivePermissions::MAX_REQUESTS,
          "items" => {
            "oneOf" => [
              object({
                "aspect" => string_enum(%w[forum]),
                "resource_type" => string_enum(%w[group forum thread]),
                "resource_id" => integer_schema(1, 2_147_483_647),
                "level" => string_enum(%w[read write moderate])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[messages]),
                "resource_type" => string_enum(%w[user group custom]),
                "resource_id" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                "level" => string_enum(%w[read write moderate])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[notes]),
                "resource_type" => string_enum(%w[note]),
                "resource_id" => integer_schema(1, 2_147_483_647),
                "level" => string_enum(%w[read write])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[notes]),
                "resource_type" => string_enum(%w[note_creation]),
                "level" => string_enum(%w[write])
              }, %w[aspect resource_type level]),
              object({
                "aspect" => string_enum(%w[blogs]),
                "resource_type" => string_enum(%w[blog]),
                "resource_id" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                "level" => string_enum(%w[read write])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[blogs]),
                "resource_type" => string_enum(%w[post]),
                "resource_id" => object({
                  "blog" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                  "post_id" => integer_schema(1, 2_147_483_647)
                }, %w[blog post_id]),
                "level" => string_enum(%w[read write])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[blogs]),
                "resource_type" => string_enum(%w[post_creation]),
                "resource_id" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                "level" => string_enum(%w[write])
              }, %w[aspect resource_type resource_id level]),
              object({
                "aspect" => string_enum(%w[blogs]),
                "resource_type" => string_enum(%w[blog_creation]),
                "level" => string_enum(%w[write])
              }, %w[aspect resource_type level])
            ]
          }
        }
      }, ["requests"])
      register("mcp_selective_permissions_request", "Request selective MCP permissions", "Request up to 100 exact forum, correspondent, note, blog, post or creation scopes in one reviewed dialog. For forum/messages, first obtain the matching scope permission and run its discovery tool; notes_scope and blogs_scope remain basic. Analyze the complete task scope, then submit one batch so the user is not interrupted repeatedly. Access to an existing container never implies creation; request creation explicitly. General domain grants remain available through mcp_permissions_request.", :basic,
        selective_request_schema, mutating_annotations) do |args, client|
        @authorization.request_selective_many(client, args["requests"])
        permission_snapshot(client, "request_selective_permissions")
      end
      register("klangten_sources_info", "Bundled source availability", "Report whether this Klangten process was started by the launcher and exposes its embedded Ruby source catalog. This never reads the filesystem.", :basic) do |_args|
        values = @source_catalog.info
        values["categories"] = object_value(values["categories"])
        tool_response("inspect_bundled_sources", values["available"] ? "Bundled Klangten sources are available from the launcher allowlist." : "Bundled Klangten sources are unavailable because this process was not started by the launcher.", values)
      end
      source_filter_schema = object({
        "category" => string_enum(%w[klangten bundled_library]),
        "prefix" => { "type" => "string", "maxLength" => 2048 },
        "query" => { "type" => "string", "maxLength" => 500 },
        "limit" => integer_schema(1, SourceCatalog::MAX_LIST_RESULTS)
      })
      register("klangten_sources_list", "List bundled Klangten sources", "List only Ruby source names present in the launcher's immutable embedded-source manifest. No caller-selected directory or filesystem fallback exists.", :source, source_filter_schema) do |args|
        values = @source_catalog.list(:category => args["category"], :prefix => args["prefix"], :query => args["query"], :limit => args["limit"] || 200)
        values["sources"] = values["sources"].map { |entry| object_value(entry) }
        tool_response("list_bundled_sources", "Returned #{values["count"]} of #{values["total_matching"]} matching bundled Ruby sources.", values)
      end
      source_read_schema = object({
        "path" => { "type" => "string", "minLength" => 1, "maxLength" => 2048 },
        "start_line" => integer_schema(1, 100_000_000),
        "line_count" => integer_schema(1, SourceCatalog::MAX_READ_LINES)
      }, ["path"])
      register("klangten_source_read", "Read a bundled Klangten source", "Read a bounded line range from one exact path returned by klangten_sources_list. Content comes directly from the launcher's embedded Ruby blob; arbitrary files cannot be opened.", :source, source_read_schema) do |args|
        values = @source_catalog.read(args["path"], :start_line => args["start_line"] || 1, :line_count => args["line_count"] || 400)
        tool_response("read_bundled_source", "Returned bundled source #{values["path"]}, lines #{values["start_line"]}..#{values["end_line"] || values["start_line"]}.", values)
      end
      register("programs_list", "List Klangten programs", "List installed program metadata and load status, including localized/raw names and descriptions, declared languages, installation origin/type and a safe signature_verified boolean. Program discovery is part of full developer access.", :developer) { |_args| { "programs" => @workspace.entries } }
      register("programs_inspect", "Inspect an Klangten program", "Return manifest, localization, installation, safe signature verification and source status for a program selected by folder, storage id or UUID.", :developer, program_schema) do |args|
        @workspace.inspect_entry(args["program"])
      end
    end

    def register_diagnostic_tools
      register("diagnostics_create", "Create diagnostic report", "Create a redacted diagnostic report. It can still contain private operational information.", :diagnostics) do |_args|
        raw_report = @bridge.debug_info
        raise ToolError, "Unexpected diagnostic report contract" if !raw_report.is_a?(String)
        report = redact_diagnostics(raw_report)
        tool_response("create_diagnostic_report", "Created a redacted diagnostic report. It can still contain private operational information.",
          "report" => report, "credentials_redacted" => true, "paths_redacted" => true)
      end
      register("log_tail", "Read recent Klangten logs", "Read recent in-memory log entries at or above a named severity. Credentials are redacted, but logs may still contain private data.", :diagnostics, object({ "limit" => integer_schema(1, 1000), "minimum_level" => string_enum(%w[debug info warning error]) })) do |args|
        limit = args["limit"] || 200
        minimum_level = args["minimum_level"] || "info"
        level = { "debug" => -1, "info" => 0, "warning" => 1, "error" => 2 }.fetch(minimum_level)
        raw_log = Log.get(limit, level, true, true)
        raise ToolError, "Unexpected log contract" if !raw_log.is_a?(String)
        log = redact_secrets(raw_log)
        tool_response("read_log", "Returned up to #{limit} recent log entries at #{minimum_level} severity or higher. Logs may still contain private information.",
          "log" => log, "limit" => limit, "minimum_level" => minimum_level, "credentials_redacted" => true)
      end
      register("programs_verify", "Verify installed programs", "Re-read program manifests and report load, compatibility and signature states.", :diagnostics) do |_args|
        programs = @workspace.entries(true).map { |entry| diagnostic_program(entry) }
        tool_response("verify_programs", "Verified #{programs.size} installed program manifests and load states.",
          "programs" => programs, "count" => programs.size, "developer_mode" => @bridge.developer_mode?)
      end
      register("configuration_inspect", "Inspect safe configuration", "Return a selected non-secret subset of Klangten configuration.", :diagnostics) { |_args| configuration_snapshot }
      register("klangten_restart", "Restart Klangten session", "Return to Klangten's loading scene, revoke live MCP grants and erase remembered client profiles. The separate loopback-only default scheme remains.", :diagnostics, nil, destructive_annotations) do |_args|
        EltenMCP.revoke_permissions
        $restart = true
        $scene = Scene_Loading.new
        tool_response("restart", "Scheduled a normal Elten session restart; revoked live grants and erased remembered client profiles. A configured loopback-only default scheme remains.",
          "scheduled" => true, "mode" => "normal", "mcp_permissions_revoked" => true, "default_permission_scheme_preserved" => true)
      end
      register("klangten_restart_developer", "Restart Klangten in developer mode", "Exit and relaunch Klangten with the developer flag. Live grants and remembered profiles are erased; the separate loopback-only default scheme remains.", :diagnostics, nil, destructive_annotations) do |_args|
        raise ToolError, "Klangten is already in developer mode" if @bridge.developer_mode?
        EltenMCP.revoke_permissions
        success = @bridge.restart_to_developer
        raise ToolError, "Cannot schedule a developer-mode restart" if !success
        tool_response("restart_in_developer_mode", "Scheduled an Klangten restart in developer mode; revoked live grants and erased remembered profiles. Developer tools require a new grant unless the preserved loopback-only default scheme explicitly grants developer/full.",
          "scheduled" => true, "mode" => "developer", "mcp_permissions_revoked" => true, "default_permission_scheme_preserved" => true)
      end
    end

    def register_developer_tools
      register("program_create", "Create an Klangten program", "Create a source program with a valid Elten3AppInfo manifest, explicit language metadata and starter class.", :developer,
        object({
          "folder" => string_schema, "name" => string_schema, "author" => string_schema,
          "main_language" => string_schema,
          "supported_languages" => { "type" => "array", "maxItems" => 100, "items" => string_schema },
          "id" => string_schema, "version" => string_schema
        }, ["folder", "name", "author", "main_language"]), mutating_annotations) do |args|
        @workspace.create_program(
          :folder => args["folder"], :name => args["name"], :author => args["author"],
          :main_language => args["main_language"], :supported_languages => args["supported_languages"],
          :id => args["id"], :version => args["version"] || "0.1.0"
        )
      end
      register("program_files_list", "List program files", "List editable files below a source program directory. Symbolic links are excluded.", :developer,
        object(program_properties.merge("path" => string_schema, "recursive" => boolean_schema), ["program"])) do |args|
        @workspace.list_files(args["program"], args["path"] || "", args["recursive"] != false)
      end
      register("program_file_read", "Read a program file", "Read a UTF-8 or base64-encoded program source or asset and return its SHA-256 hash.", :developer,
        object(program_properties.merge("path" => string_schema, "encoding" => string_enum(%w[utf8 base64])), ["program", "path"])) do |args|
        @workspace.read_file(args["program"], args["path"], args["encoding"] || "utf8")
      end
      register("program_file_write", "Write a program file", "Atomically write a program file. base_hash enables optimistic concurrency; the previous file is backed up.", :developer,
        object(program_properties.merge("path" => string_schema, "content" => string_schema, "encoding" => string_enum(%w[utf8 base64]), "base_hash" => string_schema), ["program", "path", "content"]), mutating_annotations) do |args|
        @workspace.write_file(args["program"], args["path"], args["content"], args["encoding"] || "utf8", args["base_hash"])
      end
      edit_schema = object({ "old_text" => string_schema, "new_text" => string_schema }, ["old_text", "new_text"])
      register("program_file_apply_edits", "Apply exact edits to a program file", "Apply ordered exact old_text/new_text replacements. Each old_text must occur exactly once; the previous file is backed up.", :developer,
        object(program_properties.merge("path" => string_schema, "base_hash" => string_schema, "edits" => { "type" => "array", "minItems" => 1, "items" => edit_schema }), ["program", "path", "edits"]), mutating_annotations) do |args|
        @workspace.apply_edits(args["program"], args["path"], args["edits"], args["base_hash"])
      end
      register("program_file_move", "Move a program file", "Move a file or directory inside one program after making a backup.", :developer,
        object(program_properties.merge("from" => string_schema, "to" => string_schema, "base_hash" => string_schema), ["program", "from", "to"]), mutating_annotations) do |args|
        @workspace.move_file(args["program"], args["from"], args["to"], args["base_hash"])
      end
      register("program_file_delete", "Delete a program file", "Delete a file or directory after copying it to the MCP backup store.", :developer,
        object(program_properties.merge("path" => string_schema, "recursive" => boolean_schema, "base_hash" => string_schema), ["program", "path"]), destructive_annotations) do |args|
        @workspace.delete_file(args["program"], args["path"], args["recursive"] == true, args["base_hash"])
      end
      register("program_load", "Load a program", "Load an already installed package or source program into the running developer client. Use program_install for a new local eltsetup.", :developer, program_schema, mutating_annotations) do |args|
        entry = @workspace.inspect_entry(args["program"])["entry"]
        success = Programs.load_sig(entry, :raise_errors => true)
        raise ToolError, "Program failed to load; inspect the Klangten log" if !success
        { "program" => entry, "loaded" => true }
      end
      register("program_unload", "Unload a program", "Unregister a loaded program. Threads and global monkey patches created by the program are not undone.", :developer, program_schema, destructive_annotations) do |args|
        entry = @workspace.inspect_entry(args["program"])["entry"]
        reject_current_program_unload(entry)
        removed = Programs.delete(entry)
        Programs.set_entry_loaded(entry, false)
        { "program" => entry, "unloaded" => removed, "warning" => "Program-created threads and global patches are not automatically undone." }
      end
      register("program_reload", "Reload a program", "Unregister and load a source program again. This is a soft reload and cannot undo program-created threads or global patches.", :developer, program_schema, destructive_annotations) do |args|
        entry = @workspace.inspect_entry(args["program"])["entry"]
        reject_current_program_unload(entry)
        removed = Programs.delete(entry, :reason => :reload)
        raise ToolError, "Program could not be unloaded for reload" if !removed
        success = Programs.load_sig(entry)
        raise ToolError, "Program failed to reload; inspect the Klangten log" if !success
        { "program" => entry, "loaded" => true, "warning" => "Soft reload does not undo program-created threads or global patches." }
      end
      register("program_run", "Run a loaded program", "Switch Klangten to an instance of the program's main class.", :developer, program_schema, mutating_annotations) do |args|
        entry = @workspace.inspect_entry(args["program"])["entry"]
        cls = Programs.list.find { |program| program.app_runtime != nil && program.app_runtime.entry_id == entry }
        raise ToolError, "Program is not loaded" if cls == nil
        @bridge.launch_program_scene(cls)
        { "program" => entry, "scene" => cls.name.to_s, "scheduled" => true }
      end
      register("program_install", "Install and load an eltsetup", "Install or update one local .eltsetup through Klangten's canonical staging, rollback, registry and activation path. This can replace an existing installed program; it refuses to update the MCP program serving the request.", :developer,
        object({ "package_path" => string_schema }, ["package_path"]), destructive_annotations) do |args|
        @program_installer.install(args["package_path"])
      end
      register("program_uninstall", "Uninstall an Klangten program", "Unload and uninstall one exact local program through Klangten's canonical cleanup path. Program data and cache are preserved by default; remove_data=true also removes them. The MCP program serving the request cannot uninstall itself.", :developer,
        object(program_properties.merge("remove_data" => boolean_schema), ["program"]), destructive_annotations) do |args|
        @workspace.uninstall(args["program"], args["remove_data"] == true)
      end
      build_properties = program_properties.merge(
        "format" => string_enum(%w[eltenapp eltsetup]),
        "certificate_path" => string_schema,
        "private_key_path" => string_schema
      )
      register("program_build", "Build an Klangten program package", "Build .eltenapp or .eltsetup in Elten's MCP build directory. The default is unsigned. To sign the embedded eltenapp, provide both local certificate_path and private_key_path; MCP verifies the key match, signature and current Klangten trust chain and never returns key data. Declared extra gems require Klangten's full setup builder.", :developer,
        object(build_properties, ["program"]), mutating_annotations) do |args|
        @package_builder.build(
          args["program"],
          args["format"] || "eltenapp",
          :certificate_path => args["certificate_path"],
          :private_key_path => args["private_key_path"]
        )
      end
      register("program_server_schema_inspect", "Inspect a program's server application declaration", "Read the loaded program's local server_app declaration, including tables, protection and application-notification support, plus the exact signed-in account that must be confirmed before a server write. It performs no server request. The agent may generate and edit the local declaration without account confirmation.", :developer,
        program_schema) do |args|
        program_server_schema_snapshot(args["program"])
      end
      register("program_server_schema_prepare", "Prepare manual server-application registration", "Validate a loaded program's local server_app declaration and return the exact Klangten developer Console command for register or update. It never contacts the server. Use this fallback when the signed-in account is not the intended developer account or the user prefers to perform the write personally.", :developer,
        object(program_properties.merge("action" => string_enum(%w[register update])), %w[program action])) do |args|
        program_server_schema_prepare(args["program"], args["action"])
      end
      schema_apply_properties = program_properties.merge(
        "action" => string_enum(%w[register update]),
        "confirmed_account" => string_schema,
        "account_confirmation" => string_enum(%w[confirmed_own_developer_account])
      )
      register("program_server_schema_apply", "Register or update a program's server application", "Perform the declared server_app register or update operation, including its tables, protection and notification capability. First call program_server_schema_inspect, ask the user whether its signed_in_account is their own developer account that should own the application, and wait for an explicit affirmative answer. Pass that exact account name and the required confirmation token. Never call this tool for a test, secondary, wrong or uncertain account.", :developer,
        object(schema_apply_properties, %w[program action confirmed_account account_confirmation]), destructive_annotations) do |args|
        program_server_schema_apply(args["program"], args["action"], args["confirmed_account"], args["account_confirmation"])
      end
      register("program_syntax_check", "Check program Ruby syntax", "Compile selected Ruby files without executing them and report every syntax error.", :developer,
        object(program_properties.merge("paths" => { "type" => "array", "items" => string_schema }), ["program"])) do |args|
        program_syntax_check(args["program"], args["paths"])
      end
      register("program_eval", "Evaluate Ruby in a loaded program", "Evaluate Ruby in a persistent binding whose self is the loaded program namespace and whose require context is that program. No sandbox or reliable timeout is provided.", :developer,
        object(program_properties.merge("code" => string_schema, "filename" => string_schema), ["program", "code"]), destructive_annotations) do |args|
        entry, runtime = loaded_runtime(args["program"])
        cached = @program_bindings[entry]
        binding_value = if cached.is_a?(Array) && cached[0].equal?(runtime)
                          cached[1]
                        else
                          runtime.namespace.module_eval("binding", "(mcp-program-binding)", 1)
                        end
        @program_bindings[entry] = [runtime, binding_value]
        evaluate(args["code"], args["filename"] || "(mcp:#{entry})", binding_value, runtime)
      end
      register("ruby_eval", "Evaluate Ruby in Klangten", "Evaluate arbitrary Ruby in a persistent top-level binding inside the Klangten process. No sandbox or reliable timeout is provided.", :developer,
        object({ "code" => string_schema, "filename" => string_schema }, ["code"]), destructive_annotations) do |args|
        evaluate(args["code"], args["filename"] || "(mcp)", @eval_binding)
      end
    end

    def register(name, title, description, permission, input_schema = nil, annotations = nil, &block)
      requirement = Authorization.requirement(permission)
      safe_block = if requirement[:aspect] == :developer
        block
      else
        proc do |args, client|
          value = block.arity == 1 ? block.call(args) : block.call(args, client)
          encoded = KnownData.encode(value)
          raise ToolError, "Non-developer MCP response was not explicitly constructed" if !encoded.is_a?(KnownData::ObjectValue)
          encoded
        end
      end
      output_schema = if requirement[:aspect] == :developer
        { "type" => "object" }
      else
        {
          "type" => "object",
          "properties" => {
            "operation" => { "type" => "string" },
            "summary" => { "type" => "string" }
          },
          "required" => %w[operation summary]
        }
      end
      @registry.register(name, :title => title, :description => description, :permission => permission,
        :input_schema => input_schema || object({}, []), :output_schema => output_schema,
        :annotations => annotations || read_only_annotations,
        :execution => (WORKER_TOOLS.include?(name.to_s) ? :worker : :main), &safe_block)
    end

    def object(properties, required = [])
      schema = { "type" => "object", "properties" => properties, "additionalProperties" => false }
      schema["required"] = required if !required.empty?
      schema
    end

    def string_schema
      { "type" => "string" }
    end

    def string_enum(values)
      { "type" => "string", "enum" => values }
    end

    def integer_schema(minimum, maximum)
      { "type" => "integer", "minimum" => minimum, "maximum" => maximum }
    end

    def boolean_schema
      { "type" => "boolean" }
    end

    def program_properties
      { "program" => string_schema }
    end

    def program_schema
      object(program_properties, ["program"])
    end

    def read_only_annotations
      { "readOnlyHint" => true, "destructiveHint" => false, "idempotentHint" => true, "openWorldHint" => false }
    end

    def mutating_annotations
      { "readOnlyHint" => false, "destructiveHint" => false, "idempotentHint" => false, "openWorldHint" => false }
    end

    def destructive_annotations
      { "readOnlyHint" => false, "destructiveHint" => true, "idempotentHint" => false, "openWorldHint" => true }
    end

    def object_value(values = {})
      KnownData.object(values)
    end

    def tool_response(operation, summary, values = {})
      raise ToolError, "Internal MCP response fields must be an object" if !values.is_a?(Hash)
      object_value({ "operation" => operation.to_s, "summary" => summary.to_s }.merge(values))
    end

    def permission_snapshot(client, operation)
      snapshot = @authorization.summary_for(client)
      raise ToolError, "Unexpected permission summary contract" if !snapshot.is_a?(Hash)
      client_label = snapshot["client"]
      grants = snapshot["grants"]
      developer_override = snapshot["developer_override"]
      selective = snapshot["selective_grants"]
      selective_definitions = snapshot["selective_capabilities"]
      permission_source = snapshot["permission_source"].to_s
      policy = snapshot["permission_policy"]
      raise ToolError, "Unexpected permission client contract" if !client_label.is_a?(String)
      raise ToolError, "Unexpected permission grants contract" if !grants.is_a?(Hash)
      raise ToolError, "Unexpected developer override contract" if developer_override != true && developer_override != false
      raise ToolError, "Unexpected selective grants contract" if !selective.is_a?(Array)
      raise ToolError, "Unexpected selective capability contract" if !selective_definitions.is_a?(Hash)
      raise ToolError, "Unexpected permission policy contract" if !policy.is_a?(Hash)
      known_aspects = Authorization::CAPABILITIES.keys.map(&:to_s)
      unknown = grants.keys.map(&:to_s) - known_aspects
      raise ToolError, "Unexpected permission aspect contract" if !unknown.empty?
      capabilities = Authorization::CAPABILITIES.filter_map do |aspect, definition|
        next if aspect == :developer && !@authorization.developer_mode?
        aspect_name = aspect.to_s
        granted = grants[aspect_name] || (definition[:always] ? "read" : "none")
        allowed = [:none] + Array(definition[:levels])
        granted_symbol = granted.to_s.to_sym
        raise ToolError, "Unexpected permission level contract" if !allowed.include?(granted_symbol)
        levels = allowed.map do |level|
          object_value("level" => level.to_s, "label" => Authorization::LEVEL_LABELS.fetch(level))
        end
        object_value(
          "aspect" => aspect_name, "title" => definition[:title].to_s,
          "description" => definition[:description].to_s,
          "granted_level" => granted_symbol.to_s,
          "granted_level_label" => Authorization::LEVEL_LABELS.fetch(granted_symbol),
          "available_levels" => levels, "always_enabled" => definition[:always] == true
        )
      end
      selective_grants = selective.map do |grant|
        raise ToolError, "Unexpected selective grant item" if !grant.is_a?(Hash)
        resource_id = grant["resource_id"]
        resource_id = object_value(resource_id) if resource_id.is_a?(Hash)
        object_value(
          "aspect" => grant["aspect"].to_s,
          "resource_type" => grant["resource_type"].to_s,
          "resource_id" => resource_id,
          "label" => grant["label"].to_s,
          "level" => grant["level"].to_s
        )
      end
      selective_capabilities = selective_definitions.map do |aspect, definition|
        raise ToolError, "Unexpected selective definition" if !definition.is_a?(Hash)
        object_value(
          "aspect" => aspect.to_s,
          "resource_types" => Array(definition["resource_types"]).map(&:to_s),
          "levels" => Array(definition["levels"]).map(&:to_s),
          "inheritance" => definition["inheritance"].to_s
        )
      end
      remembered = policy["remember_permissions"] == true
      lifetime = remembered ? "live transport session plus remembered account/key/client profile" : "current Klangten session only"
      tool_response(operation, "Returned #{capabilities.size} general MCP capabilities and #{selective_grants.size} selective grants for #{client_label}. Permission memory is #{remembered ? "enabled" : "disabled"}; source: #{permission_source}.",
        "client" => client_label, "capabilities" => capabilities,
        "selective_grants" => selective_grants,
        "selective_capabilities" => selective_capabilities,
        "developer_override_active" => developer_override,
        "permission_source" => permission_source,
        "permission_policy" => permission_policy_value(policy),
        "grant_lifetime" => lifetime)
    end

    def permission_policy_value(policy)
      defaults = policy["default_permissions"]
      network = policy["network"]
      raise ToolError, "Unexpected default permission policy contract" if !defaults.is_a?(Hash)
      raise ToolError, "Unexpected network permission policy contract" if !network.is_a?(Hash)
      raise ToolError, "Unexpected permission memory policy contract" if policy["remember_permissions"] != true && policy["remember_permissions"] != false
      raise ToolError, "Unexpected default permission availability contract" if policy["default_permissions_available"] != true && policy["default_permissions_available"] != false
      raise ToolError, "Unexpected network bind policy contract" if !network["bind_address"].is_a?(String) || network["bind_address"] == ""
      raise ToolError, "Unexpected network subnet policy contract" if !network["accepted_subnets"].is_a?(Array) || !network["accepted_subnets"].all? { |value| value.is_a?(String) }
      raise ToolError, "Unexpected network loopback policy contract" if network["loopback_only"] != true && network["loopback_only"] != false
      object_value(
        "remember_permissions" => policy["remember_permissions"],
        "remembered_profile_scope" => policy["remembered_profile_scope"].to_s,
        "default_permissions_available" => policy["default_permissions_available"],
        "default_permissions" => object_value(defaults),
        "network" => object_value(
          "bind_address" => network["bind_address"],
          "accepted_subnets" => network["accepted_subnets"],
          "loopback_only" => network["loopback_only"]
        )
      )
    end

    def mcp_status_value
      status = EltenMCP.status
      raise ToolError, "Unexpected local MCP status contract" if !status.is_a?(Hash)
      %w[enabled listening developer_mode].each do |name|
        value = status[name]
        raise ToolError, "Unexpected local MCP #{name} contract" if value != true && value != false
      end
      raise ToolError, "Unexpected local MCP endpoint contract" if !status["host"].is_a?(String) || status["host"] == "" || !status["port"].is_a?(Integer)
      raise ToolError, "Unexpected accepted subnet contract" if !status["allowed_subnets"].is_a?(Array) || !status["allowed_subnets"].all? { |value| value.is_a?(String) }
      raise ToolError, "Unexpected loopback-only contract" if status["loopback_only"] != true && status["loopback_only"] != false
      error = status["last_error"]
      raise ToolError, "Unexpected local MCP error contract" if !error.is_a?(String)
      object_value(
        "is_enabled" => status["enabled"], "is_listening" => status["listening"],
        "endpoint" => object_value("host" => status["host"], "port" => status["port"]),
        "accepted_client_subnets" => status["allowed_subnets"],
        "loopback_only" => status["loopback_only"],
        "developer_mode" => status["developer_mode"],
        "last_start_error" => (error == "" ? nil : redact_secrets(error)),
        "authorization" => runtime_authorization_value(status["authorization"])
      )
    end

    def runtime_authorization_value(summary)
      raise ToolError, "Unexpected runtime authorization contract" if !summary.is_a?(Hash)
      integers = %w[known_clients authorized_clients selective_grant_count denied_requests]
      integers.each { |name| raise ToolError, "Unexpected authorization #{name} contract" if !summary[name].is_a?(Integer) }
      grants = summary["granted_capabilities"]
      raise ToolError, "Unexpected granted capabilities contract" if !grants.is_a?(Hash)
      known = Authorization::CAPABILITIES.keys.map(&:to_s)
      unknown = grants.keys.map(&:to_s) - known
      raise ToolError, "Unexpected granted capability contract" if !unknown.empty?
      items = grants.map do |aspect, levels|
        raise ToolError, "Unexpected granted levels contract" if !levels.is_a?(Array) || !levels.all? { |level| level.is_a?(String) }
        definition = Authorization::CAPABILITIES.fetch(aspect.to_sym)
        levels.each do |level|
          raise ToolError, "Unexpected granted level contract" if !Array(definition[:levels]).include?(level.to_sym)
        end
        object_value("aspect" => aspect.to_s, "title" => definition[:title].to_s, "granted_levels" => levels)
      end
      object_value(
        "known_client_count" => summary["known_clients"],
        "authorized_client_count" => summary["authorized_clients"],
        "selective_grant_count" => summary["selective_grant_count"],
        "granted_capabilities" => items,
        "denied_request_count" => summary["denied_requests"],
        "remember_permissions" => summary["remember_permissions"] == true,
        "default_permissions_available" => summary["default_permissions_available"] == true,
        "default_permissions" => object_value(summary["default_permissions"] || {})
      )
    end

    PROGRAM_STATES = {
      "loaded" => "Loaded and running.",
      "not_loaded" => "Installed and compatible, but not currently loaded.",
      "unsupported_platform" => "The manifest does not support this operating system.",
      "developer_mode_only" => "Source program; it can load only in developer mode.",
      "not_signed" => "Application package is unsigned or its signature is not accepted.",
      "legacy" => "Legacy program format not supported as an Elten 3 application.",
      "incompatible" => "Manifest, API version or package contract is incompatible.",
      "invalid" => "Directory or package is not a valid Klangten program."
    }.freeze

    def diagnostic_program(entry)
      raise ToolError, "Unexpected local program entry contract" if !entry.is_a?(Hash)
      strings = %w[
        entry id name description raw_name raw_description main_language version author status
        install_type installation_source source_type main elten_api_version error
      ]
      strings.each do |name|
        value = entry[name]
        next if name == "error" && value == nil
        raise ToolError, "Unexpected local program #{name} contract" if !value.is_a?(String)
      end
      raise ToolError, "Unexpected local program build id contract" if entry["build_id"] != nil && !entry["build_id"].is_a?(String) && !entry["build_id"].is_a?(Integer)
      raise ToolError, "Unexpected local program load contract" if entry["loaded"] != true && entry["loaded"] != false
      raise ToolError, "Unexpected local program signature contract" if entry["signature_verified"] != true && entry["signature_verified"] != false
      raise ToolError, "Unexpected local program size contract" if !entry["size"].is_a?(Integer)
      platforms = entry["platforms"]
      raise ToolError, "Unexpected local program platforms contract" if !platforms.is_a?(Array) || !platforms.all? { |item| item.is_a?(String) || item.is_a?(Symbol) }
      %w[name_languages description_languages supported_languages].each do |field|
        values = entry[field]
        raise ToolError, "Unexpected local program #{field} contract" if !values.is_a?(Array) || !values.all? { |item| item.is_a?(String) || item.is_a?(Symbol) }
      end
      state = entry["status"]
      explanation = PROGRAM_STATES[state]
      raise ToolError, "Unexpected local program state contract" if explanation == nil
      source = entry["source_type"]
      raise ToolError, "Unexpected local program source format contract" if !["", "ruby", "eltenapp"].include?(source)
      object_value(
        "program_folder" => entry["entry"], "program_id" => entry["id"],
        "name" => entry["name"], "version" => entry["version"],
        "description" => entry["description"],
        "raw_name" => entry["raw_name"], "raw_description" => entry["raw_description"],
        "name_languages" => entry["name_languages"].map(&:to_s),
        "description_languages" => entry["description_languages"].map(&:to_s),
        "main_language" => entry["main_language"],
        "supported_languages" => entry["supported_languages"].map(&:to_s),
        "build_id" => (entry["build_id"] == nil ? nil : entry["build_id"].to_s),
        "author" => entry["author"], "state" => state,
        "state_explanation" => explanation, "is_loaded" => entry["loaded"],
        "install_type" => (entry["install_type"] == "" ? nil : entry["install_type"]),
        "installation_source" => (entry["installation_source"] == "" ? nil : entry["installation_source"]),
        "signature_verified" => entry["signature_verified"],
        "source_format" => ({ "" => nil, "ruby" => "source_directory", "eltenapp" => "application_package" }.fetch(source)),
        "entrypoint" => (entry["main"] == "" ? nil : entry["main"]),
        "required_elten_api_version" => (entry["elten_api_version"] == "" ? nil : entry["elten_api_version"]),
        "supported_platforms" => platforms.map(&:to_s), "size_bytes" => entry["size"],
        "problem" => (entry["error"].to_s == "" ? nil : entry["error"])
      )
    end

    def safe_configuration_value(value, name)
      return value if value == nil || value == true || value == false || value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float)
      return value.to_s if value.is_a?(Symbol)
      raise ToolError, "Unexpected safe configuration value for #{name}"
    end

    def klangten_info
      tool_response("client_information", "Returned Klangten client, runtime and local MCP information without authentication data.",
        "client" => object_value(
          "name" => "Klangten", "version" => Elten.version.to_s,
          "based_on_elten_version" => (Elten.respond_to?(:upstream_version) ? Elten.upstream_version.to_s : ""),
          "build_id" => Elten.build_id.to_s,
          "update_branch" => Elten.branch.to_s,
          "elten_api_version" => Programs.elten_api_version.to_s,
          "eltenlink_contract_version" => Programs.eltenlink_contract_version.to_s
        ),
        "runtime" => object_value("ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM),
        "developer_mode" => @bridge.developer_mode?, "mcp" => mcp_status_value)
    end

    def klangten_status
      logged_in = Session.logged?
      raise ToolError, "Unexpected login state contract" if logged_in != true && logged_in != false
      tool_response("client_status", logged_in ? "Klangten is signed in and its current local runtime state was returned." : "Klangten is not signed in; only local runtime state was returned.",
        "is_signed_in" => logged_in,
        "current_screen" => ($scene == nil ? nil : $scene.class.name.to_s),
        "loaded_program_count" => Programs.list.size,
        "runtime_thread_count" => Thread.list.size,
        "uptime_seconds" => ($start == nil ? nil : Time.now.to_i - $start.to_i),
        "mcp" => mcp_status_value)
    end

    # Klangten has no update server: only the server time is probed, version
    # information comes from Klangten::Config.
    def klangten_network_info
      cached = cached_network_info
      return cached if cached != nil
      os = Programs.platform_family
      client = @bridge.background_network_client
      server_time = EltenLink::System.server_time(client, :timeout => NETWORK_INFO_REQUEST_TIMEOUT)
      raise ToolError, "Unexpected server time contract" if !server_time.is_a?(Time)
      result = tool_response("network_information", "The Klango server is reachable; returned its public server time, the API address and the local Klangten version.",
        network_info_values(true, server_time, os))
      cache_network_info(result, NETWORK_INFO_CACHE_TTL)
    rescue EltenLink::Error
      result = tool_response("network_information", "The Klango server could not be reached within the short MCP probe timeout; only the API address and the local Klangten version were returned.",
        network_info_values(false, nil, os))
      cache_network_info(result, NETWORK_INFO_FAILURE_CACHE_TTL)
    end

    def network_info_values(reachable, server_time, os)
      {
        "is_reachable" => reachable, "server_time" => server_time,
        "api_url" => Klangten::Config.api_url, "operating_system" => os.to_s,
        "klangten_version" => Klangten::Config.version.to_s,
        "based_on_elten_version" => (Elten.respond_to?(:upstream_version) ? Elten.upstream_version.to_s : "")
      }
    end

    def cached_network_info
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @network_info_mutex.synchronize do
        return nil if @network_info_cache == nil || @network_info_cache[0] <= now
        @network_info_cache[1]
      end
    end

    def cache_network_info(value, ttl)
      expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ttl.to_f
      @network_info_mutex.synchronize { @network_info_cache = [expires_at, value] }
      value
    end

    def docs_search(query, limit)
      query = query.to_s.strip
      raise InvalidParamsError, "query is required" if query == ""
      matcher = query.downcase
      matches = []
      DOCUMENTS.each do |document|
        lines = document_text(document).lines
        lines.each_with_index do |line, index|
          next if !line.downcase.include?(matcher)
          from = [index - 1, 0].max
          to = [index + 1, lines.size - 1].min
          matches << object_value("document" => document, "line_number" => index + 1, "context" => lines[from..to].join.strip)
          break if matches.size >= limit.to_i
        end
        break if matches.size >= limit.to_i
      end
      tool_response("search_documentation", "Found #{matches.size} documentation matches for '#{query}'.",
        "query" => query, "matches" => matches, "count" => matches.size)
    end

    def configuration_snapshot
      definitions = {
        :language => ["interface_language", "Interface language"],
        :volume => ["main_volume", "Main interface volume"],
        :soundtheme => ["sound_theme", "Selected sound theme"],
        :soundthemeactivation => ["sound_theme_activation", "Sound-theme event sounds enabled"],
        :bgsounds => ["background_sounds", "Background interface sounds enabled"],
        :usepan => ["stereo_positioning", "Stereo interface positioning enabled"],
        :enablebraille => ["braille_output", "Braille output enabled"],
        :autoplay => ["audio_autoplay", "Audio autoplay policy"],
        :soundcard => ["audio_output_device", "Configured audio output device"],
        :microphone => ["microphone_input_device", "Configured microphone input device"]
      }
      settings = definitions.filter_map do |getter, (name, label)|
        next if !Configuration.respond_to?(getter)
        value = safe_configuration_value(Configuration.public_send(getter), name)
        object_value("name" => name, "label" => label, "value" => value)
      rescue Exception => e
        Log.warning("MCP safe configuration read failed for #{name}: #{e.class}") if defined?(Log)
        nil
      end
      tool_response("inspect_configuration", "Returned #{settings.size} named, non-secret configuration values. Authentication, MCP and low-level network settings are excluded.",
        "settings" => settings, "count" => settings.size,
        "excluded" => "Authentication, auto-login, MCP configuration and permissions, and low-level network transport settings")
    end

    def reject_current_program_unload(entry)
      runtime = Programs.current_runtime
      if runtime != nil && runtime.entry_id.to_s == entry.to_s
        raise ToolError, "The program serving this MCP request cannot unload or reload itself. Apply source changes now and restart Klangten to activate them."
      end
    end

    def document_text(document)
      text = Documentation.document(document, @bridge)
      raise ToolError, "Unexpected bundled document contract" if !text.is_a?(String)
      text
    end

    def redact_diagnostics(text)
      redacted = text.lines.map do |line|
        if line.match?(/\A(Session hash|Command line|ARGV):/i)
          "#{line.split(":", 2)[0]}: [redacted]\r\n"
        elsif line.match?(/\A(Root|Runtime bin|Data|Apps root|Apps source|Sound themes|Extras|Temp|Log file|Config file|Executable|Ruby executable|Program file|Working directory):/i)
          "#{line.split(":", 2)[0]}: [redacted path]\r\n"
        else
          line
        end
      end.join
      redact_secrets(redacted)
    end

    def redact_secrets(text)
      value = text.to_s.dup
      value.gsub!(/(Bearer\s+)[A-Za-z0-9._~+\/-]+/i, '\\1[redacted]')
      value.gsub!(/(Authorization\s*:\s*)[^\r\n]+/i, '\\1[redacted]')
      value.gsub!(/((?:Cookie|Set-Cookie)\s*:\s*)[^\r\n]+/i, '\\1[redacted]')
      secret_names = "token|password|passwd|client[_-]?key|login[_-]?key|session|auth(?:orization)?|cookie|secret"
      value.gsub!(/([\"']?(?:#{secret_names})[\"']?\s*[:=]\s*)(\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}\]]+)/i, '\\1[redacted]')
      value.gsub!(/([?&](?:#{secret_names})=)[^&#\s]+/i, '\\1[redacted]')
      value.gsub!(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, "[redacted email]")
      value
    end

    def program_syntax_check(identifier, paths)
      files = @workspace.list_files(identifier, "", true)["files"].select { |file| file["type"] == "file" && file["path"].end_with?(".rb") }.map { |file| file["path"] }
      if paths.is_a?(Array) && !paths.empty?
        requested = paths.map(&:to_s)
        files.select! { |path| requested.include?(path) }
        missing = requested - files
        raise InvalidParamsError, "Ruby files not found: #{missing.join(", ")}" if !missing.empty?
      end
      checks = files.map do |path|
        source = @workspace.read_file(identifier, path, "utf8")
        begin
          RubyVM::InstructionSequence.compile(source["content"], path, path, 1)
          { "path" => path, "ok" => true }
        rescue SyntaxError => e
          { "path" => path, "ok" => false, "error" => e.message.to_s }
        end
      end
      { "program" => @workspace.inspect_entry(identifier)["entry"], "ok" => checks.all? { |check| check["ok"] }, "files" => checks }
    end

    def loaded_runtime(identifier)
      entry, cls = loaded_program_class(identifier)
      [entry, cls.app_runtime]
    end

    def loaded_program_class(identifier)
      entry = @workspace.inspect_entry(identifier)["entry"]
      cls = Programs.list.find { |program| program.app_runtime != nil && program.app_runtime.entry_id == entry }
      raise ToolError, "Program is not loaded" if cls == nil
      [entry, cls]
    end

    def program_server_schema_snapshot(identifier)
      entry, cls = loaded_program_class(identifier)
      definition = cls.server_app_definition
      raise ToolError, "Program does not declare server_app" if definition == nil
      signed_in_account = current_schema_account(:required => false)
      account_question = if signed_in_account == nil
        "Klangten is not signed in. Sign in to the developer account that should own this application, inspect again, then ask for confirmation."
      else
        "Is the currently signed-in Klango account \"#{signed_in_account}\" your own developer account, and should it permanently own this application?"
      end
      {
        "program" => entry,
        "program_id" => cls.app_uuid.to_s,
        "server_app_uuid" => definition.uuid,
        "registered_in_source" => definition.uuid != nil,
        "tables_protected" => definition.protected?,
        "notifications_enabled" => definition.notifications?,
        "tables" => definition.tables,
        "table_names" => definition.tables.keys.map(&:to_s),
        "server_contacted" => false,
        "signed_in_account" => signed_in_account,
        "mandatory_account_question" => account_question,
        "policy" => "The agent may create and edit the local server application declaration, including tables and notification support. It may register or update it only after the user explicitly confirms this exact signed-in account. For a test, secondary, wrong or uncertain account, do not apply; explain how the user can sign in to the intended developer account and run the prepared command in Klangten's developer Console."
      }
    end

    def program_server_schema_prepare(identifier, action)
      snapshot = program_server_schema_snapshot(identifier)
      if action == "register" && snapshot["registered_in_source"]
        raise ToolError, "The declaration already has a server application UUID; prepare action=update"
      end
      if action == "update" && !snapshot["registered_in_source"]
        raise ToolError, "The declaration has no server application UUID; prepare action=register first"
      end
      entry = snapshot["program"]
      finder = "program = Programs.list.find { |klass| klass.app_runtime && klass.app_runtime.entry_id == #{entry.dump} }"
      operation = if action == "register"
        "uuid = program.register_server_app!\nputs uuid"
      else
        "program.update_server_schema!\nputs program.server_app_uuid"
      end
      snapshot.merge(
        "action" => action,
        "server_contacted" => false,
        "console_path" => "Main menu -> Console (developer mode)",
        "console_command" => "#{finder}\nraise \"Program is not loaded\" if program == nil\n#{operation}",
        "human_must_execute" => true,
        "next_step" => action == "register" ? "After the Console returns a UUID, persist it in server_app(uuid: ...), reload, and use update for later schema changes." : "Run after reviewing the declared table diff while signed in to the intended developer account."
      )
    end

    def program_server_schema_apply(identifier, action, confirmed_account, account_confirmation)
      raise ToolError, "Explicit developer-account confirmation is required" if account_confirmation != "confirmed_own_developer_account"
      current_account = current_schema_account
      if confirmed_account.to_s.casecmp(current_account) != 0
        raise ToolError, "The signed-in Klango account changed or does not match the account confirmed by the user; inspect and ask again"
      end

      snapshot = program_server_schema_snapshot(identifier)
      if action == "register" && snapshot["registered_in_source"]
        raise ToolError, "The declaration already has a server application UUID; use action=update"
      end
      if action == "update" && !snapshot["registered_in_source"]
        raise ToolError, "The declaration has no server application UUID; use action=register first"
      end

      _entry, cls = loaded_program_class(identifier)
      if action == "register"
        uuid = cls.register_server_app!
        snapshot.merge(
          "action" => action,
          "server_contacted" => true,
          "signed_in_account" => current_account,
          "server_app_uuid" => uuid.to_s,
          "registered" => true,
          "source_edit_required" => true,
          "next_step" => "Edit server_app(uuid: ...) in the program source with this UUID, reload, inspect, and keep future changes on action=update."
        )
      else
        cls.update_server_schema!
        snapshot.merge(
          "action" => action,
          "server_contacted" => true,
          "signed_in_account" => current_account,
          "updated" => true,
          "next_step" => "The declared schema was updated for the confirmed developer account; inspect and test table access."
        )
      end
    end

    def current_schema_account(required: true)
      if !defined?(Session) || !Session.logged?
        raise ToolError, "Klangten is not signed in; sign in to the intended developer account first" if required
        return nil
      end
      account = Session.name.to_s
      if account == ""
        raise ToolError, "Klangten did not expose the signed-in account name" if required
        return nil
      end
      account
    end

    def evaluate(code, filename, binding_value, program_runtime = nil)
      stdout = StringIO.new
      stderr = StringIO.new
      old_stdout = $stdout
      old_stderr = $stderr
      previous_runtime = Thread.current[:elten_program_runtime]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        $stdout = stdout
        $stderr = stderr
        Thread.current[:elten_program_runtime] = program_runtime if program_runtime != nil
        result = binding_value.eval(code.to_s, filename.to_s, 1)
        {
          "ok" => true,
          "result_class" => result.class.name.to_s,
          "result" => safe_inspect(result),
          "stdout" => stdout.string,
          "stderr" => stderr.string,
          "duration_ms" => elapsed_ms(started),
          "warning" => "Evaluation ran in-process without a sandbox or reliable timeout."
        }
      rescue Exception => e
        {
          "ok" => false,
          "exception_class" => e.class.name.to_s,
          "message" => e.message.to_s,
          "backtrace" => Array(e.backtrace).first(100),
          "stdout" => stdout.string,
          "stderr" => stderr.string,
          "duration_ms" => elapsed_ms(started),
          "__is_error" => true
        }
      ensure
        Thread.current[:elten_program_runtime] = previous_runtime
        $stdout = old_stdout
        $stderr = old_stderr
      end
    end

    def safe_inspect(value)
      text = value.inspect
      return text if text.bytesize <= 1_000_000
      text.byteslice(0, 1_000_000).to_s.force_encoding(Encoding::UTF_8).scrub + "..."
    rescue Exception => e
      "#<inspect failed: #{e.class}: #{e.message}>"
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
    end
  end
end
