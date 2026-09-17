# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: klangten:// resources and rebranded prompts.

require "json"

module EltenMCP
  class ResourceCatalog
    def initialize(registry, bridge)
      @registry = registry
      @bridge = bridge
    end

    def list(developer_mode)
      resources = [
        resource("klangten://info", "Klangten information", "Version, runtime and MCP mode", "application/json", :basic),
        resource("klangten://status", "Klangten status", "Current non-secret client state", "application/json", :basic)
      ]
      ToolCatalog::DOCUMENTS.each do |document|
        description = case document
        when "programming" then "Current model-facing guide and templates for exemplary Klangten applications"
        when "api_overview" then "Compact map of controls, runners, timers, sound, tables and other Klangten APIs"
        else "Bundled Klangten documentation"
        end
        resources << resource("klangten://docs/#{document}", "Klangten document: #{document}", description, "text/plain", :basic)
      end
      resources << resource("klangten://diagnostics", "Klangten diagnostics", "Redacted diagnostic report", "text/plain", :diagnostics)
      resources << resource("klangten://logs/recent", "Recent Klangten logs", "Recent logs with basic credential redaction", "text/plain", :diagnostics)
      resources << resource("klangten://programs", "Klangten programs", "Installed program manifests and states", "application/json", :developer) if developer_mode
      resources
    end

    def read(uri)
      case uri.to_s
      when "klangten://info"
        [Authorization.requirement(:basic, :read), json_tool("klangten_info", {})]
      when "klangten://status"
        [Authorization.requirement(:basic, :read), json_tool("klangten_status", {})]
      when "klangten://programs"
        [Authorization.requirement(:developer, :full), json_tool("programs_list", {})]
      when "klangten://diagnostics"
        [Authorization.requirement(:diagnostics, :read), @registry.call(@registry.find("diagnostics_create"), {})["report"].to_s]
      when "klangten://logs/recent"
        [Authorization.requirement(:diagnostics, :read), @registry.call(@registry.find("log_tail"), { "limit" => 200 })["log"].to_s]
      else
        match = uri.to_s.match(/\Aklangten:\/\/docs\/([a-z0-9_]+)\z/)
        if match != nil && ToolCatalog::DOCUMENTS.include?(match[1])
          text = Documentation.document(match[1], @bridge)
          raise ToolError, "Unexpected bundled document contract" if !text.is_a?(String)
          return [Authorization.requirement(:basic, :read), text]
        end
        raise InvalidParamsError, "Unknown resource URI: #{uri}"
      end
    end

    def permission_for(uri)
      case uri.to_s
      when "klangten://diagnostics", "klangten://logs/recent"
        Authorization.requirement(:diagnostics, :read)
      when "klangten://programs"
        Authorization.requirement(:developer, :full)
      else
        Authorization.requirement(:basic, :read)
      end
    end

    def mime_type(uri)
      uri.to_s.start_with?("klangten://docs/", "klangten://diagnostics", "klangten://logs/") ? "text/plain" : "application/json"
    end

    private

    def resource(uri, name, description, mime_type, aspect)
      permission = Authorization.requirement(aspect)
      {
        "uri" => uri, "name" => name, "description" => description, "mimeType" => mime_type,
        "_meta" => { "klangten/permission" => { "aspect" => permission[:aspect].to_s, "level" => permission[:level].to_s } }
      }
    end

    def json_tool(name, arguments)
      JSON.pretty_generate(@registry.call(@registry.find(name), arguments))
    end
  end

  class PromptCatalog
    def list(developer_mode)
      prompts = [
        {
          "name" => "troubleshoot_klangten",
          "title" => "Troubleshoot Klangten",
          "description" => "Investigate an Klangten issue using status, documentation and optional diagnostics.",
          "arguments" => [{ "name" => "problem", "description" => "Problem reported by the user", "required" => true }]
        }
      ]
      if developer_mode
        prompts << {
          "name" => "develop_klangten_program",
          "title" => "Develop an Klangten program",
          "description" => "Develop an exemplary voice-driven Klangten program from current guidance, sources and templates.",
          "arguments" => [
            { "name" => "program", "description" => "Program folder, storage id or UUID", "required" => true },
            { "name" => "task", "description" => "Requested change", "required" => true }
          ]
        }
      end
      prompts
    end

    def get(name, arguments)
      arguments = {} if !arguments.is_a?(Hash)
      case name.to_s
      when "troubleshoot_klangten"
        problem = arguments["problem"].to_s
        permission = Authorization.requirement(:basic, :read)
        text = "Investigate this Klangten problem: #{problem}\nStart with klangten_status and relevant bundled documentation. Request diagnostics/read only if needed. Never request or expose the session token."
      when "develop_klangten_program"
        permission = Authorization.requirement(:developer, :full)
        text = <<~TEXT
          Work on Klangten program #{arguments["program"]}: #{arguments["task"]}

          First read the bundled docs_get(document=programming) and docs_get(document=api_overview), then read the complete program—not only the manifest or one affected file. Current source definitions and call sites are authoritative: inspect them through klangten_sources_list/klangten_source_read when available. Do not assume a local docs/ directory exists. If launcher sources are unavailable and browsing is permitted, inspect the matching upstream Elten sources at https://github.com/dawidpieper/elten3 (Klangten modifies them, so check for differences); repository documentation is only supporting context. Klangten is voice-driven and has no graphical interface: design speech, Braille, focus, keyboard and sound as the native interaction model. Prefer program_main, focused modules, Program data/resource/sound/server helpers, Form#wait, Tasks.run and Runner; treat feature-owned loop_update and Program#main as legacy. For cross-user realtime hints, inspect Program#signal/#signaled and its active-scene delivery limits; do not confuse it with Program.on host events or durable server tables.

          Choose signal for small transient hints. LiveSessions is an advanced API for message exchange, chat contexts and games that do not require immediate UDP communication. Communication is an advanced low-level API for control over realtime binary transmission, including reliable/unreliable delivery and UDP. Read api_overview for the capability map, then inspect the corresponding source.

          Use base_hash for edits, syntax-check all Ruby files, reload after changes, inspect logs on failure, test error/cancellation/focus/resource paths, and explain that soft reload cannot undo threads or global patches. If this is the MCP program serving the request, restart Klangten instead of trying to unload or reload it.

          Generate and edit local server_app declarations when the task requires them. Before a server register or update, call program_server_schema_inspect, ask whether its exact signed_in_account is the user's developer account which should own the application, and wait for an explicit answer. After yes, program_server_schema_apply may execute with the exact account and confirmation token; persist a returned registration UUID in source yourself. For a test, secondary, wrong or uncertain account, do not apply: explain how the user can switch accounts and personally execute the command from program_server_schema_prepare in Klangten's developer Console.
        TEXT
      else
        raise InvalidParamsError, "Unknown prompt: #{name}"
      end
      [permission, { "description" => name.to_s, "messages" => [{ "role" => "user", "content" => { "type" => "text", "text" => text } }] }]
    end
  end
end
