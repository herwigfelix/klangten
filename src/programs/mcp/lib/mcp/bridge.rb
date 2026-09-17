# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; Klango server terms instead of EltenLink rules.

module EltenMCP
  class BackgroundNetworkClient < EltenLink::Client
    MCP_DEFAULT_TIMEOUT = 30.0

    def json(method, path, params = nil, timeout: MCP_DEFAULT_TIMEOUT, headers: nil, cancellation_token: nil)
      super
    end

    def api_payload(method, path, params = nil, timeout: MCP_DEFAULT_TIMEOUT, headers: nil, cancellation_token: nil)
      super
    end

    def api_data(method, path, params = nil, timeout: MCP_DEFAULT_TIMEOUT, headers: nil, cancellation_token: nil)
      super
    end

    def api_success?(method, path, params = nil, timeout: MCP_DEFAULT_TIMEOUT, headers: nil, cancellation_token: nil)
      super
    end

    def api_binary_payload(method, path, body, headers = {}, params = nil, timeout: MCP_DEFAULT_TIMEOUT, cancellation_token: nil)
      super
    end

    def api_binary_data(method, path, body, headers = {}, params = nil, timeout: MCP_DEFAULT_TIMEOUT, cancellation_token: nil)
      super
    end
  end

  class Bridge
    include EltenAPI

    def config(group, key, default = "")
      readconfig(group, key, default)
    end

    def set_config(group, key, value)
      writeconfig(group, key, value)
    end

    def translate(context, text)
      p_(context, text)
    rescue Exception
      text
    end

    def choose(options, header, cancel_index = 0)
      select_action(
        options.each_with_index.map { |label, index| [index, label] },
        :header => header,
        :cancel => cancel_index
      )
    end

    def ask_text(header, text = "")
      input_text(header, :text => text.to_s, :escapable => true)
    end

    def choose_permission(rows, header)
      result = nil
      dialog_open
      control = EltenAPI::Controls::ChoiceListBox.new(rows, :header => header, :quiet => true)
      apply = EltenAPI::Controls::Button.new(translate("MCP", "Apply permissions"))
      cancel = EltenAPI::Controls::Button.new(translate("MCP", "Cancel"))
      form = EltenAPI::Controls::Form.new([control, apply, cancel], :quiet => true)
      form.header = header
      form.accept_button = apply
      form.cancel_button = cancel
      apply.on(:press) do
        result = control.values
        form.resume
      end
      control.on(:select) { apply.press }
      cancel.on(:press) { form.resume }
      form.wait
      result
    ensure
      dialog_close
      loop_update
    end

    def choose_permission_level(label, options, header, default = 0)
      selected = choose_permission([[label, options, default]], header)
      selected == nil ? default : selected[0]
    end

    def choose_form(options, header, cancel_index = 0)
      return cancel_index if !options.is_a?(Array) || options.empty?
      result = cancel_index
      dialog_open
      list = EltenAPI::Controls::ListBox.new(options, :header => header, :index => cancel_index, :quiet => true)
      select = EltenAPI::Controls::Button.new(translate("MCP", "Select"))
      cancel = EltenAPI::Controls::Button.new(translate("MCP", "Cancel"))
      form = EltenAPI::Controls::Form.new([list, select, cancel], :quiet => true)
      form.header = header
      form.accept_button = select
      form.cancel_button = cancel
      select.on(:press) do
        result = list.index
        form.resume
      end
      list.on(:select) { select.press }
      cancel.on(:press) { form.resume }
      form.wait
      result
    ensure
      dialog_close
      loop_update
    end

    def manage_client_permissions_form(rows, header)
      result = nil
      dialog_open
      permissions = EltenAPI::Controls::ChoiceListBox.new(rows, :header => header, :quiet => true)
      edit_selective = EltenAPI::Controls::Button.new(translate("MCP", "Edit selected client's selective permissions"))
      revoke_client = EltenAPI::Controls::Button.new(translate("MCP", "Revoke selected client's permissions"))
      save = EltenAPI::Controls::Button.new(translate("MCP", "Save general permissions"))
      close = EltenAPI::Controls::Button.new(translate("MCP", "Close"))
      form = EltenAPI::Controls::Form.new([permissions, edit_selective, revoke_client, save, close], :quiet => true)
      form.header = header
      form.accept_button = save
      form.cancel_button = close
      permissions.on(:select) { save.press }
      edit_selective.on(:press) do
        result = { "action" => "selective" }
        form.resume
      end
      revoke_client.on(:press) do
        result = { "action" => "revoke_client" }
        form.resume
      end
      save.on(:press) do
        result = { "action" => "save_general", "values" => permissions.values }
        form.resume
      end
      close.on(:press) { form.resume }
      form.wait
      result
    ensure
      dialog_close
      loop_update
    end

    def prepare_permission_prompt
      return false if !defined?(EltenWindow) || !EltenWindow.respond_to?(:minimized?)
      return false if EltenWindow.minimized? != true
      restored = if EltenWindow.respond_to?(:restore_from_tray)
                   EltenWindow.restore_from_tray
                 elsif EltenWindow.respond_to?(:show)
                   EltenWindow.show
                 else
                   false
                 end
      return false if restored == false || restored == nil
      if respond_to?(:delay_precise, true)
        delay_precise(0.25)
      else
        sleep(0.25)
      end
      true
    rescue Exception => e
      Log.warning("Cannot restore Klangten window before MCP permission prompt: #{e.class}: #{e.message}") if defined?(Log)
      false
    end

    def show_credentials(authorization, configuration, network = nil, endpoint = nil, bearer_authorization = nil)
      dialog_open
      warning = EltenAPI::Controls::Static.new(translate("MCP", "These credentials contain a secret client key. Treat it like a password and do not paste it into chats or prompts."))
      network ||= {}
      network_summary = EltenAPI::Controls::Static.new(
        translate("MCP", "Bind address: %{host}. Accepted client subnets: %{subnets}. Connections outside these subnets are rejected before the client key is checked.")
          .gsub("%{host}", network["bind_address"].to_s)
          .gsub("%{subnets}", Array(network["allowed_subnets"]).join(", "))
      )
      authorization_field = EltenAPI::Controls::EditBox.new(
        translate("MCP", "Authorization header"),
        :type => EltenAPI::Controls::EditBox::Flags::ReadOnly,
        :text => authorization
      )
      configuration_field = EltenAPI::Controls::EditBox.new(
        translate("MCP", "Example MCP client configuration"),
        :type => EltenAPI::Controls::EditBox::Flags::MultiLine | EltenAPI::Controls::EditBox::Flags::ReadOnly,
        :text => configuration
      )
      copy_authorization = EltenAPI::Controls::Button.new(translate("MCP", "Copy Authorization header"))
      copy_configuration = EltenAPI::Controls::Button.new(translate("MCP", "Copy MCP client configuration"))
      add_to_claude = EltenAPI::Controls::Button.new(translate("MCP", "Add Klangten MCP to Claude Code"))
      add_to_codex = EltenAPI::Controls::Button.new(translate("MCP", "Add Klangten MCP to Codex"))
      add_to_antigravity = EltenAPI::Controls::Button.new(translate("MCP", "Add Klangten MCP to Antigravity"))
      add_to_hermes = EltenAPI::Controls::Button.new(translate("MCP", "Add Klangten MCP to Hermes"))
      close = EltenAPI::Controls::Button.new(translate("MCP", "Close"))
      form = EltenAPI::Controls::Form.new(
        [warning, network_summary, authorization_field, configuration_field, copy_authorization, copy_configuration, add_to_claude, add_to_codex, add_to_antigravity, add_to_hermes, close],
        :quiet => true
      )
      form.header = translate("MCP", "MCP connection details")
      form.cancel_button = close
      copy_authorization.on(:press) do
        copy(authorization)
        notify(translate("MCP", "Authorization header copied. It contains a secret client key."), false)
      end
      copy_configuration.on(:press) do
        copy(configuration)
        notify(translate("MCP", "MCP client configuration copied. It contains a secret client key. Treat it like a password and do not paste it into chats or prompts."), false)
      end
      add_to_claude.on(:press) do
        install_client_configuration(:claude, "Claude Code", endpoint, bearer_authorization)
      end
      add_to_codex.on(:press) do
        install_client_configuration(:codex, "Codex", endpoint, bearer_authorization)
      end
      add_to_antigravity.on(:press) do
        install_client_configuration(:antigravity, "Antigravity", endpoint, bearer_authorization)
      end
      add_to_hermes.on(:press) do
        install_client_configuration(:hermes, "Hermes", endpoint, bearer_authorization)
      end
      close.on(:press) { form.resume }
      form.wait
      true
    ensure
      dialog_close
      loop_update
    end

    def install_client_configuration(target, client_name, endpoint, authorization)
      warning = translate(
        "MCP",
        "Do you want to add Klangten MCP to %{client}? Its configuration file will be detected automatically."
      ).gsub("%{client}", client_name.to_s)
      return false if !confirm_action(warning)
      result = ClientConfigInstaller.new.install(target, :url => endpoint, :authorization => authorization)
      message = if result["status"] == "updated"
                  translate("MCP", "The old Klangten MCP Authorization header was updated in %{client}. Restart the client before using the server.")
                else
                  translate("MCP", "Klangten MCP was added to %{client}. Restart the client before using the server.")
                end
      notify(message.gsub("%{client}", client_name.to_s), false)
      true
    rescue ClientConfigInstaller::ConfigError => error
      message = translate("MCP", "Cannot update the %{client} MCP configuration: %{error}")
        .gsub("%{client}", client_name.to_s)
        .gsub("%{error}", error.message.to_s)
      notify(message, false)
      false
    rescue Exception => error
      Log.error("Unexpected #{client_name} MCP configuration error: #{error.class}: #{error.message}") if defined?(Log)
      message = translate("MCP", "Cannot update the %{client} MCP configuration because of an unexpected local error. The configuration was not intentionally changed.")
        .gsub("%{client}", client_name.to_s)
      notify(message, false)
      false
    end

    def confirm_action(text)
      confirm(text.to_s)
    end

    def notify(text, wait = false)
      alert(text, wait)
    end

    def copy(text)
      Clipboard.text = text.to_s
    end

    def developer_mode?
      super
    end

    def debug_info
      createdebuginfo
    end

    def documentation(name)
      return licensetext if name.to_s == "license"
      # Klangten: EltenLink's rules do not apply; show the notice about the Klango server's terms instead.
      return klangten_server_terms_text if name.to_s == "rules" && respond_to?(:klangten_server_terms_text, true)
      _doc(name.to_s)
    end

    def restart_to_developer
      restart_to_developer_mode
    end

    def launch_program_scene(program_class)
      insert_scene($scene) if $scene != nil
      $scene = program_class.new
    end

    def network_client
      elten_link
    end

    def background_network_client
      @background_network_client ||= BackgroundNetworkClient.new
    end

  end
end
