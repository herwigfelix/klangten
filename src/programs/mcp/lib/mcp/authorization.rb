# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; notes aspect replaces organizer; feed, calendars and tasks removed.

module EltenMCP
  class Authorization
    CAPABILITIES = {
      :basic => {
        :levels => [:read], :always => true,
        :title => "Basic information",
        :description => "Bundled documentation, Klangten and MCP version, and non-secret runtime information. Always available."
      },
      :diagnostics => {
        :levels => [:read],
        :title => "Diagnostics",
        :description => "Redacted logs, debug reports, safe configuration diagnostics, verification and restart controls. Logs can still contain private operational data."
      },
      :account => {
        :levels => [:read, :write],
        :title => "Account information",
        :description => "Profile, visiting card, status, signature, region, contacts, honors and online monitors. Email addresses, passwords, tokens and login keys are never exposed by these tools."
      },
      :forum => {
        :levels => [:scope, :read, :write, :moderate],
        :title => "Forum",
        :description => "Scope reveals only selectable group, forum and thread names/IDs for permission planning. Read adds domain-wide structure and content; write adds posting and personal actions; moderate adds grouped moderation. After scope discovery, request one selective batch for bounded work or the necessary full domain level. Reading a thread can mark unread posts as read."
      },
      :messages => {
        :levels => [:scope, :read, :write, :moderate],
        :title => "Private messages",
        :description => "Scope reveals only selectable correspondent identifiers, names and types for permission planning. Read adds domain-wide conversations and content; write sends messages and creates or updates groups; moderate additionally changes message state, flags or protection, deletes content and manages membership or muting. After scope discovery, request one selective batch for bounded work or the necessary full domain level. Reading content may update read state."
      },
      :notifications => {
        :levels => [:read, :write],
        :title => "Notifications",
        :description => "Notification text and read state; optional grouped marking as read. Opaque notification payloads, sounds and routing are never exposed."
      },
      :blogs => {
        :levels => [:read, :write],
        :title => "Blogs",
        :description => "Domain-wide blogs, posts, comments, categories and mentions; optional creation and management. For bounded work use selective blog/post grants and separate blog/post creation scopes. Password-changing APIs are excluded."
      },
      :notes => {
        :levels => [:read, :write],
        :title => "Notes",
        :description => "Domain-wide private and shared notes. For bounded work use selective note grants and the separate note_creation scope."
      },
      :polls => {
        :levels => [:read, :write],
        :title => "Polls",
        :description => "Poll lists, questions and results; optional answering, creation and deletion."
      },
      :settings => {
        :levels => [:write],
        :title => "Change settings",
        :description => "Read and change a strict allowlist of ordinary Klangten settings. MCP enablement, keys, port and MCP permissions are excluded."
      },
      :source => {
        :levels => [:read],
        :title => "Bundled Klangten sources",
        :description => "Read Ruby sources embedded by the running Klangten launcher: Klangten itself and bundled Ruby libraries. Arbitrary filesystem paths are never accepted."
      },
      :developer => {
        :levels => [:full],
        :title => "Developer tools",
        :description => "Global override plus program source editing, live loading, builds and in-process Ruby evaluation. Equivalent to arbitrary code execution in Elten."
      }
    }.freeze

    LEVEL_LABELS = {
      :none => "Disabled", :scope => "Discover selectable scopes", :read => "Read", :write => "Read and write",
      :moderate => "Read, write and moderate", :full => "Full developer access"
    }.freeze

    class << self
      def requirement(value, level = nil)
        return value if value.is_a?(Hash) && value[:aspect] != nil
        { :aspect => value.to_sym, :level => (level || default_level(value)).to_sym }
      end

      def default_level(aspect)
        Array(CAPABILITIES[aspect.to_sym] && CAPABILITIES[aspect.to_sym][:levels]).first || :read
      end

      def permitted_level?(aspect, level)
        level == :none || Array(CAPABILITIES[aspect.to_sym] && CAPABILITIES[aspect.to_sym][:levels]).include?(level.to_sym)
      end
    end

    def initialize(bridge, config = nil, identity_provider = nil)
      @bridge = bridge
      @config = config
      @identity_provider = identity_provider
      @grants = Hash.new { |hash, key| hash[key] = {} }
      @denied = {}
      @clients = {}
      @restored_clients = {}
      @permission_sources = {}
      @selective = SelectivePermissions.new(bridge)
    end

    def developer_mode?
      @bridge.developer_mode?
    end

    def observe(client)
      id = client_id(client)
      @clients[id] = normalized_client(client)
      restore_client_permissions(id) if !@restored_clients[id]
      id
    end

    def ensure_permission(required, client)
      requirement = self.class.requirement(required)
      aspect = requirement[:aspect].to_sym
      level = requirement[:level].to_sym
      validate_requirement(aspect, level)
      observe(client)
      return requirement if granted?(client, requirement)
      if aspect == :developer && !developer_mode?
        raise AuthorizationError, "Developer MCP tools require Klangten developer mode"
      end
      denied_key = [client_id(client), aspect, level]
      raise AuthorizationError, "This MCP capability was denied for the current Klangten session" if @denied[denied_key]
      request_grant(client, aspect, level)
      return requirement if granted?(client, requirement)
      @denied[denied_key] = true
      raise AuthorizationError, "The requested MCP capability was not granted"
    end

    def ensure_tool_permission(tool, arguments, client)
      requirement = self.class.requirement(tool.permission)
      aspect = requirement[:aspect].to_sym
      return ensure_permission(requirement, client) if ![:forum, :messages, :notes, :blogs].include?(aspect)
      return ensure_permission(requirement, client) if requirement[:level].to_sym == :scope
      observe(client)
      return requirement if granted?(client, requirement)

      resolved = @selective.targets_for(tool.name, arguments)
      if resolved[:general_required]
        raise selective_authorization_error(requirement, [], resolved[:reason])
      end
      if resolved[:unresolved]
        raise selective_authorization_error(requirement, [], resolved[:reason])
      end
      targets = Array(resolved[:targets])
      missing = @selective.missing(client_id(client), aspect, requirement[:level], targets)
      return requirement if !targets.empty? && missing.empty?
      raise selective_authorization_error(requirement, missing.empty? ? targets : missing,
        "The required selective scopes are not all granted.")
    end

    def granted?(client, required)
      requirement = self.class.requirement(required)
      aspect = requirement[:aspect].to_sym
      level = requirement[:level].to_sym
      return true if CAPABILITIES[aspect] && CAPABILITIES[aspect][:always]
      grants = @grants[client_id(client)]
      return true if developer_mode? && grants[:developer] == :full
      level_rank(aspect, grants[aspect]) >= level_rank(aspect, level)
    end

    def request_many(client, requests)
      raise InvalidParamsError, "requests must be a non-empty array" if !requests.is_a?(Array) || requests.empty?
      raise InvalidParamsError, "At most 10 capabilities can be requested together" if requests.size > 10
      observe(client)
      pending = requests.filter_map do |request|
        raise InvalidParamsError, "Each permission request must be an object" if !request.is_a?(Hash)
        aspect = request["aspect"].to_s.to_sym
        level = request["level"].to_s.to_sym
        validate_requirement(aspect, level)
        next if granted?(client, { :aspect => aspect, :level => level })
        { :aspect => aspect, :level => level }
      end
      duplicate = pending.group_by { |request| request[:aspect] }.find { |_aspect, values| values.size > 1 }
      raise InvalidParamsError, "Request each general capability at most once per batch" if duplicate != nil
      if !pending.empty?
        rows = pending.map do |request|
          definition = CAPABILITIES.fetch(request[:aspect])
          levels = [:none] + definition[:levels]
          label = "#{@bridge.translate("MCP", definition[:title])}. #{@bridge.translate("MCP", definition[:description])}"
          options = levels.map { |level| @bridge.translate("MCP", LEVEL_LABELS.fetch(level)) }
          [label, options, levels.index(request[:level]) || 0]
        end
        header = @bridge.translate("MCP", "MCP client %{client} requests %{count} general capabilities in one batch. Review every row; Left and Right change its level, Enter applies the complete list, and Escape cancels.")
          .gsub("%{client}", client_label(client))
          .gsub("%{count}", pending.size.to_s)
        @bridge.prepare_permission_prompt if @bridge.respond_to?(:prepare_permission_prompt)
        values = @bridge.choose_permission(rows, header)
        if values != nil
          id = client_id(client)
          pending.each_with_index do |request, index|
            levels = [:none] + CAPABILITIES.fetch(request[:aspect])[:levels]
            selected = levels[values[index].to_i] || :none
            set_grant(id, request[:aspect], selected, :persist => false)
            Log.info("MCP bulk permission decision for #{client_label(client)}: #{request[:aspect]}=#{selected}") if defined?(Log)
          end
          persist_client_permissions(id)
        end
      end
      summary_for(client)
    end

    def request_selective_many(client, requests)
      id = observe(client)
      result = @selective.request_many(id, client_label(client), requests)
      persist_client_permissions(id) if result["applied"] == true
      Log.info("MCP selective permission batch for #{client_label(client)}: #{Array(requests).size} requested") if defined?(Log)
      result
    end

    def revoke_all(forget: false)
      @config.clear_permission_profiles if forget && @config != nil
      @grants.clear
      @denied.clear
      @selective.clear_all
      @clients.clear
      @restored_clients.clear
      @permission_sources.clear
      true
    end

    def summary_for(client)
      observe(client)
      grants = { "basic" => "read" }
      @grants[client_id(client)].each { |aspect, level| grants[aspect.to_s] = level.to_s }
      {
        "client" => client_label(client),
        "grants" => grants,
        "selective_grants" => @selective.summary_for(client_id(client)),
        "selective_capabilities" => @selective.definitions,
        "developer_override" => developer_mode? && grants["developer"] == "full",
        "permission_source" => @permission_sources[client_id(client)] || "session",
        "permission_policy" => policy,
        "capabilities" => definitions
      }
    end

    def summary
      granted = @grants.values.each_with_object({}) do |values, result|
        values.each { |aspect, level| result[aspect.to_s] ||= []; result[aspect.to_s] << level.to_s }
      end
      granted.each_value(&:uniq!)
      authorized_ids = @grants.select { |_id, values| !values.empty? }.keys | @selective.authorized_client_ids
      {
        "known_clients" => @clients.size,
        "authorized_clients" => authorized_ids.size,
        "granted_capabilities" => granted,
        "selective_grant_count" => @selective.count,
        "denied_requests" => @denied.size,
        "remember_permissions" => @config != nil && @config.remember_permissions?,
        "default_permissions_available" => @config != nil && @config.loopback_only?,
        "default_permissions" => @config == nil ? {} : @config.default_permissions
      }
    end

    def remember_forum_structure(structure)
      @selective.remember_forum_structure(structure)
    end

    def remember_forum_posts(thread_id, posts)
      @selective.remember_forum_posts(thread_id, posts)
    end

    def remember_forum_trash_threads(group_id, threads)
      @selective.remember_forum_trash_threads(group_id, threads)
    end

    def remember_forum_thread(thread_id, forum_id, title = nil)
      @selective.remember_forum_thread(thread_id, forum_id, title)
    end

    def remember_forum_post(thread_id, post_id)
      @selective.remember_forum_post(thread_id, post_id)
    end

    def remember_message_participants(participants)
      @selective.remember_message_participants(participants)
    end

    def remember_messages(participant, messages)
      @selective.remember_messages(participant, messages)
    end

    def remember_notes_scope(notes)
      @selective.remember_notes_scope(notes)
    end

    def remember_blogs(blogs)
      @selective.remember_blogs(blogs)
    end

    def remember_blog_posts(blog, posts)
      @selective.remember_blog_posts(blog, posts)
    end

    def remember_blog_post(blog, post_id, name = nil)
      @selective.remember_blog_post(blog, post_id, name)
    end

    def remember_blog_mentions(mentions)
      @selective.remember_blog_mentions(mentions)
    end

    def definitions
      CAPABILITIES.each_with_object({}) do |(aspect, definition), result|
        next if aspect == :developer && !developer_mode?
        result[aspect.to_s] = {
          "title" => definition[:title],
          "description" => definition[:description],
          "levels" => definition[:levels].map(&:to_s),
          "always" => definition[:always] == true
        }
      end
    end

    def selective_definitions
      @selective.definitions
    end

    def policy
      return {
        "remember_permissions" => false,
        "default_permissions_available" => true,
        "default_permissions" => {},
        "network" => {
          "bind_address" => Config::DEFAULT_BIND_ADDRESS,
          "accepted_subnets" => Config::DEFAULT_ALLOWED_SUBNETS,
          "loopback_only" => true
        }
      } if @config == nil
      network = @config.network_configuration
      {
        "remember_permissions" => @config.remember_permissions?,
        "remembered_profile_scope" => "Signed-in Klango account + current secret MCP key + self-declared client name/version.",
        "default_permissions_available" => network["loopback_only"] == true,
        "default_permissions" => @config.default_permissions,
        "network" => {
          "bind_address" => network["bind_address"],
          "accepted_subnets" => network["allowed_subnets"],
          "loopback_only" => network["loopback_only"] == true
        }
      }
    end

    def permission_clients
      @clients.keys.sort_by { |id| client_label(@clients[id]).downcase }.map do |id|
        { "id" => id, "label" => client_label(@clients[id]) }
      end
    end

    def configure_permission_memory(enabled)
      return false if @config == nil
      remember = enabled == true
      @config.remember_permissions = remember
      @clients.each_key { |id| persist_client_permissions(id) } if remember
      true
    end

    def manage(client_id = nil)
      return manage_client(client_id) if client_id != nil
      clients = permission_clients
      if clients.empty?
        @bridge.notify(@bridge.translate("MCP", "No MCP clients have been observed in this session."), false)
        return true
      end
      close = @bridge.translate("MCP", "Close")
      options = clients.map { |client| client["label"] } + [close]
      selected = @bridge.choose_form(options, @bridge.translate("MCP", "Choose an MCP client whose permissions you want to edit."), options.size - 1)
      return true if selected.to_i >= clients.size
      manage_client(clients[selected.to_i]["id"])
    end

    def manage_client(id)
      client = @clients[id]
      return false if client == nil
      loop do
        aspects, rows = general_permission_rows(id)
        header = @bridge.translate("MCP", "Permissions for %{client}. General and selective permissions are managed together here. Left and Right change a general level; Enter saves general changes.").gsub("%{client}", client_label(client))
        decision = @bridge.manage_client_permissions_form(rows, header)
        return true if decision == nil
        case decision["action"]
        when "save_general"
          apply_general_permission_values(id, aspects, decision["values"])
          return true
        when "selective"
          @selective.manage(id, client_label(client))
          persist_client_permissions(id)
        when "revoke_client"
          return true if revoke_client_from_manager(id)
        end
      end
    end

    private

    def general_permission_rows(id)
      aspects = CAPABILITIES.keys.reject { |aspect| CAPABILITIES[aspect][:always] || (aspect == :developer && !developer_mode?) }
      rows = aspects.map do |aspect|
        current = @grants[id][aspect] || :none
        definition = CAPABILITIES[aspect]
        levels = [:none] + definition[:levels]
        label = "#{@bridge.translate("MCP", definition[:title])}. #{@bridge.translate("MCP", definition[:description])}"
        [label, levels.map { |level| @bridge.translate("MCP", LEVEL_LABELS[level]) }, levels.index(current) || 0]
      end
      [aspects, rows]
    end

    def apply_general_permission_values(id, aspects, values)
      return false if !values.is_a?(Array)
      aspects.each_with_index do |aspect, index|
        levels = [:none] + CAPABILITIES[aspect][:levels]
        set_grant(id, aspect, levels[values[index].to_i] || :none, :persist => false)
      end
      persist_client_permissions(id)
      message = if @config != nil && @config.remember_permissions?
                  "MCP permissions updated and remembered for this Klango account and client profile."
                else
                  "MCP permissions updated for the current Klangten session."
                end
      @bridge.notify(@bridge.translate("MCP", message), false)
      true
    end

    def revoke_client_from_manager(id)
      return false if id == nil || @clients[id] == nil
      warning = @bridge.translate("MCP", "Revoke all current and remembered permissions for %{client}? The client may request access again.").gsub("%{client}", client_label(@clients[id]))
      confirmed = @bridge.choose_form([@bridge.translate("MCP", "Cancel"), @bridge.translate("MCP", "Revoke permissions")], warning, 0)
      return false if confirmed.to_i != 1
      clear_client_permissions(id, :forget => true)
      @bridge.notify(@bridge.translate("MCP", "Client permissions revoked."), false)
      true
    end

    def selective_authorization_error(requirement, targets, reason)
      aspect = requirement[:aspect].to_s
      level = requirement[:level].to_s
      selective_requests = @selective.request_items(aspect, level, targets)
      data = {
        "kind" => "permission_plan_required",
        "reason" => reason.to_s,
        "general_option" => {
          "tool" => "mcp_permissions_request",
          "request" => { "aspect" => aspect, "level" => level }
        },
        "selective_option" => {
          "tool" => "mcp_selective_permissions_request",
          "requests" => selective_requests
        },
        "guidance" => "Determine the complete set of resource and creation scopes needed for the task first, then request the whole general or selective set in one batch before continuing."
      }
      AuthorizationError.new("The MCP client lacks the required general or selective permission", :data => data)
    end

    def validate_requirement(aspect, level)
      raise InvalidParamsError, "Unknown MCP permission aspect: #{aspect}" if !CAPABILITIES.key?(aspect)
      raise InvalidParamsError, "Invalid level #{level} for #{aspect}" if !self.class.permitted_level?(aspect, level)
      if aspect == :developer && !developer_mode?
        raise AuthorizationError, "Developer MCP tools require Klangten developer mode"
      end
    end

    def level_rank(aspect, level)
      return 0 if level == nil || level.to_sym == :none
      index = Array(CAPABILITIES[aspect] && CAPABILITIES[aspect][:levels]).index(level.to_sym)
      index == nil ? 0 : index + 1
    end

    def request_grant(client, aspect, required_level)
      id = observe(client)
      levels = [:none] + CAPABILITIES[aspect][:levels]
      options = levels.map { |level| LEVEL_LABELS[level] }
      label = @bridge.translate("MCP", CAPABILITIES[aspect][:title])
      options.map! { |option| @bridge.translate("MCP", option) }
      @bridge.prepare_permission_prompt if @bridge.respond_to?(:prepare_permission_prompt)
      selected_index = @bridge.choose_permission_level(label, options, permission_warning(client, aspect, required_level), 0)
      selected = levels[selected_index.to_i] || :none
      set_grant(id, aspect, selected)
      Log.info("MCP permission decision for #{client_label(client)}: #{aspect}=#{selected}") if defined?(Log)
      selected
    end

    def set_grant(id, aspect, selected, persist: true)
      if selected == :none
        @grants[id].delete(aspect)
      else
        @grants[id][aspect] = selected
      end
      @denied.delete_if { |key, _value| key[0] == id && key[1] == aspect }
      @permission_sources[id] = "session" if persist
      persist_client_permissions(id) if persist
    end

    def restore_client_permissions(id)
      @restored_clients[id] = true
      return false if @config == nil
      client = @clients[id]
      account = current_account_identity
      profile = account == "" ? nil : @config.permission_profile(account, client)
      if profile != nil
        restore_general_permissions(id, profile["general"])
        @selective.replace_for(id, profile["selective"])
        @permission_sources[id] = "remembered"
        return true
      end
      defaults = @config.default_permissions
      if !defaults.empty? && @config.loopback_only?
        restore_general_permissions(id, defaults)
        @permission_sources[id] = "default"
        return true
      end
      @permission_sources[id] = "session"
      false
    rescue Exception => e
      Log.error("Cannot restore MCP permissions: #{e.class}: #{e.message}") if defined?(Log)
      @permission_sources[id] = "session"
      false
    end

    def restore_general_permissions(id, values)
      return if !values.is_a?(Hash)
      values.each do |aspect_name, level_name|
        aspect = aspect_name.to_s.to_sym
        level = level_name.to_s.to_sym
        next if !CAPABILITIES.key?(aspect) || CAPABILITIES[aspect][:always]
        next if aspect == :developer && !developer_mode?
        next if !self.class.permitted_level?(aspect, level) || level == :none
        set_grant(id, aspect, level, :persist => false)
      end
    end

    def persist_client_permissions(id)
      return false if @config == nil || !@config.remember_permissions?
      client = @clients[id]
      account = current_account_identity
      return false if client == nil || account == ""
      general = @grants[id].each_with_object({}) { |(aspect, level), result| result[aspect.to_s] = level.to_s }
      saved = @config.save_permission_profile(account, client, {
        "general" => general,
        "selective" => @selective.summary_for(id)
      })
      @permission_sources[id] = "remembered" if saved
      saved
    rescue Exception => e
      Log.error("Cannot remember MCP permissions: #{e.class}: #{e.message}") if defined?(Log)
      false
    end

    def clear_client_permissions(id, forget: false)
      client = @clients[id]
      account = current_account_identity
      @grants.delete(id)
      @selective.clear_client(id)
      @denied.delete_if { |key, _value| key[0] == id }
      @restored_clients[id] = true
      @permission_sources[id] = "session"
      @config.delete_permission_profile(account, client) if forget && @config != nil && client != nil && account != ""
      true
    end

    def current_account_identity
      value = @identity_provider.respond_to?(:call) ? @identity_provider.call : nil
      value.to_s.strip[0, 200]
    rescue Exception
      ""
    end

    def permission_warning(client, aspect, required_level)
      definition = CAPABILITIES[aspect]
      persistence = if @config != nil && @config.remember_permissions?
                      "This decision will be stored for the current Klango account, secret MCP key and self-declared client name/version until it is forgotten in the main MCP settings."
                    else
                      "This decision lasts only for the current Klangten session."
                    end
      text = "MCP client %{client} requests %{title}: %{level}. %{description} %{persistence}"
      if aspect == :developer
        text += " Developer access is not sandboxed: code evaluation can read tokens, messages and files, use the network, modify programs and act as you."
      else
        text += " The domain tools never return Klangten session tokens, passwords, login keys or email addresses."
      end
      replacements = {
        "client" => client_label(client), "title" => definition[:title],
        "level" => LEVEL_LABELS[required_level], "description" => definition[:description],
        "persistence" => persistence
      }
      translated = @bridge.translate("MCP", text)
      translated.gsub(/%\{(client|title|level|description|persistence)\}/) { |match| replacements[$1] || match }
    end

    def normalized_client(client)
      return { "name" => "unknown MCP client", "version" => "" } if !client.is_a?(Hash)
      { "name" => client["name"].to_s, "version" => client["version"].to_s }
    end

    def client_id(client)
      if client.is_a?(Hash)
        session_id = client["_session_id"].to_s
        return "session:#{session_id}" if session_id.match?(/\A[0-9a-f]{64}\z/)
      end
      value = normalized_client(client)
      "unbound:#{value["name"][0, 100]}\0#{value["version"][0, 50]}"
    end

    def client_label(client)
      value = normalized_client(client)
      name = value["name"].strip.gsub(/[[:cntrl:]]/, " ")
      version = value["version"].strip.gsub(/[[:cntrl:]]/, " ")
      name = "unknown MCP client" if name == ""
      version == "" ? name[0, 120] : "#{name[0, 100]} #{version[0, 30]}"
    end
  end
end
