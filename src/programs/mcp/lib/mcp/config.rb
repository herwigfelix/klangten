# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: own default port 37383 and server name klangten; notes aspect; feed removed.

require "digest"
require "ipaddr"
require "securerandom"

module EltenMCP
  class Config
    # Klangten: Elten's MCP uses 37373; a different default lets both run side by side.
    DEFAULT_PORT = 37383
    DEFAULT_BIND_ADDRESS = "127.0.0.1"
    DEFAULT_ALLOWED_SUBNETS = ["127.0.0.1/32"].freeze
    MAX_ALLOWED_SUBNETS = 32
    MAX_REMEMBERED_SELECTIVE_GRANTS = 100
    MIN_PORT = 1024
    MAX_PORT = 65_535
    CONFIG_FILE = "config.json"
    DEFAULT_PERMISSION_LEVELS = {
      "diagnostics" => %w[read],
      "account" => %w[read write],
      "forum" => %w[scope read write moderate],
      "messages" => %w[scope read write moderate],
      "notifications" => %w[read write],
      "blogs" => %w[read write],
      "notes" => %w[read write],
      "polls" => %w[read write],
      "settings" => %w[write],
      "source" => %w[read],
      "developer" => %w[full]
    }.freeze

    def initialize(storage)
      @storage = storage
      @mutex = Mutex.new
    end

    def enabled?
      value("enabled") == true
    end

    def enabled=(enabled)
      update("enabled", enabled == true)
    end

    def port
      value("port").to_i
    end

    def port=(port)
      port = Integer(port)
      raise ArgumentError, "MCP port must be in #{MIN_PORT}..#{MAX_PORT}" if !port.between?(MIN_PORT, MAX_PORT)
      update("port", port)
    end

    def bind_address
      value("bind_address").to_s
    end

    def allowed_subnets
      Array(value("allowed_subnets")).map(&:to_s)
    end

    def network_risk_acknowledged?
      value("network_risk_acknowledged") == true
    end

    def network_configuration
      @mutex.synchronize do
        ensure_loaded
        {
          "bind_address" => @data["bind_address"].to_s,
          "allowed_subnets" => Array(@data["allowed_subnets"]).map(&:to_s),
          "risk_acknowledged" => @data["network_risk_acknowledged"] == true,
          "loopback_only" => loopback_subnets?(Array(@data["allowed_subnets"]))
        }
      end
    end

    def configure_network(bind_address:, allowed_subnets:, risk_acknowledged:)
      bind = normalized_bind_address(bind_address)
      subnets = normalized_subnets(allowed_subnets)
      bind_ip = IPAddr.new(bind)
      if !subnets.any? { |entry| network = IPAddr.new(entry); (bind_ip.ipv4? && network.ipv4?) || (bind_ip.ipv6? && network.ipv6?) }
        raise ArgumentError, "At least one accepted MCP subnet must use the bind address family"
      end
      advanced = bind != DEFAULT_BIND_ADDRESS || subnets != DEFAULT_ALLOWED_SUBNETS
      if advanced && risk_acknowledged != true
        raise ArgumentError, "You must explicitly acknowledge the network exposure risk before using non-default MCP network settings"
      end
      @mutex.synchronize do
        ensure_loaded
        @data["bind_address"] = bind
        @data["allowed_subnets"] = subnets
        @data["network_risk_acknowledged"] = advanced && risk_acknowledged == true
        @data["default_permissions"] = {} if !loopback_subnets?(subnets)
        persist
      end
      network_configuration
    end

    def loopback_only?
      @mutex.synchronize do
        ensure_loaded
        loopback_subnets?(Array(@data["allowed_subnets"]))
      end
    end

    def remember_permissions?
      value("remember_permissions") == true
    end

    def remember_permissions=(enabled)
      @mutex.synchronize do
        ensure_loaded
        @data["remember_permissions"] = enabled == true
        @data["permission_profiles"] = {} if enabled != true
        persist
      end
      enabled == true
    end

    def default_permissions
      @mutex.synchronize do
        ensure_loaded
        return {} if !loopback_subnets?(Array(@data["allowed_subnets"]))
        deep_copy(@data["default_permissions"])
      end
    end

    def default_permissions=(permissions)
      normalized = normalize_default_permissions(permissions)
      @mutex.synchronize do
        ensure_loaded
        raise ArgumentError, "Default MCP permissions are available only when accepted clients are restricted to loopback" if !loopback_subnets?(Array(@data["allowed_subnets"]))
        @data["default_permissions"] = normalized
        persist
      end
      deep_copy(normalized)
    end

    def permission_profile(account, client)
      @mutex.synchronize do
        ensure_loaded
        return nil if @data["remember_permissions"] != true
        key = permission_profile_key(account, client, @data["client_key"])
        value = @data["permission_profiles"][key]
        value == nil ? nil : deep_copy(value)
      end
    end

    def save_permission_profile(account, client, profile)
      normalized = normalize_permission_profile(profile)
      @mutex.synchronize do
        ensure_loaded
        return false if @data["remember_permissions"] != true || account.to_s.strip == ""
        key = permission_profile_key(account, client, @data["client_key"])
        @data["permission_profiles"][key] = normalized.merge(
          "account" => account.to_s,
          "client_name" => normalized_client_value(client, "name"),
          "client_version" => normalized_client_value(client, "version")
        )
        persist
      end
      true
    end

    def delete_permission_profile(account, client)
      @mutex.synchronize do
        ensure_loaded
        key = permission_profile_key(account, client, @data["client_key"])
        removed = @data["permission_profiles"].delete(key) != nil
        persist if removed
        removed
      end
    end

    def clear_permission_profiles
      @mutex.synchronize do
        ensure_loaded
        changed = !@data["permission_profiles"].empty?
        @data["permission_profiles"] = {}
        persist if changed
        changed
      end
    end

    def client_key
      @mutex.synchronize do
        ensure_loaded
        @data["client_key"]
      end
    end

    def rotate_client_key
      @mutex.synchronize do
        ensure_loaded
        @data["client_key"] = generate_key
        @data["permission_profiles"] = {}
        persist
        @data["client_key"]
      end
    end

    def client_configuration
      host = bind_address
      host = DEFAULT_BIND_ADDRESS if host == "0.0.0.0"
      host = "::1" if host == "::"
      host = "[#{host}]" if host.include?(":")
      {
        "mcpServers" => {
          ClientConfigInstaller::SERVER_NAME => {
            "type" => "http",
            "url" => "http://#{host}:#{port}/mcp",
            "headers" => { "Authorization" => authorization_value }
          }
        }
      }
    end

    def authorization_value
      "Bearer #{client_key}"
    end

    def authorization_header
      "Authorization: #{authorization_value}"
    end

    private

    def value(key)
      @mutex.synchronize do
        ensure_loaded
        @data[key]
      end
    end

    def update(key, value)
      @mutex.synchronize do
        ensure_loaded
        @data[key] = value
        persist
      end
      value
    end

    def ensure_loaded
      return if @data != nil
      stored = @storage.read_json(CONFIG_FILE, :default => {})
      @data = stored.is_a?(Hash) ? stored : {}
      @data = {
        "enabled" => @data["enabled"] == true || @data["enabled"].to_s == "true",
        "port" => normalized_port(@data["port"]),
        "client_key" => valid_key?(@data["client_key"]) ? @data["client_key"].downcase : generate_key,
        "bind_address" => safe_bind_address(@data["bind_address"]),
        "allowed_subnets" => safe_subnets(@data["allowed_subnets"]),
        "network_risk_acknowledged" => @data["network_risk_acknowledged"] == true,
        "remember_permissions" => @data["remember_permissions"] == true,
        "permission_profiles" => normalize_permission_profiles(@data["permission_profiles"]),
        "default_permissions" => normalize_default_permissions(@data["default_permissions"])
      }
      advanced = @data["bind_address"] != DEFAULT_BIND_ADDRESS || @data["allowed_subnets"] != DEFAULT_ALLOWED_SUBNETS
      if advanced && !@data["network_risk_acknowledged"]
        @data["bind_address"] = DEFAULT_BIND_ADDRESS
        @data["allowed_subnets"] = DEFAULT_ALLOWED_SUBNETS.dup
      end
      @data["network_risk_acknowledged"] = advanced && @data["network_risk_acknowledged"] == true
      @data["permission_profiles"] = {} if !@data["remember_permissions"]
      @data["default_permissions"] = {} if !loopback_subnets?(@data["allowed_subnets"])
      persist
    end

    def normalized_port(port)
      port = port.to_i
      port.between?(MIN_PORT, MAX_PORT) ? port : DEFAULT_PORT
    end

    def valid_key?(key)
      key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
    end

    def safe_bind_address(value)
      normalized_bind_address(value)
    rescue ArgumentError
      DEFAULT_BIND_ADDRESS
    end

    def normalized_bind_address(value)
      text = value.to_s.strip
      raise ArgumentError, "MCP bind address must be an IP address, not a hostname" if text == "" || text.include?("/") || text.include?("%")
      IPAddr.new(text).to_s
    rescue IPAddr::InvalidAddressError
      raise ArgumentError, "MCP bind address must be a valid IPv4 or IPv6 literal"
    end

    def safe_subnets(value)
      normalized_subnets(value)
    rescue ArgumentError
      DEFAULT_ALLOWED_SUBNETS.dup
    end

    def normalized_subnets(value)
      if value.is_a?(Array)
        values = value
      else
        text = value.to_s.strip
        if text.match?(/[,;\t\r\n]/)
          raise ArgumentError, "Accepted MCP subnets must be separated by spaces"
        end
        values = text.split(" ")
      end
      values = values.map { |entry| entry.to_s.strip }.reject(&:empty?)
      raise ArgumentError, "At least one accepted MCP subnet is required" if values.empty?
      raise ArgumentError, "At most #{MAX_ALLOWED_SUBNETS} accepted MCP subnets are allowed" if values.size > MAX_ALLOWED_SUBNETS
      values.map do |entry|
        raise ArgumentError, "Accepted MCP subnet #{entry.inspect} must use CIDR notation" if !entry.include?("/")
        network = IPAddr.new(entry)
        "#{network}/#{network.prefix}"
      rescue IPAddr::InvalidAddressError
        raise ArgumentError, "Invalid accepted MCP subnet: #{entry}"
      end.uniq
    end

    def loopback_subnets?(subnets)
      ipv4_loopback = IPAddr.new("127.0.0.0/8")
      ipv6_loopback = IPAddr.new("::1/128")
      Array(subnets).all? do |entry|
        network = IPAddr.new(entry)
        first = network.to_range.begin
        last = network.to_range.end
        container = network.ipv4? ? ipv4_loopback : ipv6_loopback
        container.include?(first) && container.include?(last)
      rescue IPAddr::InvalidAddressError
        false
      end
    end

    def normalize_default_permissions(value)
      return {} if !value.is_a?(Hash)
      value.each_with_object({}) do |(aspect, level), result|
        name = aspect.to_s
        selected = level.to_s
        result[name] = selected if Array(DEFAULT_PERMISSION_LEVELS[name]).include?(selected)
      end
    end

    def normalize_permission_profiles(value)
      return {} if !value.is_a?(Hash)
      value.each_with_object({}) do |(key, profile), result|
        next if key.to_s !~ /\A[0-9a-f]{64}\z/ || !profile.is_a?(Hash)
        result[key.to_s] = normalize_permission_profile(profile).merge(
          "account" => profile["account"].to_s[0, 200],
          "client_name" => profile["client_name"].to_s[0, 100],
          "client_version" => profile["client_version"].to_s[0, 50]
        )
      end
    end

    def normalize_permission_profile(value)
      value = {} if !value.is_a?(Hash)
      general = normalize_default_permissions(value["general"])
      selective = Array(value["selective"]).filter_map { |grant| normalize_selective_profile_grant(grant) }
      { "general" => general, "selective" => selective.first(MAX_REMEMBERED_SELECTIVE_GRANTS) }
    end

    def normalize_selective_profile_grant(grant)
      return nil if !grant.is_a?(Hash)
      aspect = grant["aspect"].to_s
      type = grant["resource_type"].to_s
      level = grant["level"].to_s
      id = grant["resource_id"]
      normalized_id = case aspect
      when "forum"
        return nil if !%w[group forum thread].include?(type) || !%w[read write moderate].include?(level) || !positive_selective_id?(id)
        id.to_i
      when "messages"
        return nil if !%w[user group custom].include?(type) || !%w[read write moderate].include?(level) || !safe_selective_text?(id)
        id.to_s.strip
      when "notes"
        return nil if !%w[note note_creation].include?(type)
        creation = type == "note_creation"
        return nil if creation && level != "write"
        return nil if !creation && !%w[read write].include?(level)
        if creation
          "create"
        else
          return nil if !positive_selective_id?(id)
          id.to_i
        end
      when "blogs"
        return nil if !%w[blog post blog_creation post_creation].include?(type)
        creation = type.end_with?("_creation")
        return nil if creation && level != "write"
        return nil if !creation && !%w[read write].include?(level)
        if type == "blog_creation"
          "create"
        elsif type == "post"
          return nil if !id.is_a?(Hash) || !safe_selective_text?(id["blog"]) || !positive_selective_id?(id["post_id"])
          { "blog" => id["blog"].to_s.strip, "post_id" => id["post_id"].to_i }
        else
          return nil if !safe_selective_text?(id)
          id.to_s.strip
        end
      else
        return nil
      end
      { "aspect" => aspect, "resource_type" => type, "resource_id" => normalized_id, "level" => level }
    end

    def safe_selective_text?(value)
      value.is_a?(String) && value.strip != "" && value.each_char.count <= 200 && !value.match?(/[[:cntrl:]]/)
    end

    def positive_selective_id?(value)
      value.to_s.match?(/\A[0-9]+\z/) && value.to_i > 0
    end

    def permission_profile_key(account, client, key)
      values = [account.to_s.strip.downcase, normalized_client_value(client, "name"), normalized_client_value(client, "version"), key.to_s]
      Digest::SHA256.hexdigest(values.join("\0"))
    end

    def normalized_client_value(client, key)
      return "" if !client.is_a?(Hash)
      limit = key == "name" ? 100 : 50
      client[key].to_s.gsub(/[[:cntrl:]]/, " ").strip[0, limit]
    end

    def deep_copy(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_copy(item) }
      when Array then value.map { |item| deep_copy(item) }
      when String then value.dup
      else value
      end
    end

    def generate_key
      SecureRandom.hex(32)
    end

    def persist
      written = @storage.write_json(CONFIG_FILE, @data)
      raise Error, "Cannot save MCP program configuration" if !written
      File.chmod(0o600, @storage.data_path(CONFIG_FILE)) rescue nil
      true
    end
  end
end
