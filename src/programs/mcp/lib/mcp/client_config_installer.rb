# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: client entries are named klangten, so Elten's MCP entries are never touched.

require "json"
require "securerandom"
require "uri"

module EltenMCP
  class ClientConfigInstaller
    # Klangten: own entry name, so an existing "elten" entry of a normal Elten MCP is never touched.
    SERVER_NAME = "klangten"
    MAX_CONFIG_BYTES = 8 * 1024 * 1024
    OLD_AUTHORIZATION = /\ABearer [0-9a-f]{64}\z/i.freeze

    TomlAssignment = Struct.new(:key_path, :value, :value_start, :value_end)
    TomlTable = Struct.new(:path, :array, :assignments)
    YamlLine = Struct.new(:number, :start_offset, :body_end, :indent, :key, :value, :value_start, :value_end, :significant, :kind)
    YamlGroup = Struct.new(:key, :line, :start_index, :end_index)

    class ConfigError < Error
    end

    def initialize(claude_path: nil, codex_path: nil, antigravity_path: nil, hermes_path: nil)
      @claude_path = claude_path
      @codex_path = codex_path
      @antigravity_path = antigravity_path
      @hermes_path = hermes_path
    end

    def install(target, url:, authorization:)
      endpoint = validated_endpoint(url)
      header = validated_authorization(authorization)
      case target.to_sym
      when :claude
        install_claude(endpoint, header)
      when :codex
        install_codex(endpoint, header)
      when :antigravity
        install_antigravity(endpoint, header)
      when :hermes
        install_hermes(endpoint, header)
      else
        raise ConfigError, "Unsupported MCP client configuration target"
      end
    end

    def claude_config_path
      @claude_path || File.join(home_directory, ".claude.json")
    end

    def codex_config_path
      return @codex_path if @codex_path != nil
      root = ENV["CODEX_HOME"].to_s.strip
      root = File.join(home_directory, ".codex") if root == ""
      File.join(root, "config.toml")
    end

    def antigravity_config_path
      @antigravity_path || File.join(home_directory, ".gemini", "config", "mcp_config.json")
    end

    def hermes_config_path
      @hermes_path || File.join(home_directory, ".hermes", "config.yaml")
    end

    private

    def install_claude(endpoint, authorization)
      path = claude_config_path
      original = read_config(path, "Claude Code")
      document = parse_json_object(original, "Claude Code")
      destination = document["mcpServers"]
      if destination != nil && !destination.is_a?(Hash)
        raise ConfigError, "Claude Code config has a non-object mcpServers value; it was not changed"
      end

      maps = collect_mcp_maps(document)
      maps.each do |location, servers|
        servers.each do |name, entry|
          raise ConfigError, "Claude Code MCP server #{name.inspect} is not an object; config was not changed" if !entry.is_a?(Hash)
          if name.to_s.downcase == SERVER_NAME && (location != "$" || name.to_s != SERVER_NAME)
            raise ConfigError, "Claude Code already contains an Klangten-named MCP server outside the exact user entry; config was not changed"
          end
          next if !entry.key?("url")
          raise ConfigError, "Claude Code MCP server #{name.inspect} has a non-string URL; config was not changed" if !entry["url"].is_a?(String)
          if canonical_endpoint(entry["url"]) == endpoint[:canonical] && (location != "$" || name.to_s != SERVER_NAME)
            raise ConfigError, "Claude Code already contains an MCP server with this address under #{name.inspect}; config was not changed"
          end
        end
      end

      editor = JsonObjectEditor.new(original)
      root_members = editor.root_members
      if destination == nil
        updated = editor.insert_member(root_members, "mcpServers", { SERVER_NAME => claude_entry(endpoint[:url], authorization) })
        status = "added"
      elsif destination.key?(SERVER_NAME)
        old_header = valid_existing_claude_entry(destination[SERVER_NAME], endpoint)
        raise ConfigError, "Claude Code already has the current Klangten MCP server; config was not changed" if old_header == authorization
        raise ConfigError, "Claude Code Klangten entry does not contain a recognizable previous bearer key; config was not changed" if !old_authorization?(old_header)
        servers_member = member_named(root_members, "mcpServers")
        server_members = editor.object_members(servers_member.value_start)
        elten_member = member_named(server_members, SERVER_NAME)
        entry_members = editor.object_members(elten_member.value_start)
        headers_member = member_named(entry_members, "headers")
        header_members = editor.object_members(headers_member.value_start)
        authorization_member = member_named(header_members, "Authorization")
        updated = editor.replace(authorization_member.value_start, authorization_member.value_end, JSON.generate(authorization))
        status = "updated"
      else
        destination.each_key do |name|
          if name.to_s.downcase == SERVER_NAME
            raise ConfigError, "Claude Code already contains an MCP server whose name differs from klangten only by case; config was not changed"
          end
        end
        servers_member = member_named(root_members, "mcpServers")
        server_members = editor.object_members(servers_member.value_start)
        updated = editor.insert_member(server_members, SERVER_NAME, claude_entry(endpoint[:url], authorization))
        status = "added"
      end
      write_config(path, original, updated)
      { "client" => "Claude Code", "status" => status, "path" => path }
    end

    def install_antigravity(endpoint, authorization)
      path = antigravity_config_path
      original = read_config(path, "Antigravity")
      document = parse_json_object(original, "Antigravity")
      destination = document["mcpServers"]
      if destination != nil && !destination.is_a?(Hash)
        raise ConfigError, "Antigravity config has a non-object mcpServers value; it was not changed"
      end

      maps = collect_mcp_maps(document, "$", [], "Antigravity")
      maps.each do |location, servers|
        servers.each do |name, entry|
          raise ConfigError, "Antigravity MCP server #{name.inspect} is not an object; config was not changed" if !entry.is_a?(Hash)
          if name.to_s.downcase == SERVER_NAME && (location != "$" || name.to_s != SERVER_NAME)
            raise ConfigError, "Antigravity already contains an Klangten-named MCP server outside the exact global entry; config was not changed"
          end
          next if !entry.key?("serverUrl")
          raise ConfigError, "Antigravity MCP server #{name.inspect} has a non-string serverUrl; config was not changed" if !entry["serverUrl"].is_a?(String)
          if canonical_endpoint(entry["serverUrl"]) == endpoint[:canonical] && (location != "$" || name.to_s != SERVER_NAME)
            raise ConfigError, "Antigravity already contains an MCP server with this address under #{name.inspect}; config was not changed"
          end
        end
      end

      editor = JsonObjectEditor.new(original)
      root_members = editor.root_members
      if destination == nil
        updated = editor.insert_member(root_members, "mcpServers", { SERVER_NAME => antigravity_entry(endpoint[:url], authorization) })
        status = "added"
      elsif destination.key?(SERVER_NAME)
        old_header = valid_existing_antigravity_entry(destination[SERVER_NAME], endpoint)
        raise ConfigError, "Antigravity already has the current Klangten MCP server; config was not changed" if old_header == authorization
        raise ConfigError, "Antigravity Klangten entry does not contain a recognizable previous bearer key; config was not changed" if !old_authorization?(old_header)
        servers_member = member_named(root_members, "mcpServers")
        server_members = editor.object_members(servers_member.value_start)
        elten_member = member_named(server_members, SERVER_NAME)
        entry_members = editor.object_members(elten_member.value_start)
        headers_member = member_named(entry_members, "headers")
        header_members = editor.object_members(headers_member.value_start)
        authorization_member = member_named(header_members, "Authorization")
        updated = editor.replace(authorization_member.value_start, authorization_member.value_end, JSON.generate(authorization))
        status = "updated"
      else
        destination.each_key do |name|
          if name.to_s.downcase == SERVER_NAME
            raise ConfigError, "Antigravity already contains an MCP server whose name differs from klangten only by case; config was not changed"
          end
        end
        servers_member = member_named(root_members, "mcpServers")
        server_members = editor.object_members(servers_member.value_start)
        updated = editor.insert_member(server_members, SERVER_NAME, antigravity_entry(endpoint[:url], authorization))
        status = "added"
      end
      write_config(path, original, updated)
      { "client" => "Antigravity", "status" => status, "path" => path }
    end

    def install_codex(endpoint, authorization)
      path = codex_config_path
      original = read_config(path, "Codex")
      tables = scan_toml(original)
      server_tables = tables.select { |table| table.path[0] == "mcp_servers" }
      server_tables.each do |table|
        raise ConfigError, "Codex config uses an unsupported mcp_servers table shape; it was not changed" if table.array || table.path.size < 2
      end
      grouped = server_tables.group_by { |table| table.path[1] }
      grouped.each do |name, group|
        main_tables = group.select { |table| table.path.size == 2 }
        raise ConfigError, "Codex MCP server #{name.inspect} has no single main table; config was not changed" if main_tables.size != 1
        url_assignment = assignment_named(main_tables[0], "url", :required => false)
        if url_assignment != nil
          existing_url, = toml_string(url_assignment)
          if canonical_endpoint(existing_url) == endpoint[:canonical] && name != SERVER_NAME
            raise ConfigError, "Codex already contains an MCP server with this address under #{name.inspect}; config was not changed"
          end
        end
        if name.to_s.downcase == SERVER_NAME && name != SERVER_NAME
          raise ConfigError, "Codex already contains an MCP server whose name differs from klangten only by case; config was not changed"
        end
      end

      if grouped.key?(SERVER_NAME)
        old_header, start_position, end_position = valid_existing_codex_entry(grouped[SERVER_NAME], endpoint)
        raise ConfigError, "Codex already has the current Klangten MCP server; config was not changed" if old_header == authorization
        raise ConfigError, "Codex Klangten entry does not contain a recognizable previous bearer key; config was not changed" if !old_authorization?(old_header)
        updated = original.byteslice(0, start_position) + toml_quote(authorization) + original.byteslice(end_position, original.bytesize - end_position).to_s
        status = "updated"
      else
        separator = original.end_with?("\n\n") || original == "" ? "" : (original.end_with?("\n") ? "\n" : "\n\n")
        updated = original + separator +
          "[mcp_servers.#{SERVER_NAME}]\n" +
          "url = #{toml_quote(endpoint[:url])}\n" +
          "http_headers = { Authorization = #{toml_quote(authorization)} }\n"
        status = "added"
      end
      write_config(path, original, updated)
      { "client" => "Codex", "status" => status, "path" => path }
    end

    def install_hermes(endpoint, authorization)
      path = hermes_config_path
      original = read_config(path, "Hermes")
      yaml = scan_yaml_document(original, "Hermes")
      if yaml[:empty_root] != nil
        updated = replace_yaml_empty_mapping(original, yaml[:empty_root], hermes_root_block(endpoint[:url], authorization, original), "Hermes config root")
        status = "added"
      else
        root_groups = yaml[:root_groups]
        mcp_group = root_groups.find { |group| group.key == "mcp_servers" }
        if mcp_group == nil
          updated = insert_yaml_block(original, original.bytesize, hermes_root_block(endpoint[:url], authorization, original))
          status = "added"
          write_config(path, original, updated)
          return { "client" => "Hermes", "status" => status, "path" => path }
        end

        if mcp_group.line.value == "{}"
          updated = replace_yaml_empty_mapping(original, mcp_group.line, yaml_newline(original) + hermes_server_block(endpoint[:url], authorization, original), "Hermes mcp_servers")
          status = "added"
          write_config(path, original, updated)
          return { "client" => "Hermes", "status" => status, "path" => path }
        end
        raise ConfigError, "Hermes config has a non-mapping mcp_servers value; it was not changed" if mcp_group.line.value != ""

        server_groups = yaml_mapping_groups(yaml[:lines], mcp_group.start_index + 1, mcp_group.end_index, 2, "Hermes mcp_servers")
        server_groups.each do |server|
          raise ConfigError, "Hermes MCP server #{server.key.inspect} is not a block mapping; config was not changed" if server.line.value != ""
          if server.key.downcase == SERVER_NAME && server.key != SERVER_NAME
            raise ConfigError, "Hermes already contains an MCP server whose name differs from klangten only by case; config was not changed"
          end
          fields = yaml_mapping_groups(yaml[:lines], server.start_index + 1, server.end_index, 4, "Hermes MCP server #{server.key.inspect}")
          url_field = fields.find { |field| field.key == "url" }
          next if url_field == nil
          existing_url = yaml_group_scalar(yaml[:lines], url_field, "Hermes MCP server URL")
          if canonical_endpoint(existing_url) == endpoint[:canonical] && server.key != SERVER_NAME
            raise ConfigError, "Hermes already contains an MCP server with this address under #{server.key.inspect}; config was not changed"
          end
        end

        elten_group = server_groups.find { |server| server.key == SERVER_NAME }
        if elten_group != nil
          old_header, header_line = valid_existing_hermes_entry(yaml[:lines], elten_group, endpoint)
          raise ConfigError, "Hermes already has the current Klangten MCP server; config was not changed" if old_header == authorization
          raise ConfigError, "Hermes Klangten entry does not contain a recognizable previous bearer key; config was not changed" if !old_authorization?(old_header)
          updated = replace_yaml_line_value(original, header_line, JSON.generate(authorization), "Hermes Authorization header")
          status = "updated"
        else
          position = yaml_group_end_offset(original, yaml[:lines], mcp_group)
          updated = insert_yaml_block(original, position, hermes_server_block(endpoint[:url], authorization, original))
          status = "added"
        end
      end
      write_config(path, original, updated)
      { "client" => "Hermes", "status" => status, "path" => path }
    end

    def valid_existing_claude_entry(entry, endpoint)
      raise ConfigError, "Claude Code Klangten entry is not an object; config was not changed" if !entry.is_a?(Hash)
      allowed = %w[headers type url]
      raise ConfigError, "Claude Code Klangten entry has unexpected fields; config was not changed" if entry.keys.map(&:to_s).sort != allowed
      raise ConfigError, "Claude Code Klangten entry is not a Streamable HTTP server; config was not changed" if !%w[http streamable-http].include?(entry["type"].to_s)
      raise ConfigError, "Claude Code Klangten entry points to another address; config was not changed" if !entry["url"].is_a?(String) || canonical_endpoint(entry["url"]) != endpoint[:canonical]
      headers = entry["headers"]
      raise ConfigError, "Claude Code Klangten headers are not a clean object; config was not changed" if !headers.is_a?(Hash) || headers.keys.map(&:to_s) != ["Authorization"] || !headers["Authorization"].is_a?(String)
      headers["Authorization"]
    end

    def valid_existing_antigravity_entry(entry, endpoint)
      raise ConfigError, "Antigravity Klangten entry is not an object; config was not changed" if !entry.is_a?(Hash)
      allowed = %w[headers serverUrl]
      raise ConfigError, "Antigravity Klangten entry has unexpected fields; config was not changed" if entry.keys.map(&:to_s).sort != allowed
      raise ConfigError, "Antigravity Klangten entry points to another address; config was not changed" if !entry["serverUrl"].is_a?(String) || canonical_endpoint(entry["serverUrl"]) != endpoint[:canonical]
      headers = entry["headers"]
      raise ConfigError, "Antigravity Klangten headers are not a clean object; config was not changed" if !headers.is_a?(Hash) || headers.keys.map(&:to_s) != ["Authorization"] || !headers["Authorization"].is_a?(String)
      headers["Authorization"]
    end

    def valid_existing_hermes_entry(lines, entry, endpoint)
      fields = yaml_mapping_groups(lines, entry.start_index + 1, entry.end_index, 4, "Hermes Klangten entry")
      raise ConfigError, "Hermes Klangten entry has unexpected fields; config was not changed" if fields.map(&:key).sort != %w[headers url]
      url_field = fields.find { |field| field.key == "url" }
      existing_url = yaml_group_scalar(lines, url_field, "Hermes Klangten URL")
      raise ConfigError, "Hermes Klangten entry points to another address; config was not changed" if canonical_endpoint(existing_url) != endpoint[:canonical]
      headers_field = fields.find { |field| field.key == "headers" }
      raise ConfigError, "Hermes Klangten headers are not a clean mapping; config was not changed" if headers_field.line.value != ""
      header_fields = yaml_mapping_groups(lines, headers_field.start_index + 1, headers_field.end_index, 6, "Hermes Klangten headers")
      raise ConfigError, "Hermes Klangten headers must contain only Authorization; config was not changed" if header_fields.map(&:key) != ["Authorization"]
      header_field = header_fields[0]
      [yaml_group_scalar(lines, header_field, "Hermes Authorization header"), header_field.line]
    end

    def valid_existing_codex_entry(tables, endpoint)
      main = tables.find { |table| table.path.size == 2 }
      nested = tables.reject { |table| table.equal?(main) }
      url_assignment = assignment_named(main, "url")
      existing_url, = toml_string(url_assignment)
      raise ConfigError, "Codex Klangten entry points to another address; config was not changed" if canonical_endpoint(existing_url) != endpoint[:canonical]

      inline = assignment_named(main, "http_headers", :required => false)
      if inline != nil
        raise ConfigError, "Codex Klangten entry mixes inline and nested headers; config was not changed" if !nested.empty?
        expected_keys = main.assignments.map { |assignment| assignment.key_path }
        raise ConfigError, "Codex Klangten entry has unexpected fields; config was not changed" if expected_keys.sort != [["http_headers"], ["url"]].sort
        return parse_inline_authorization(inline)
      end

      raise ConfigError, "Codex Klangten entry does not have one clean http_headers table; config was not changed" if nested.size != 1 || nested[0].path != ["mcp_servers", SERVER_NAME, "http_headers"]
      raise ConfigError, "Codex Klangten entry has unexpected fields; config was not changed" if main.assignments.map(&:key_path) != [["url"]]
      headers = nested[0]
      raise ConfigError, "Codex Klangten HTTP headers table is not clean; config was not changed" if headers.assignments.size != 1 || headers.assignments[0].key_path != ["Authorization"]
      toml_string(headers.assignments[0])
    end

    def claude_entry(url, authorization)
      {
        "type" => "http",
        "url" => url,
        "headers" => { "Authorization" => authorization }
      }
    end

    def antigravity_entry(url, authorization)
      {
        "serverUrl" => url,
        "headers" => { "Authorization" => authorization }
      }
    end

    def hermes_server_block(url, authorization, text)
      newline = yaml_newline(text)
      "  #{SERVER_NAME}:#{newline}" +
        "    url: #{JSON.generate(url)}#{newline}" +
        "    headers:#{newline}" +
        "      Authorization: #{JSON.generate(authorization)}#{newline}"
    end

    def hermes_root_block(url, authorization, text)
      "mcp_servers:#{yaml_newline(text)}" + hermes_server_block(url, authorization, text)
    end

    def collect_mcp_maps(value, location = "$", result = [], label = "Claude Code")
      return result if !value.is_a?(Hash) && !value.is_a?(Array)
      if value.is_a?(Hash)
        value.each do |key, item|
          child = location + "." + key.to_s
          if key.to_s == "mcpServers"
            raise ConfigError, "#{label} config has a non-object mcpServers value at #{child}; it was not changed" if !item.is_a?(Hash)
            result << [location, item]
          else
            collect_mcp_maps(item, child, result, label)
          end
        end
      else
        value.each_with_index { |item, index| collect_mcp_maps(item, "#{location}[#{index}]", result, label) }
      end
      result
    end

    def scan_yaml_document(text, label)
      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      raise ConfigError, "#{label} config is not valid UTF-8; it was not changed" if !utf8.valid_encoding?
      lines = []
      offset = 0
      utf8.each_line.with_index do |raw, index|
        lines << scan_yaml_line(raw, index + 1, offset, label)
        offset += raw.bytesize
      end
      significant = lines.select(&:significant)
      raise ConfigError, "#{label} config is empty; it was not changed" if significant.empty?
      if significant.size == 1 && significant[0].indent == 0 && significant[0].kind == :empty_mapping
        return { :lines => lines, :root_groups => [], :empty_root => significant[0] }
      end
      root_groups = yaml_mapping_groups(lines, 0, lines.size, 0, "#{label} config root")
      raise ConfigError, "#{label} config root is not a mapping; it was not changed" if root_groups.empty?
      { :lines => lines, :root_groups => root_groups, :empty_root => nil }
    end

    def scan_yaml_line(raw, number, start_offset, label)
      body = raw.sub(/\r?\n\z/, "")
      body_end = start_offset + body.bytesize
      indent = 0
      indent += 1 while indent < body.bytesize && body.getbyte(indent) == 32
      if indent < body.bytesize && body.getbyte(indent) == 9
        remainder = body.byteslice(indent, body.bytesize - indent).to_s
        raise ConfigError, "#{label} config uses a tab for YAML indentation on line #{number}; it was not changed" if remainder.strip != ""
      end
      visible_end = yaml_visible_end(body, number, label)
      visible_end -= 1 while visible_end > indent && [9, 32].include?(body.getbyte(visible_end - 1))
      content = body.byteslice(indent, visible_end - indent).to_s
      return YamlLine.new(number, start_offset, body_end, indent, nil, "", body_end, body_end, false, :blank) if content == ""
      raise ConfigError, "#{label} config uses unsupported YAML indentation on line #{number}; it was not changed" if indent.odd?
      if ["---", "..."].include?(content) || content.start_with?("%")
        raise ConfigError, "#{label} config uses YAML documents or directives that cannot be edited safely; it was not changed"
      end
      if yaml_forbidden_syntax?(content)
        raise ConfigError, "#{label} config uses YAML aliases, anchors, or tags that cannot be edited safely; it was not changed"
      end
      if content == "{}"
        value_start = start_offset + indent
        return YamlLine.new(number, start_offset, body_end, indent, nil, "{}", value_start, value_start + 2, true, :empty_mapping)
      end
      if content == "-" || content.start_with?("- ")
        return YamlLine.new(number, start_offset, body_end, indent, nil, content, start_offset + indent, start_offset + visible_end, true, :sequence)
      end
      colon = yaml_mapping_colon(content)
      return YamlLine.new(number, start_offset, body_end, indent, nil, content, start_offset + indent, start_offset + visible_end, true, :other) if colon == nil
      key_source = content.byteslice(0, colon).to_s.strip
      key = yaml_key_text(key_source, number, label)
      raw_value = content.byteslice(colon + 1, content.bytesize - colon - 1).to_s
      leading = raw_value.bytesize - raw_value.lstrip.bytesize
      value = raw_value.strip
      value_start = start_offset + indent + colon + 1 + leading
      value_end = value_start + value.bytesize
      if value.start_with?("|", ">")
        raise ConfigError, "#{label} config uses a YAML block scalar that cannot be edited safely; it was not changed"
      end
      YamlLine.new(number, start_offset, body_end, indent, key, value, value_start, value_end, true, :mapping)
    end

    def yaml_visible_end(body, number, label)
      quote = nil
      escaped = false
      index = 0
      while index < body.bytesize
        byte = body.getbyte(index)
        if quote == 34
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            quote = nil
          end
        elsif quote == 39
          if byte == 39 && body.getbyte(index + 1) == 39
            index += 1
          elsif byte == 39
            quote = nil
          end
        elsif byte == 34 || byte == 39
          quote = byte
        elsif byte == 35 && (index == 0 || [9, 32].include?(body.getbyte(index - 1)))
          return index
        end
        index += 1
      end
      raise ConfigError, "#{label} config has an unterminated YAML string on line #{number}; it was not changed" if quote != nil
      body.bytesize
    end

    def yaml_forbidden_syntax?(content)
      quote = nil
      escaped = false
      index = 0
      while index < content.bytesize
        byte = content.getbyte(index)
        if quote == 34
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            quote = nil
          end
        elsif quote == 39
          if byte == 39 && content.getbyte(index + 1) == 39
            index += 1
          elsif byte == 39
            quote = nil
          end
        elsif byte == 34 || byte == 39
          quote = byte
        elsif [33, 38, 42].include?(byte)
          previous = index == 0 ? nil : content.getbyte(index - 1)
          boundary = previous == nil || [9, 32, 44, 58, 91, 123].include?(previous)
          return true if boundary
        end
        index += 1
      end
      false
    end

    def yaml_mapping_colon(content)
      quote = nil
      escaped = false
      index = 0
      while index < content.bytesize
        byte = content.getbyte(index)
        if quote == 34
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            quote = nil
          end
        elsif quote == 39
          if byte == 39 && content.getbyte(index + 1) == 39
            index += 1
          elsif byte == 39
            quote = nil
          end
        elsif byte == 34 || byte == 39
          quote = byte
        elsif byte == 58
          return index
        end
        index += 1
      end
      nil
    end

    def yaml_key_text(source, number, label)
      raise ConfigError, "#{label} config has an empty YAML key on line #{number}; it was not changed" if source == ""
      return source if source.match?(/\A[A-Za-z0-9_.-]+\z/)
      if source.start_with?(%q{"})
        value = JSON.parse(source)
        return value if value.is_a?(String)
      elsif source.start_with?(%q{'}) && source.end_with?(%q{'})
        inner = source.byteslice(1, source.bytesize - 2).to_s
        return inner.gsub("''", "'") if !inner.gsub("''", "").include?("'")
      end
      raise ConfigError, "#{label} config uses an unsupported YAML key on line #{number}; it was not changed"
    rescue JSON::ParserError
      raise ConfigError, "#{label} config has an invalid quoted YAML key on line #{number}; it was not changed"
    end

    def yaml_mapping_groups(lines, start_index, end_index, indent, label)
      groups = []
      seen = {}
      current = nil
      index = start_index
      while index < end_index
        line = lines[index]
        if line.significant
          raise ConfigError, "#{label} has invalid indentation; config was not changed" if line.indent < indent
          if line.indent == indent
            raise ConfigError, "#{label} is not a clean YAML mapping; config was not changed" if line.kind != :mapping
            raise ConfigError, "#{label} contains duplicate key #{line.key.inspect}; config was not changed" if seen[line.key]
            current.end_index = index if current != nil
            current = YamlGroup.new(line.key, line, index, end_index)
            groups << current
            seen[line.key] = true
          elsif current == nil
            raise ConfigError, "#{label} has nested content without a parent key; config was not changed"
          end
        end
        index += 1
      end
      current.end_index = end_index if current != nil
      groups
    end

    def yaml_group_scalar(lines, group, label)
      raise ConfigError, "#{label} is missing; config was not changed" if group == nil
      raise ConfigError, "#{label} must be one scalar value; config was not changed" if group.line.value == "" || yaml_group_has_children?(lines, group)
      source = group.line.value
      if source.start_with?(%q{"})
        value = JSON.parse(source)
        raise ConfigError, "#{label} must be one string value; config was not changed" if !value.is_a?(String)
        value
      elsif source.start_with?(%q{'})
        raise ConfigError, "#{label} has an invalid quoted scalar; config was not changed" if !source.end_with?(%q{'})
        inner = source.byteslice(1, source.bytesize - 2).to_s
        raise ConfigError, "#{label} has an invalid quoted scalar; config was not changed" if inner.gsub("''", "").include?("'")
        inner.gsub("''", "'")
      else
        raise ConfigError, "#{label} uses an inline YAML collection; config was not changed" if source.start_with?("{", "[")
        source
      end
    rescue JSON::ParserError
      raise ConfigError, "#{label} has an invalid quoted scalar; config was not changed"
    end

    def yaml_group_has_children?(lines, group)
      lines[(group.start_index + 1)...group.end_index].to_a.any?(&:significant)
    end

    def yaml_group_end_offset(text, lines, group)
      group.end_index < lines.size ? lines[group.end_index].start_offset : text.bytesize
    end

    def replace_yaml_line_value(text, line, replacement, label)
      raise ConfigError, "#{label} cannot be located safely; config was not changed" if line.value_start == nil || line.value_end == nil
      text.byteslice(0, line.value_start).to_s + replacement.to_s.b + text.byteslice(line.value_end, text.bytesize - line.value_end).to_s
    end

    def replace_yaml_empty_mapping(text, line, block, label)
      tail = text.byteslice(line.value_end, line.body_end - line.value_end).to_s
      raise ConfigError, "#{label} has content after its empty inline mapping; config was not changed" if tail.strip != ""
      replacement = block.to_s
      replacement = replacement.sub(/\r?\n\z/, "") if [10, 13].include?(text.getbyte(line.value_end))
      replace_yaml_line_value(text, line, replacement, label)
    end

    def insert_yaml_block(text, position, block)
      raise ConfigError, "Cannot locate YAML insertion point safely" if position < 0 || position > text.bytesize
      prefix = position > 0 && ![10, 13].include?(text.getbyte(position - 1)) ? yaml_newline(text) : ""
      text.byteslice(0, position).to_s + prefix.b + block.to_s.b + text.byteslice(position, text.bytesize - position).to_s
    end

    def yaml_newline(text)
      text.include?("\r\n") ? "\r\n" : "\n"
    end

    def parse_json_object(text, label)
      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      raise ConfigError, "#{label} config is not valid UTF-8; it was not changed" if !utf8.valid_encoding?
      value = JSON.parse(utf8, :allow_duplicate_key => false)
      raise ConfigError, "#{label} config root is not an object; it was not changed" if !value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      raise ConfigError, "#{label} config is invalid JSON (#{error.message.to_s.lines.first.to_s.strip}); it was not changed"
    end

    def read_config(path, label)
      raise ConfigError, "#{label} config does not exist: #{path}" if !File.file?(path)
      raise ConfigError, "#{label} config is a symbolic link and was not changed: #{path}" if File.symlink?(path)
      raise ConfigError, "#{label} config is not readable and writable: #{path}" if !File.readable?(path) || !File.writable?(path)
      size = File.size(path)
      raise ConfigError, "#{label} config is too large to update safely" if size > MAX_CONFIG_BYTES
      File.binread(path)
    rescue ConfigError
      raise
    rescue Exception => error
      raise ConfigError, "Cannot read #{label} config: #{error.class}: #{error.message}"
    end

    def write_config(path, original, updated)
      raise ConfigError, "Configuration update produced no change" if updated == original
      raise ConfigError, "Configuration changed while it was being reviewed; it was not overwritten" if File.binread(path) != original
      directory = File.dirname(path)
      temporary = File.join(directory, ".#{File.basename(path)}.klangten-mcp-#{Process.pid}-#{SecureRandom.hex(6)}.tmp")
      mode = File.stat(path).mode & 0o777
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.binmode
        file.write(updated)
        file.flush
        file.fsync rescue nil
      end
      raise ConfigError, "Configuration changed before the atomic replacement; it was not overwritten" if File.binread(path) != original
      File.rename(temporary, path)
      true
    rescue ConfigError
      raise
    rescue Exception => error
      raise ConfigError, "Cannot update configuration atomically: #{error.class}: #{error.message}"
    ensure
      File.delete(temporary) rescue nil if defined?(temporary) && temporary != nil && File.exist?(temporary)
    end

    def home_directory
      Dir.home
    rescue Exception
      raise ConfigError, "Cannot determine the user home directory"
    end

    def validated_endpoint(url)
      text = url.to_s.strip
      canonical = canonical_endpoint(text)
      { :url => text, :canonical => canonical }
    end

    def canonical_endpoint(url)
      uri = URI.parse(url.to_s)
      raise ConfigError, "MCP server URL must use HTTP or HTTPS" if !%w[http https].include?(uri.scheme.to_s.downcase)
      raise ConfigError, "MCP server URL must contain a host" if uri.host.to_s == ""
      raise ConfigError, "MCP server URL cannot contain user information or a fragment" if uri.userinfo != nil || uri.fragment != nil
      path = uri.path.to_s
      path = "/" if path == ""
      path = path.sub(%r{/+\z}, "") if path != "/"
      [uri.scheme.downcase, uri.host.downcase, uri.port, path, uri.query.to_s]
    rescue URI::InvalidURIError
      raise ConfigError, "MCP server URL is invalid"
    end

    def validated_authorization(value)
      text = value.to_s
      raise ConfigError, "MCP Authorization header has an unexpected format" if !old_authorization?(text)
      text
    end

    def old_authorization?(value)
      value.is_a?(String) && value.match?(OLD_AUTHORIZATION)
    end

    def member_named(members, name)
      member = members.find { |item| item.key == name }
      raise ConfigError, "Configuration structure changed while locating #{name.inspect}" if member == nil
      member
    end

    def scan_toml(text)
      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      raise ConfigError, "Codex config is not valid UTF-8; it was not changed" if !utf8.valid_encoding?
      raise ConfigError, "Codex config uses multiline TOML strings that cannot be edited conservatively" if text.include?(%q{"""}) || text.include?("'''")
      tables = []
      current = TomlTable.new([], false, [])
      tables << current
      square_depth = 0
      curly_depth = 0
      offset = 0
      text.each_line do |line|
        visible, equals_at, square_delta, curly_delta = toml_line_info(line)
        stripped = visible.strip
        if square_depth == 0 && curly_depth == 0 && stripped.start_with?("[")
          path, array = parse_toml_header(stripped)
          current = TomlTable.new(path, array, [])
          tables << current
        elsif square_depth == 0 && curly_depth == 0 && stripped != ""
          raise ConfigError, "Codex config contains an unsupported TOML statement; it was not changed" if equals_at == nil
          assignment = parse_toml_assignment(line, visible, equals_at, offset)
          if current.path.empty? && assignment.key_path[0] == "mcp_servers"
            raise ConfigError, "Codex config uses dotted or inline mcp_servers assignments; it was not changed"
          end
          current.assignments << assignment if current.path[0] == "mcp_servers"
        end
        square_depth += square_delta
        curly_depth += curly_delta
        raise ConfigError, "Codex config has unbalanced TOML containers; it was not changed" if square_depth < 0 || curly_depth < 0
        offset += line.bytesize
      end
      raise ConfigError, "Codex config has an incomplete multiline TOML value; it was not changed" if square_depth != 0 || curly_depth != 0
      tables
    end

    def toml_line_info(line)
      visible_end = line.bytesize
      equals_at = nil
      square_delta = 0
      curly_delta = 0
      quote = nil
      escaped = false
      index = 0
      while index < line.bytesize
        byte = line.getbyte(index)
        if quote == 34
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            quote = nil
          end
        elsif quote == 39
          quote = nil if byte == 39
        elsif byte == 34 || byte == 39
          quote = byte
        elsif byte == 35
          visible_end = index
          break
        else
          equals_at = index if byte == 61 && equals_at == nil
          square_delta += 1 if byte == 91
          square_delta -= 1 if byte == 93
          curly_delta += 1 if byte == 123
          curly_delta -= 1 if byte == 125
        end
        index += 1
      end
      raise ConfigError, "Codex config has an unterminated TOML string; it was not changed" if quote != nil
      [line.byteslice(0, visible_end), equals_at != nil && equals_at < visible_end ? equals_at : nil, square_delta, curly_delta]
    end

    def parse_toml_header(stripped)
      array = stripped.start_with?("[[")
      if array
        raise ConfigError, "Invalid TOML array table in Codex config" if !stripped.end_with?("]]" )
        body = stripped.byteslice(2, stripped.bytesize - 4)
      else
        raise ConfigError, "Invalid TOML table in Codex config" if !stripped.end_with?("]")
        body = stripped.byteslice(1, stripped.bytesize - 2)
      end
      [parse_toml_key_path(body), array]
    end

    def parse_toml_assignment(line, visible, equals_at, offset)
      key = parse_toml_key_path(visible.byteslice(0, equals_at))
      value_part = visible.byteslice(equals_at + 1, visible.bytesize - equals_at - 1).to_s
      leading = value_part.bytesize - value_part.lstrip.bytesize
      stripped = value_part.strip
      raise ConfigError, "Codex config contains an empty TOML value; it was not changed" if stripped == ""
      start_position = offset + equals_at + 1 + leading
      TomlAssignment.new(key, stripped, start_position, start_position + stripped.bytesize)
    end

    def parse_toml_key_path(value)
      source = value.to_s.b
      result = []
      index = 0
      loop do
        index += 1 while index < source.bytesize && [9, 32].include?(source.getbyte(index))
        raise ConfigError, "Invalid empty TOML key in Codex config" if index >= source.bytesize
        if source.getbyte(index) == 34
          finish = toml_quoted_finish(source, index, 34)
          token = source.byteslice(index, finish - index)
          result << JSON.parse(token.force_encoding(Encoding::UTF_8))
          index = finish
        elsif source.getbyte(index) == 39
          finish = toml_quoted_finish(source, index, 39)
          result << source.byteslice(index + 1, finish - index - 2).force_encoding(Encoding::UTF_8).to_s
          index = finish
        else
          finish = index
          finish += 1 while finish < source.bytesize && source.getbyte(finish).chr.match?(/[A-Za-z0-9_-]/)
          raise ConfigError, "Unsupported TOML key in Codex config" if finish == index
          result << source.byteslice(index, finish - index).to_s
          index = finish
        end
        index += 1 while index < source.bytesize && [9, 32].include?(source.getbyte(index))
        break if index >= source.bytesize
        raise ConfigError, "Invalid TOML dotted key in Codex config" if source.getbyte(index) != 46
        index += 1
      end
      result
    rescue JSON::ParserError
      raise ConfigError, "Invalid quoted TOML key in Codex config"
    end

    def toml_quoted_finish(source, start, quote)
      index = start + 1
      escaped = false
      while index < source.bytesize
        byte = source.getbyte(index)
        if quote == 34 && escaped
          escaped = false
        elsif quote == 34 && byte == 92
          escaped = true
        elsif byte == quote
          return index + 1
        end
        index += 1
      end
      raise ConfigError, "Unterminated quoted TOML value in Codex config"
    end

    def assignment_named(table, name, required: true)
      selected = table.assignments.select { |assignment| assignment.key_path == [name] }
      raise ConfigError, "Codex MCP server has duplicate #{name} values; config was not changed" if selected.size > 1
      if required && selected.empty?
        raise ConfigError, "Codex MCP server is missing #{name}; config was not changed"
      end
      selected[0]
    end

    def toml_string(assignment)
      value = assignment.value.to_s.b
      if value.start_with?(%q{"})
        finish = toml_quoted_finish(value, 0, 34)
        raise ConfigError, "Codex MCP value is not one clean string; config was not changed" if finish != value.bytesize
        decoded = JSON.parse(value.force_encoding(Encoding::UTF_8))
      elsif value.start_with?("'")
        finish = toml_quoted_finish(value, 0, 39)
        raise ConfigError, "Codex MCP value is not one clean string; config was not changed" if finish != value.bytesize
        decoded = value.byteslice(1, value.bytesize - 2).force_encoding(Encoding::UTF_8).to_s
      else
        raise ConfigError, "Codex MCP value is not a literal string; config was not changed"
      end
      [decoded, assignment.value_start, assignment.value_end]
    rescue JSON::ParserError
      raise ConfigError, "Codex MCP string is invalid; config was not changed"
    end

    def parse_inline_authorization(assignment)
      value = assignment.value.to_s.b
      index = 0
      index += 1 while index < value.bytesize && [9, 32].include?(value.getbyte(index))
      raise ConfigError, "Codex Klangten http_headers is not one clean inline table; config was not changed" if value.getbyte(index) != 123
      index += 1
      closing = value.rindex("}")
      raise ConfigError, "Codex Klangten http_headers is not one clean inline table; config was not changed" if closing == nil || value.byteslice(closing + 1, value.bytesize - closing - 1).to_s.strip != ""
      body = value.byteslice(index, closing - index)
      visible, equals_at, square_delta, curly_delta = toml_line_info(body)
      raise ConfigError, "Codex Klangten http_headers must contain only Authorization; config was not changed" if equals_at == nil || square_delta != 0 || curly_delta != 0
      key = parse_toml_key_path(visible.byteslice(0, equals_at))
      raise ConfigError, "Codex Klangten http_headers must contain only Authorization; config was not changed" if key != ["Authorization"]
      raw = visible.byteslice(equals_at + 1, visible.bytesize - equals_at - 1).to_s
      leading = raw.bytesize - raw.lstrip.bytesize
      stripped = raw.strip
      raise ConfigError, "Codex Klangten Authorization header has extra fields; config was not changed" if stripped.include?(",")
      nested = TomlAssignment.new(["Authorization"], stripped, assignment.value_start + index + equals_at + 1 + leading, assignment.value_start + index + equals_at + 1 + leading + stripped.bytesize)
      toml_string(nested)
    end

    def toml_quote(value)
      JSON.generate(value.to_s)
    end

    class JsonObjectEditor
      Member = Struct.new(:key, :key_start, :key_end, :value_start, :value_end)

      def initialize(text)
        @text = text.b
        @object_closes = {}
      end

      def root_members
        start = skip_space(0)
        members = object_members(start)
        close = @object_closes.fetch(members.object_id)
        raise ConfigError, "JSON contains trailing data" if skip_space(close + 1) != @text.bytesize
        members
      end

      def object_members(start)
        raise ConfigError, "Expected a JSON object" if @text.getbyte(start) != 123
        members = []
        index = skip_space(start + 1)
        if @text.getbyte(index) == 125
          @object_closes[members.object_id] = index
          return members
        end
        loop do
          key_start = index
          key_end = scan_string(index)
          key = JSON.parse(@text.byteslice(key_start, key_end - key_start).force_encoding(Encoding::UTF_8))
          index = skip_space(key_end)
          raise ConfigError, "Expected a JSON object colon" if @text.getbyte(index) != 58
          value_start = skip_space(index + 1)
          value_end = scan_value(value_start)
          members << Member.new(key, key_start, key_end, value_start, value_end)
          index = skip_space(value_end)
          break if @text.getbyte(index) == 125
          raise ConfigError, "Expected a JSON object comma" if @text.getbyte(index) != 44
          index = skip_space(index + 1)
        end
        @object_closes[members.object_id] = index
        members
      rescue JSON::ParserError
        raise ConfigError, "Cannot locate JSON object members safely"
      end

      def insert_member(members, key, value)
        close = @object_closes.fetch(members.object_id) { raise ConfigError, "Cannot locate JSON object end" }
        raise ConfigError, "Cannot locate JSON object end" if @text.getbyte(close) != 125
        indent = closing_indent(close)
        child_indent = indent + "  "
        pair = JSON.generate(key.to_s) + ": " + JSON.generate(value)
        addition = (members.empty? ? "" : ",") + "\n" + child_indent + pair + "\n" + indent
        replace(close, close, addition)
      end

      def replace(start, finish, replacement)
        @text.byteslice(0, start).to_s + replacement.to_s.b + @text.byteslice(finish, @text.bytesize - finish).to_s
      end

      private

      def scan_value(index)
        byte = @text.getbyte(index)
        return scan_string(index) if byte == 34
        return scan_object(index) if byte == 123
        return scan_array(index) if byte == 91
        finish = index
        finish += 1 while finish < @text.bytesize && ![9, 10, 13, 32, 44, 93, 125].include?(@text.getbyte(finish))
        raise ConfigError, "Cannot locate JSON value" if finish == index
        finish
      end

      def scan_object(index)
        cursor = skip_space(index + 1)
        return cursor + 1 if @text.getbyte(cursor) == 125
        loop do
          cursor = scan_string(cursor)
          cursor = skip_space(cursor)
          raise ConfigError, "Invalid JSON object" if @text.getbyte(cursor) != 58
          cursor = scan_value(skip_space(cursor + 1))
          cursor = skip_space(cursor)
          return cursor + 1 if @text.getbyte(cursor) == 125
          raise ConfigError, "Invalid JSON object" if @text.getbyte(cursor) != 44
          cursor = skip_space(cursor + 1)
        end
      end

      def scan_array(index)
        cursor = skip_space(index + 1)
        return cursor + 1 if @text.getbyte(cursor) == 93
        loop do
          cursor = scan_value(cursor)
          cursor = skip_space(cursor)
          return cursor + 1 if @text.getbyte(cursor) == 93
          raise ConfigError, "Invalid JSON array" if @text.getbyte(cursor) != 44
          cursor = skip_space(cursor + 1)
        end
      end

      def scan_string(index)
        raise ConfigError, "Expected a JSON string" if @text.getbyte(index) != 34
        index += 1
        escaped = false
        while index < @text.bytesize
          byte = @text.getbyte(index)
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            return index + 1
          end
          index += 1
        end
        raise ConfigError, "Unterminated JSON string"
      end

      def skip_space(index)
        index += 1 while index < @text.bytesize && [9, 10, 13, 32].include?(@text.getbyte(index))
        index
      end

      def closing_indent(index)
        line_start = @text.rindex("\n", index - 1)
        line_start = line_start == nil ? 0 : line_start + 1
        prefix = @text.byteslice(line_start, index - line_start).to_s
        prefix.match?(/\A[ \t]*\z/) ? prefix : ""
      end
    end
  end
end
