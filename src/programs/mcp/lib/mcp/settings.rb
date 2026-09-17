# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; klangten client configuration entry.

require "json"

module EltenMCP
  class Settings
    def initialize(runtime, bridge)
      @runtime = runtime
      @bridge = bridge
      @permission_client_ids = []
      @default_permission_aspects = []
    end

    def add_to(settings)
      @default_permissions_confirmed = false
      @default_permissions_save_enabled = false
      @staged_default_permissions = nil
      settings.category(@bridge.translate("MCP", "Model Context Protocol"))
      settings.boolean(:enabled,
        :label => @bridge.translate("MCP", "Enable the local MCP server"),
        :get => proc { @runtime.config.enabled? },
        :set => proc { |value| @runtime.config.enabled = value })
      settings.integer(:port,
        :label => @bridge.translate("MCP", "Local MCP port"),
        :range => Config::MIN_PORT..Config::MAX_PORT,
        :get => proc { @runtime.config.port },
        :set => proc { |value| @runtime.config.port = value })
      settings.boolean(:advanced_network,
        :label => @bridge.translate("MCP", "Use a non-default bind address or accepted subnets (high risk)"),
        :get => proc { @runtime.config.network_risk_acknowledged? },
        :set => proc { |value| stage_network_risk(value) })
      settings.text(:bind_address,
        :label => @bridge.translate("MCP", "Bind IP address"),
        :get => proc { @runtime.config.bind_address },
        :set => proc { |value| stage_bind_address(value) })
      settings.text(:allowed_subnets,
        :label => @bridge.translate("MCP", "Accepted client subnets in CIDR notation, separated by spaces"),
        :get => proc { @runtime.config.allowed_subnets.join(" ") },
        :set => proc { |value| save_network_settings(value) })
      settings.boolean(:remember_permissions,
        :label => @bridge.translate("MCP", "Remember reviewed permissions between Klangten sessions (high risk)"),
        :get => proc { @runtime.config.remember_permissions? },
        :set => proc { |value| @runtime.configure_permission_memory(value) })

      @default_permission_aspects = default_permission_aspects
      if @runtime.config.loopback_only?
        current_count = @runtime.config.default_permissions.size
        settings.boolean(:configure_default_permissions,
          :label => @bridge.translate("MCP", "Show automatic default permissions for new clients (high risk; currently %{count})").gsub("%{count}", current_count.to_s),
          :get => proc { false },
          :set => proc { |value| stage_default_permissions_visibility(value) })
        @default_permission_aspects.each do |aspect|
          definition = Authorization::CAPABILITIES[aspect]
          levels = [:none] + definition[:levels]
          choices = levels.map { |level| [@bridge.translate("MCP", Authorization::LEVEL_LABELS[level]), level] }
          label = @bridge.translate("MCP", "Automatic default for %{capability}. %{description}")
            .gsub("%{capability}", @bridge.translate("MCP", definition[:title]))
            .gsub("%{description}", @bridge.translate("MCP", definition[:description]))
          settings.choice("default_permission_#{aspect}".to_sym,
            :label => label,
            :choices => choices,
            :get => proc { default_permission_level(aspect) },
            :set => proc { |value| stage_default_permission(aspect, value) })
        end
      else
        @default_permission_aspects = []
      end

      clients = @runtime.permission_clients
      @permission_client_ids = clients.map { |client| client["id"] }
      client_choices = if clients.empty?
                         [[@bridge.translate("MCP", "No MCP clients have been observed in this session."), "__none__"]]
                       else
                         clients.map { |client| [client["label"], client["id"]] }
                       end
      settings.choice(:permission_client,
        :label => @bridge.translate("MCP", "MCP clients"),
        :choices => client_choices,
        :get => proc { @permission_client_ids[0] || "__none__" },
        :set => proc { |_value| true })
      settings.action(:show_credentials, :label => @bridge.translate("MCP", "Show MCP connection details")) { show_credentials }
      settings.action(:rotate_key, :label => @bridge.translate("MCP", "Rotate MCP client key")) { rotate_key }
      settings.action(:revoke_all_permissions, :label => @bridge.translate("MCP", "Revoke all current and remembered client permissions")) { revoke_all_permissions }
      settings.action(:show_status, :label => @bridge.translate("MCP", "Show MCP server status")) { show_status }
      install_settings_behavior(settings)
    end

    def show_credentials
      client_configuration = @runtime.config.client_configuration
      server_configuration = client_configuration.fetch("mcpServers").fetch(ClientConfigInstaller::SERVER_NAME)
      @bridge.show_credentials(
        @runtime.config.authorization_header,
        JSON.pretty_generate(client_configuration),
        @runtime.config.network_configuration,
        server_configuration.fetch("url"),
        server_configuration.fetch("headers").fetch("Authorization")
      )
    end

    def rotate_key
      warning = @bridge.translate("MCP", "Rotate the MCP client key? Existing client configurations will stop working immediately. All current grants and remembered client profiles will be revoked; the separately configured default permission scheme will remain.")
      return false if !@bridge.confirm_action(warning)
      @runtime.rotate_client_key
      @bridge.notify(@bridge.translate("MCP", "MCP client key rotated. Copy a new client configuration."), false)
      true
    end

    def revoke_all_permissions
      warning = @bridge.translate("MCP", "Revoke every current grant and erase every remembered client profile? The separately configured default scheme is not changed.")
      return false if !@bridge.confirm_action(warning)
      @runtime.revoke_permissions
      @bridge.notify(@bridge.translate("MCP", "All current and remembered MCP client permissions have been revoked."), false)
      true
    end

    def show_status
      status = @runtime.status
      text = if status["listening"]
               @bridge.translate("MCP", "MCP is listening on %{host}:%{port}; accepted client subnets: %{subnets}.")
                 .gsub("%{host}", status["host"].to_s)
                 .gsub("%{port}", status["port"].to_s)
                 .gsub("%{subnets}", Array(status["allowed_subnets"]).join(", "))
             elsif status["enabled"]
               @bridge.translate("MCP", "MCP is enabled but is not listening. %{error}").gsub("%{error}", status["last_error"].to_s)
             else
               @bridge.translate("MCP", "MCP is disabled.")
             end
      authorization = status["authorization"] || {}
      if status["loopback_only"] != true
        text += " " + @bridge.translate("MCP", "Warning: MCP accepts clients outside loopback. Anyone in an accepted subnet who obtains the secret client key can connect as an MCP client.")
      end
      if authorization["authorized_clients"].to_i > 0
        capabilities = (authorization["granted_capabilities"] || {}).map { |aspect, levels| "#{aspect}=#{Array(levels).join("/")}" }.join(", ")
        text += " " + @bridge.translate("MCP", "Authorized clients: %{count}; general capabilities: %{capabilities}; selective grants: %{selective}.")
          .gsub("%{count}", authorization["authorized_clients"].to_i.to_s)
          .gsub("%{capabilities}", capabilities)
          .gsub("%{selective}", authorization["selective_grant_count"].to_i.to_s)
      end
      memory = status["remember_permissions"] ? @bridge.translate("MCP", "enabled") : @bridge.translate("MCP", "disabled")
      text += " " + @bridge.translate("MCP", "Permission memory: %{state}; default permission capabilities: %{count}.")
        .gsub("%{state}", memory)
        .gsub("%{count}", status["default_permissions"].size.to_s)
      @bridge.notify(text, false)
      status
    end

    private

    def install_settings_behavior(settings)
      scene = settings.instance_variable_get(:@scene)
      return false if scene == nil || !scene.respond_to?(:on_load) || !settings.respond_to?(:render)
      original_render = settings.method(:render)
      owner = self
      settings.define_singleton_method(:render) do
        result = original_render.call
        owner.send(:attach_settings_behavior, scene)
        result
      end
      true
    end

    def attach_settings_behavior(scene)
      scene.on_load do
        form = scene.instance_variable_get(:@form)
        categories = scene.instance_variable_get(:@settings)
        category_index = scene.instance_variable_get(:@category)
        category = categories[category_index] if categories.is_a?(Array)
        next if form == nil || category == nil
        attach_network_controls(form, category)
        attach_permission_controls(form, category)
      end
      true
    end

    def setting_field_indices(category, names)
      result = names.each_with_object({}) { |name, values| values[name.to_s] = nil }
      Array(category).each_with_index do |setting, index|
        next if !setting.is_a?(Array) || setting[2] != :extension_setting
        result.each_key do |name|
          result[name] = index - 1 if setting[3].to_s.end_with?(":" + name)
        end
      end
      result
    end

    def attach_network_controls(form, category)
      indices = setting_field_indices(category, %w[advanced_network bind_address allowed_subnets])
      return false if indices.values.any?(&:nil?)
      checkbox = form.fields[indices["advanced_network"]]
      return false if checkbox == nil
      checkbox.on(:change) do
        if checkbox.checked
          if !@runtime.config.network_risk_acknowledged? && @network_risk_confirmed != true
            @network_risk_confirmed = @bridge.confirm_action(network_risk_warning)
            checkbox.checked = false if @network_risk_confirmed != true
          end
        elsif !@runtime.config.network_risk_acknowledged?
          @network_risk_confirmed = false
        end
        if checkbox.checked
          form.show(indices["bind_address"])
          form.show(indices["allowed_subnets"])
        else
          form.hide(indices["bind_address"])
          form.hide(indices["allowed_subnets"])
        end
      end
      checkbox.trigger(:change)
      true
    end

    def attach_permission_controls(form, category)
      names = %w[remember_permissions configure_default_permissions permission_client] +
        @default_permission_aspects.map { |aspect| "default_permission_#{aspect}" }
      indices = setting_field_indices(category, names)

      remember = form.fields[indices["remember_permissions"]] if indices["remember_permissions"] != nil
      if remember != nil
        remember.on(:change) do
          desired = remember.checked == true
          current = @runtime.config.remember_permissions?
          next if desired == current
          warning = desired ? remember_permissions_enable_warning : remember_permissions_disable_warning
          remember.checked = current if !@bridge.confirm_action(warning)
        end
      end

      defaults_toggle = form.fields[indices["configure_default_permissions"]] if indices["configure_default_permissions"] != nil
      default_indices = @default_permission_aspects.map { |aspect| indices["default_permission_#{aspect}"] }.compact
      if defaults_toggle != nil && default_indices.size == @default_permission_aspects.size
        update_default_visibility = proc do
          default_indices.each do |index|
            defaults_toggle.checked ? form.show(index) : form.hide(index)
          end
        end
        defaults_toggle.on(:change) do
          if defaults_toggle.checked
            if @default_permissions_confirmed != true
              @default_permissions_confirmed = @bridge.confirm_action(default_permissions_warning)
              defaults_toggle.checked = false if @default_permissions_confirmed != true
            end
          else
            @default_permissions_confirmed = false
          end
          update_default_visibility.call
        end
        update_default_visibility.call
      end

      client_list = form.fields[indices["permission_client"]] if indices["permission_client"] != nil
      if client_list != nil
        client_list.empty_label = @bridge.translate("MCP", "No MCP clients have been observed in this session.") if client_list.respond_to?(:empty_label=)
        client_list.options = [] if @permission_client_ids.empty? && client_list.respond_to?(:options=)
        client_list.on(:select) do
          client_id = @permission_client_ids[client_list.index.to_i]
          if client_id == nil
            @bridge.notify(@bridge.translate("MCP", "No MCP clients have been observed in this session."), false)
          else
            @runtime.manage_permissions(client_id)
          end
        end
      end
      true
    end

    def default_permission_aspects
      Authorization::CAPABILITIES.keys.reject do |aspect|
        Authorization::CAPABILITIES[aspect][:always] || (aspect == :developer && !@bridge.developer_mode?)
      end
    end

    def default_permission_level(aspect)
      selected = @runtime.config.default_permissions[aspect.to_s].to_s
      selected = "none" if selected == ""
      levels = [:none] + Authorization::CAPABILITIES[aspect][:levels]
      levels.include?(selected.to_sym) ? selected.to_sym : :none
    end

    def stage_default_permissions_visibility(value)
      @default_permissions_save_enabled = value == true && @default_permissions_confirmed == true && @runtime.config.loopback_only?
      @staged_default_permissions = visible_default_permissions
      true
    end

    def stage_default_permission(aspect, value)
      return true if @default_permissions_save_enabled != true || !@runtime.config.loopback_only?
      @staged_default_permissions ||= visible_default_permissions
      level = value.to_sym
      if level == :none
        @staged_default_permissions.delete(aspect.to_s)
      else
        @staged_default_permissions[aspect.to_s] = level.to_s
      end
      if aspect == @default_permission_aspects[-1]
        @runtime.config.default_permissions = @staged_default_permissions
      end
      true
    end

    def visible_default_permissions
      allowed = @default_permission_aspects.map(&:to_s)
      @runtime.config.default_permissions.each_with_object({}) do |(aspect, level), result|
        result[aspect.to_s] = level.to_s if allowed.include?(aspect.to_s)
      end
    end

    def remember_permissions_enable_warning
      @bridge.translate("MCP", "High risk: remembered general and selective grants are stored for the signed-in Klango account, current secret key and self-declared client name/version. Anyone who obtains the key can spoof that client identity and reuse the grants. Do you want to enable permission memory?")
    end

    def remember_permissions_disable_warning
      @bridge.translate("MCP", "Disabling permission memory will erase every remembered client profile when these settings are saved. Current live session grants remain until revoked or the session ends. Do you want to disable permission memory?")
    end

    def default_permissions_warning
      @bridge.translate("MCP", "High risk: these levels are granted automatically to every new MCP client without an individual confirmation. Anyone with the secret key can use them immediately. Do you want to configure automatic default permissions?")
    end

    def network_risk_warning
      @bridge.translate("MCP", "High risk: changing the bind address can expose MCP on a network. Anyone inside an accepted subnet who obtains the secret client key can request access to Klangten data and actions. Use the narrowest CIDRs, keep firewalls enabled, never expose MCP directly to the Internet, and rotate the key after suspected disclosure. Do you want to configure advanced network access?")
    end

    def network_settings_state
      @network_settings_state ||= begin
        current = @runtime.config.network_configuration
        {
          "risk_acknowledged" => current["risk_acknowledged"] == true,
          "previous_risk_acknowledged" => current["risk_acknowledged"] == true,
          "bind_address" => current["bind_address"].to_s,
          "allowed_subnets" => Array(current["allowed_subnets"]).join(" ")
        }
      end
    end

    def stage_network_risk(value)
      network_settings_state["risk_acknowledged"] = value == true
    end

    def stage_bind_address(value)
      network_settings_state["bind_address"] = value.to_s
    end

    def save_network_settings(value)
      state = network_settings_state
      state["allowed_subnets"] = value.to_s
      risk_acknowledged = state["risk_acknowledged"] == true
      if risk_acknowledged && state["previous_risk_acknowledged"] != true && @network_risk_confirmed != true
        risk_acknowledged = @bridge.confirm_action(network_risk_warning)
      end
      previous_defaults = @runtime.config.default_permissions
      configuration = @runtime.config.configure_network(
        :bind_address => risk_acknowledged ? state["bind_address"] : Config::DEFAULT_BIND_ADDRESS,
        :allowed_subnets => risk_acknowledged ? state["allowed_subnets"] : Config::DEFAULT_ALLOWED_SUBNETS,
        :risk_acknowledged => risk_acknowledged
      )
      if !configuration["loopback_only"] && !previous_defaults.empty?
        @bridge.notify(@bridge.translate("MCP", "The default permission scheme was erased because accepted client subnets now extend beyond loopback."), false)
      end
      configuration
    ensure
      @network_settings_state = nil
      @network_risk_confirmed = false
    end
  end
end
